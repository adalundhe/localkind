#!/usr/bin/env bash
# Installs Kiali — the UI for the Istio mesh (traffic graph, config validation, workload health) —
# plus the Prometheus it reads its metrics from. Istio itself has no UI.
#
#   Prometheus  Istio's own sample addon, pinned to ISTIO_VERSION: one pod, no persistence,
#               preconfigured to scrape istiod, ztunnel, waypoints and gateways. Dev-grade on purpose.
#   Kiali       Helm chart pinned to KIALI_VERSION, token login, published on $KIALI_URL.
. "$(dirname "$0")/lib.sh"
need helm
need kubectl
need curl

ns="$ISTIO_NAMESPACE"
k -n "$ns" get deployment istiod >/dev/null 2>&1 || die "Istio is not installed — run scripts/35-istio.sh first"

log "Prometheus (Istio $ISTIO_VERSION sample addon)"
k apply -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/prometheus.yaml" >/dev/null
k -n "$ns" rollout status deployment/prometheus --timeout=300s >/dev/null

h repo add kiali https://kiali.org/helm-charts >/dev/null 2>&1 || true
h repo update kiali >/dev/null
log "helm upgrade --install kiali-server (kiali/kiali-server $KIALI_VERSION)"
h upgrade --install kiali-server kiali/kiali-server --namespace "$ns" \
  --version "$KIALI_VERSION" -f "$ROOT/istio/kiali.yaml" \
  --set "server.port=$KIALI_PORT" --wait --timeout 10m >/dev/null

# Login token: a non-expiring ServiceAccount token for Kiali's own service account, so re-running
# this script never invalidates the token you already have.
k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: kiali-login-token
  namespace: $ns
  annotations:
    kubernetes.io/service-account.name: kiali
  labels:
    app.kubernetes.io/managed-by: hyperlight-localkind
type: kubernetes.io/service-account-token
YAML
i=0
until [ -n "$(k -n "$ns" get secret kiali-login-token -o jsonpath='{.data.token}' 2>/dev/null)" ]; do
  i=$((i+1)); [ "$i" -gt 30 ] && die "the kiali-login-token Secret was never populated"
  sleep 2
done

log "Waiting for $KIALI_URL"
i=0
until curl -fsS -m 5 -o /dev/null "$KIALI_URL/kiali/healthz"; do
  i=$((i+1)); [ "$i" -gt 60 ] && die "Kiali did not answer on $KIALI_URL"
  sleep 5
done
ok "Kiali $KIALI_VERSION is up at $KIALI_URL/kiali  (log in with KIALI_TOKEN from .secrets/credentials.env)"
