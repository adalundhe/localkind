#!/usr/bin/env bash
# Chaos Mesh: fault injection at the pod and network level — kill pods, partition them, add
# latency/loss/corruption with netem. Unlike Istio's fault injection (HTTP only) this works on any
# IP traffic, which matters here: focal and slates replicate over UDP/QUIC.
#
# The dashboard runs in security mode: log in with a name of your choice and CHAOS_MESH_TOKEN
# from .secrets/credentials.env (a token for the cluster-scoped manager account created below).
. "$(dirname "$0")/lib.sh"
need helm
need kubectl
need curl

ns="$CHAOS_MESH_NAMESPACE"
h repo add chaos-mesh https://charts.chaos-mesh.org >/dev/null 2>&1 || true
h repo update chaos-mesh >/dev/null
log "helm upgrade --install chaos-mesh (chart $CHAOS_MESH_VERSION)"
# kind nodes run containerd; the chart defaults to the Docker runtime and socket.
h upgrade --install chaos-mesh chaos-mesh/chaos-mesh --namespace "$ns" --create-namespace \
  --version "$CHAOS_MESH_VERSION" \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.securityMode=true \
  --set dashboard.service.type=LoadBalancer \
  --wait --timeout 10m >/dev/null

k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: chaos-manager, namespace: $ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: {name: chaos-manager}
rules:
- apiGroups: [""]
  resources: [pods, namespaces]
  verbs: [get, watch, list]
- apiGroups: [chaos-mesh.org]
  resources: ["*"]
  verbs: [get, list, watch, create, delete, patch, update]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: {name: chaos-manager}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: chaos-manager}
subjects:
- {kind: ServiceAccount, name: chaos-manager, namespace: $ns}
---
apiVersion: v1
kind: Secret
metadata:
  name: chaos-manager-token
  namespace: $ns
  annotations: {kubernetes.io/service-account.name: chaos-manager}
  labels: {app.kubernetes.io/managed-by: hyperlight-localkind}
type: kubernetes.io/service-account-token
YAML
i=0
until [ -n "$(k -n "$ns" get secret chaos-manager-token -o jsonpath='{.data.token}' 2>/dev/null)" ]; do
  i=$((i+1)); [ "$i" -gt 30 ] && die "the chaos-manager-token Secret was never populated"
  sleep 2
done

nodes="$(k get nodes --no-headers | wc -l | tr -d ' ')"
ready="$(k -n "$ns" get daemonset chaos-daemon -o jsonpath='{.status.numberReady}')"
[ "$ready" = "$nodes" ] || warn "chaos-daemon: $ready/$nodes nodes ready (control-plane taints can exclude a node)"

i=0
until curl -fsS -m 5 -o /dev/null "$CHAOS_MESH_URL"; do
  i=$((i+1)); [ "$i" -gt 60 ] && die "the Chaos Mesh dashboard did not answer on $CHAOS_MESH_URL"
  sleep 5
done
ok "Chaos Mesh $CHAOS_MESH_VERSION is up; dashboard at $CHAOS_MESH_URL  (token: CHAOS_MESH_TOKEN in .secrets/credentials.env)"
