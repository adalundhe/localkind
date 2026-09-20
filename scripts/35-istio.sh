#!/usr/bin/env bash
# Installs Istio in AMBIENT mode: no sidecars. A per-node `ztunnel` gives enrolled pods mTLS,
# workload identity and L4 policy; L7 (HTTP routing, retries, L7 authz) is opt-in per namespace
# via a waypoint proxy. Nothing is in the mesh until you label a namespace:
#
#     kubectl label namespace <ns> istio.io/dataplane-mode=ambient      # no pod restarts needed
#
# Do NOT enroll concourse, argocd or kube-system: Concourse workers are privileged pods running
# their own nested container networking.
#
# Charts (all pinned to ISTIO_VERSION in env.sh): base (CRDs), istiod, cni, ztunnel — plus the
# Gateway API CRDs, which are how waypoints and ingress gateways are declared.
. "$(dirname "$0")/lib.sh"
need helm
need kubectl

ns="$ISTIO_NAMESPACE"
h repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null 2>&1 || true
h repo update istio >/dev/null

log "Gateway API CRDs $GATEWAY_API_VERSION (the version Istio $ISTIO_VERSION is tested against)"
k apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" >/dev/null

install() { # <release> <chart> [extra helm args...]
  local release="$1" chart="$2"; shift 2
  log "helm upgrade --install $release ($chart $ISTIO_VERSION)"
  h upgrade --install "$release" "$chart" --namespace "$ns" --create-namespace \
    --version "$ISTIO_VERSION" --wait --timeout 10m "$@" >/dev/null
}
install istio-base istio/base
install istiod     istio/istiod  --set profile=ambient -f "$ROOT/istio/istiod.yaml"
install istio-cni  istio/cni     --set profile=ambient
install ztunnel    istio/ztunnel

nodes="$(k get nodes --no-headers | wc -l | tr -d ' ')"
for ds in istio-cni-node ztunnel; do
  ready="$(k -n "$ns" get daemonset "$ds" -o jsonpath='{.status.numberReady}')"
  [ "$ready" = "$nodes" ] || die "DaemonSet $ds: $ready/$nodes pods ready"
done
ok "Istio $ISTIO_VERSION (ambient) is up: istiod + istio-cni and ztunnel on all $nodes nodes"
