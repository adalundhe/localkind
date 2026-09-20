#!/usr/bin/env bash
# Checks everything the bootstrap depends on and fails with a specific message, before anything
# is installed.
. "$(dirname "$0")/lib.sh"

for tool in docker kubectl helm jq curl git shasum; do need "$tool"; done
ok "tools present: docker kubectl helm jq curl git"

docker info >/dev/null 2>&1 || die "the Docker engine is not running — start Docker Desktop"

kubectl config get-contexts -o name | grep -qx "$KUBE_CONTEXT" || die \
"kube-context '$KUBE_CONTEXT' does not exist.
    Docker Desktop -> Settings -> Kubernetes -> Enable Kubernetes, cluster type 'kind'.
    ('docker desktop kubernetes status' shows its state; it takes a minute or two to appear.)"

total="$(k get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
ready="$(k get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')"
[ "$total" -gt 0 ] && [ "$ready" = "$total" ] || die "cluster not ready: $ready/$total nodes Ready"
ok "cluster $KUBE_CONTEXT: $ready/$total nodes Ready ($(k version -o json 2>/dev/null | jq -r .serverVersion.gitVersion))"

if [ "$KUBE_CONTEXT" != "docker-desktop" ]; then
  warn "KUBE_CONTEXT is not docker-desktop. The UIs are exposed as LoadBalancer Services, which"
  warn "Docker Desktop publishes on localhost. On another cluster you need your own load balancer"
  warn "(or kubectl port-forward) and matching CONCOURSE_URL / ARGOCD_URL."
fi

k get storageclass -o json | jq -e '.items[] | select(.metadata.annotations["storageclass.kubernetes.io/is-default-class"]=="true")' >/dev/null ||
  die "no default StorageClass — Concourse workers and Postgres need PersistentVolumes"
ok "default StorageClass present"

# A port that is busy is fine if it is already ours (re-running bootstrap), fatal otherwise.
port_check() { # <port> <namespace> <service>
  if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1 && ! k -n "$2" get svc "$3" >/dev/null 2>&1; then
    die "port $1 is already in use by something else — free it or override the port in env.sh"
  fi
}
port_check "$CONCOURSE_PORT" "$CONCOURSE_NAMESPACE" "${CONCOURSE_RELEASE}-web"
port_check "$ARGOCD_PORT" "$ARGOCD_NAMESPACE" "${ARGOCD_RELEASE}-server"
port_check "$KIALI_PORT" "$ISTIO_NAMESPACE" kiali
port_check "$GRAFANA_PORT" "$ISTIO_NAMESPACE" grafana
port_check "$HEADLAMP_PORT" "$HEADLAMP_NAMESPACE" headlamp
port_check 2333 "$CHAOS_MESH_NAMESPACE" chaos-dashboard
ok "ports $CONCOURSE_PORT (Concourse), $ARGOCD_PORT (Argo CD), $KIALI_PORT (Kiali), $GRAFANA_PORT (Grafana) and 2333 (Chaos Mesh) are available"

if [ -n "${DOCKER_PAT:-}" ] || grep -qE '^[[:space:]]*(export[[:space:]]+)?DOCKER_PAT=' "$DOCKER_PAT_SOURCE" 2>/dev/null; then
  ok "DOCKER_PAT found (validated against Docker Hub later, by 40-registry-credentials.sh)"
else
  warn "no DOCKER_PAT in the environment or $DOCKER_PAT_SOURCE — CI will run but nothing can be pushed"
fi
