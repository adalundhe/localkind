#!/usr/bin/env bash
# Installs / upgrades Concourse from concourse/values.yaml and waits until the web node answers
# and at least one worker has registered.
. "$(dirname "$0")/lib.sh"
need helm
need kubectl
need curl

ns="$CONCOURSE_NAMESPACE"
secret_exists "$ns" "${CONCOURSE_RELEASE}-web" || die "run scripts/10-concourse-secrets.sh first"
secret_exists "$ns" concourse-db            || die "run scripts/10-concourse-secrets.sh first"

h repo add concourse https://concourse-charts.storage.googleapis.com/ >/dev/null 2>&1 || true
h repo update concourse >/dev/null

# The DB password goes through a 0600 temp file rather than --set, so it never shows up in `ps`.
tmp="$(mktemp)"; chmod 600 "$tmp"; trap 'rm -f "$tmp"' EXIT
{
  printf 'postgresql:\n  auth:\n    password: "%s"\n' "$(secret_value "$ns" concourse-db password)"
  printf 'imageTag: "%s"\n' "$CONCOURSE_IMAGE_TAG"
  printf 'concourse:\n  web:\n    externalUrl: "%s"\n    bindPort: %s\n' "$CONCOURSE_URL" "$CONCOURSE_PORT"
  printf '    auth:\n      mainTeam:\n        localUser: "%s"\n' "$CONCOURSE_ADMIN_USER"
} > "$tmp"

log "helm upgrade --install $CONCOURSE_RELEASE (chart $CONCOURSE_CHART_VERSION) into $KUBE_CONTEXT/$ns"
h upgrade --install "$CONCOURSE_RELEASE" concourse/concourse \
  --namespace "$ns" \
  --version "$CONCOURSE_CHART_VERSION" \
  -f "$ROOT/concourse/values.yaml" \
  -f "$tmp" \
  --wait --timeout 15m

log "Waiting for $CONCOURSE_URL"
i=0
until curl -fsS -m 5 "$CONCOURSE_URL/api/v1/info" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 60 ] && die "Concourse web did not answer on $CONCOURSE_URL"
  sleep 5
done
ok "Concourse $(curl -fsS "$CONCOURSE_URL/api/v1/info" | sed -E 's/.*"version":"([^"]+)".*/\1/') is up at $CONCOURSE_URL"
