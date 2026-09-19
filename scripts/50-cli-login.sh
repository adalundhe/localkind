#!/usr/bin/env bash
# Initial client-side setup for both tools:
#   - installs `fly`    matching the running Concourse (downloaded from the web node itself)
#   - installs `argocd` matching the running Argo CD  (GitHub release, SHA-256 verified)
#   - logs both in as admin using the credentials generated at install time
#
# Both CLIs only accept a password as a flag (neither reads stdin), so it is briefly visible to
# `ps` on this machine. These are the local platform's admin passwords, never the Docker Hub token.
. "$(dirname "$0")/lib.sh"
need curl
need jq
need kubectl
need shasum

case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=amd64 ;; esac
platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
mkdir -p "$(dirname "$FLY_BIN")" "$(dirname "$ARGOCD_BIN")"

# --- fly ---------------------------------------------------------------------------------------
want="$(curl -fsS -m 10 "$CONCOURSE_URL/api/v1/info" | jq -r .version)" ||
  die "Concourse is not answering on $CONCOURSE_URL — run scripts/20-concourse.sh first"
if [ "$("$FLY_BIN" --version 2>/dev/null || true)" != "$want" ]; then
  log "Installing fly $want ($platform/$arch) to $FLY_BIN"
  curl -fsSL -m 300 "$CONCOURSE_URL/api/v1/cli?arch=$arch&platform=$platform" -o "$FLY_BIN.download"
  chmod +x "$FLY_BIN.download"
  xattr -d com.apple.quarantine "$FLY_BIN.download" 2>/dev/null || true
  mv "$FLY_BIN.download" "$FLY_BIN"
fi
ok "fly $("$FLY_BIN" --version) at $FLY_BIN"

log "fly login: target '$FLY_TARGET' -> $CONCOURSE_URL (team $CONCOURSE_TEAM)"
"$FLY_BIN" -t "$FLY_TARGET" login -c "$CONCOURSE_URL" -n "$CONCOURSE_TEAM" \
  -u "$(secret_value "$CONCOURSE_NAMESPACE" concourse-admin username)" \
  -p "$(secret_value "$CONCOURSE_NAMESPACE" concourse-admin password)" >/dev/null
ok "fly logged in (tokens last 24h — re-run this script when fly says 'not authorized')"

# --- argocd ------------------------------------------------------------------------------------
want="$(curl -fsS -m 10 "$ARGOCD_URL/api/version" | jq -r .Version)" ||
  die "Argo CD is not answering on $ARGOCD_URL — run scripts/30-argocd.sh first"
want="${want%%+*}"   # "v3.5.3+abc123" -> "v3.5.3"
have="$("$ARGOCD_BIN" version --client --short 2>/dev/null | awk '{print $2}' || true)"
if [ "${have%%+*}" != "$want" ]; then
  log "Installing argocd $want ($platform/$arch) to $ARGOCD_BIN"
  base="https://github.com/argoproj/argo-cd/releases/download/$want"
  asset="argocd-$platform-$arch"
  curl -fsSL -m 300 "$base/$asset" -o "$ARGOCD_BIN.download"
  expected="$(curl -fsSL -m 30 "$base/cli_checksums.txt" | awk -v a="$asset" '$2 == a {print $1}')"
  actual="$(shasum -a 256 "$ARGOCD_BIN.download" | awk '{print $1}')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    rm -f "$ARGOCD_BIN.download"
    die "checksum mismatch for $asset (expected '${expected:-<none published>}', got '$actual')"
  fi
  chmod +x "$ARGOCD_BIN.download"
  xattr -d com.apple.quarantine "$ARGOCD_BIN.download" 2>/dev/null || true
  mv "$ARGOCD_BIN.download" "$ARGOCD_BIN"
fi
ok "argocd $want at $ARGOCD_BIN (sha256 verified on install)"

host="${ARGOCD_URL#http://}"; host="${host#https://}"
log "argocd login: $host"
"$ARGOCD_BIN" login "$host" --plaintext --name "$FLY_TARGET" --username admin \
  --password "$(secret_value "$ARGOCD_NAMESPACE" argocd-initial-admin-secret password)" >/dev/null
ok "argocd logged in (context '$FLY_TARGET')"

printf '\n'; "$FLY_BIN" -t "$FLY_TARGET" workers
printf '\n'; "$ARGOCD_BIN" app list 2>/dev/null || true
