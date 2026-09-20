#!/usr/bin/env bash
# Headlamp: a general Kubernetes UI — every workload, its events and logs, pod exec, CRDs (Argo CD
# Applications, Istio resources, chaos experiments) and, with metrics-server, CPU/memory per pod.
# The other UIs each show one slice; this shows the whole cluster.
#
# Login is a ServiceAccount token (Headlamp's in-cluster default, which is what we want: Docker
# Desktop publishes this port to the local network). scripts/access.sh --copy headlamp copies it.
# The token is cluster-admin — it is your own dev cluster — so treat it like a password.
. "$(dirname "$0")/lib.sh"
need helm
need kubectl
need curl

ns="$HEADLAMP_NAMESPACE"
h repo add headlamp https://kubernetes-sigs.github.io/headlamp/ >/dev/null 2>&1 || true
h repo update headlamp >/dev/null
log "helm upgrade --install headlamp (chart $HEADLAMP_CHART_VERSION)"
# The chart's own ServiceAccount stays unprivileged: what you can do is decided by the token you
# log in with, not by the pod.
h upgrade --install headlamp headlamp/headlamp --namespace "$ns" --create-namespace \
  --version "$HEADLAMP_CHART_VERSION" \
  --set service.type=LoadBalancer --set "service.port=$HEADLAMP_PORT" \
  --set clusterRoleBinding.create=false \
  --wait --timeout 10m >/dev/null

k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: headlamp-admin, namespace: $ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: headlamp-admin}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin}
subjects:
- {kind: ServiceAccount, name: headlamp-admin, namespace: $ns}
---
apiVersion: v1
kind: Secret
metadata:
  name: headlamp-admin-token
  namespace: $ns
  annotations: {kubernetes.io/service-account.name: headlamp-admin}
  labels: {app.kubernetes.io/managed-by: hyperlight-localkind}
type: kubernetes.io/service-account-token
YAML
i=0
until [ -n "$(k -n "$ns" get secret headlamp-admin-token -o jsonpath='{.data.token}' 2>/dev/null)" ]; do
  i=$((i+1)); [ "$i" -gt 30 ] && die "the headlamp-admin-token Secret was never populated"
  sleep 2
done

i=0
until curl -fsS -m 5 -o /dev/null "$HEADLAMP_URL" 2>/dev/null; do
  i=$((i+1)); [ "$i" -gt 60 ] && die "Headlamp did not answer on $HEADLAMP_URL"
  sleep 5
done
ok "Headlamp is up at $HEADLAMP_URL  (token: HEADLAMP_TOKEN in .secrets/credentials.env)"
