#!/usr/bin/env bash
# Copies the Docker Hub access token into the cluster so pipelines can push and Argo CD can pull.
#
# Source of truth is `export DOCKER_PAT=...` in $DOCKER_PAT_SOURCE (default ~/.zshrc), or the
# DOCKER_PAT environment variable if it is already set. The token is:
#   - never printed, never written into this repo, never placed on a command line (`ps`-safe)
#   - verified against Docker Hub *before* anything is stored, including that it may push
#
# Creates / updates:
#   <concourse team ns>/docker        -> ((docker.username)) / ((docker.password)) in pipelines
#   argocd/repo-dockerhub-oci         -> Argo CD credentials for oci://registry-1.docker.io/<user>
#
# Re-run this after rotating the token; both Secrets are replaced in place.
. "$(dirname "$0")/lib.sh"
need kubectl
need curl
need jq

read_pat() {
  if [ -n "${DOCKER_PAT:-}" ]; then printf '%s' "$DOCKER_PAT"; return 0; fi
  [ -r "$DOCKER_PAT_SOURCE" ] || die "DOCKER_PAT is not set and $DOCKER_PAT_SOURCE is not readable"
  # Parse the single assignment rather than sourcing a zsh rc file (side effects, zsh-only syntax).
  grep -E '^[[:space:]]*(export[[:space:]]+)?DOCKER_PAT=' "$DOCKER_PAT_SOURCE" | tail -1 |
    sed -E "s/^[[:space:]]*(export[[:space:]]+)?DOCKER_PAT=//; s/^\"([^\"]*)\".*/\1/; s/^'([^']*)'.*/\1/; s/[[:space:]].*\$//" |
    tr -d '\n'
}

tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
read_pat > "$tmp/password"
[ -s "$tmp/password" ] || die "no DOCKER_PAT found in the environment or in $DOCKER_PAT_SOURCE"
printf '%s' "$DOCKER_USER" > "$tmp/username"

log "Verifying the token with Docker Hub as user '$DOCKER_USER'"
# curl reads the credentials from a 0600 config file, so they never appear in argv.
printf 'user = "%s:%s"\n' "$DOCKER_USER" "$(cat "$tmp/password")" > "$tmp/curlrc"; chmod 600 "$tmp/curlrc"
scope="repository:${DOCKER_USER}/localkind-probe:pull,push"
http="$(curl -sS -o "$tmp/token.json" -w '%{http_code}' -K "$tmp/curlrc" \
  "https://auth.docker.io/token?service=registry.docker.io&scope=${scope}")" || die "could not reach auth.docker.io"
rm -f "$tmp/curlrc"
[ "$http" = "200" ] || die "Docker Hub rejected the credentials for '$DOCKER_USER' (HTTP $http). Is DOCKER_PAT current?"
# The granted actions are inside the (unverified, we only read it) JWT payload.
actions="$(jq -r '.token' "$tmp/token.json" | cut -d. -f2 | tr '_-' '/+' |
  awk '{ pad = (4 - length($0) % 4) % 4; while (pad-- > 0) $0 = $0 "="; print }' |
  base64 --decode 2>/dev/null | jq -r '[.access[]?.actions[]?] | join(",")' 2>/dev/null || true)"
rm -f "$tmp/token.json"
case ",$actions," in
  *,push,*) ok "token is valid and may push (granted: $actions)" ;;
  *) die "token is valid but was NOT granted push (granted: '${actions:-nothing}'). Create a Read & Write token." ;;
esac

apply_secret() { # <namespace> <name> [--label k=v ...] -- <kubectl create secret args...>
  local ns="$1" name="$2"; shift 2
  local labels=()
  while [ "$1" != "--" ]; do labels+=("$1"); shift; done; shift
  k -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml |
    k label --local -f - "${labels[@]}" -o yaml | k apply -f - >/dev/null
}

k get namespace "$CONCOURSE_TEAM_NAMESPACE" >/dev/null 2>&1 ||
  die "namespace $CONCOURSE_TEAM_NAMESPACE does not exist yet — run scripts/20-concourse.sh first (the chart creates it)"
apply_secret "$CONCOURSE_TEAM_NAMESPACE" docker \
  app.kubernetes.io/managed-by=hyperlight-localkind -- \
  --from-file=username="$tmp/username" --from-file=password="$tmp/password"
ok "pipeline credentials: $CONCOURSE_TEAM_NAMESPACE/docker  ->  ((docker.username)) ((docker.password))"

if k get namespace "$ARGOCD_NAMESPACE" >/dev/null 2>&1; then
  printf 'helm' > "$tmp/type"
  printf 'registry-1.docker.io/%s' "$DOCKER_USER" > "$tmp/url"
  printf 'dockerhub-%s' "$DOCKER_USER" > "$tmp/name"
  printf 'true' > "$tmp/enableOCI"
  apply_secret "$ARGOCD_NAMESPACE" repo-dockerhub-oci \
    argocd.argoproj.io/secret-type=repository app.kubernetes.io/managed-by=hyperlight-localkind -- \
    --from-file=type="$tmp/type" --from-file=name="$tmp/name" --from-file=url="$tmp/url" \
    --from-file=enableOCI="$tmp/enableOCI" \
    --from-file=username="$tmp/username" --from-file=password="$tmp/password"
  ok "Argo CD repository credentials: $ARGOCD_NAMESPACE/repo-dockerhub-oci"
else
  warn "namespace $ARGOCD_NAMESPACE not found — skipped Argo CD repository credentials (run scripts/30-argocd.sh, then re-run this)"
fi
