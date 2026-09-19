#!/usr/bin/env bash
# Installs / upgrades Argo CD from argocd/values.yaml, waits for the UI, then applies the
# AppProject and Applications under argocd/.
. "$(dirname "$0")/lib.sh"
need helm
need kubectl
need curl

ns="$ARGOCD_NAMESPACE"

h repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
h repo update argo >/dev/null

log "helm upgrade --install $ARGOCD_RELEASE (chart $ARGOCD_CHART_VERSION) into $KUBE_CONTEXT/$ns"
h upgrade --install "$ARGOCD_RELEASE" argo/argo-cd \
  --namespace "$ns" --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  -f "$ROOT/argocd/values.yaml" \
  --set-string "configs.cm.url=$ARGOCD_URL" \
  --set "server.service.servicePortHttp=$ARGOCD_PORT" \
  --wait --timeout 15m

log "Waiting for $ARGOCD_URL"
i=0
until curl -fsS -m 5 -o /dev/null "$ARGOCD_URL/healthz"; do
  i=$((i+1)); [ "$i" -gt 60 ] && die "Argo CD did not answer on $ARGOCD_URL"
  sleep 5
done
ok "Argo CD is up at $ARGOCD_URL"

# Manifests reference the Docker Hub namespace as __DOCKER_USER__; it comes from env.sh.
render() { sed "s#__DOCKER_USER__#${DOCKER_USER}#g" "$1"; }

if ls "$ROOT/argocd/projects"/*.yaml >/dev/null 2>&1; then
  log "Applying AppProjects"
  for f in "$ROOT/argocd/projects"/*.yaml; do
    render "$f" | k apply -n "$ns" -f - >/dev/null
    ok "applied projects/$(basename "$f")"
  done
fi
if [ -d "$ROOT/argocd/apps" ] && ls "$ROOT/argocd/apps"/*.yaml >/dev/null 2>&1; then
  log "Applying Applications"
  for f in "$ROOT/argocd/apps"/*.yaml; do
    render "$f" | k apply -n "$ns" -f - >/dev/null
    ok "applied apps/$(basename "$f")"
  done
fi
