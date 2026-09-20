#!/usr/bin/env bash
# Grafana on the mesh's Prometheus, preloaded with Istio's dashboards (mesh, service, workload,
# ztunnel, control plane). It is Istio's own sample addon, pinned to ISTIO_VERSION — with its
# login fixed: the addon ships anonymous *Admin* access and admin/admin, and Docker Desktop
# publishes these ports to the local network. Here: anonymous off, generated admin password.
. "$(dirname "$0")/lib.sh"
need kubectl
need curl

ns="$ISTIO_NAMESPACE"
k -n "$ns" get deployment prometheus >/dev/null 2>&1 || die "Prometheus is not installed — run scripts/37-kiali.sh first"

if ! secret_exists "$ns" grafana-admin; then
  tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
  printf 'admin' > "$tmp/GF_SECURITY_ADMIN_USER"
  printf '%s' "$(random_password 28)" > "$tmp/GF_SECURITY_ADMIN_PASSWORD"
  k -n "$ns" create secret generic grafana-admin \
    --from-file="$tmp/GF_SECURITY_ADMIN_USER" --from-file="$tmp/GF_SECURITY_ADMIN_PASSWORD" >/dev/null
  k -n "$ns" label secret grafana-admin app.kubernetes.io/managed-by=hyperlight-localkind >/dev/null
  ok "generated the Grafana admin password (Secret $ns/grafana-admin)"
fi

log "Grafana (Istio $ISTIO_VERSION sample addon)"
k apply -f "https://raw.githubusercontent.com/istio/istio/${ISTIO_VERSION}/samples/addons/grafana.yaml" >/dev/null
# Re-applied on every run because `kubectl apply` above resets them to the addon's defaults.
k -n "$ns" set env deployment/grafana \
  GF_AUTH_ANONYMOUS_ENABLED=false GF_AUTH_BASIC_ENABLED=true GF_AUTH_DISABLE_LOGIN_FORM=false >/dev/null
k -n "$ns" set env deployment/grafana --from=secret/grafana-admin >/dev/null
k -n "$ns" patch service grafana --type json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/type\",\"value\":\"LoadBalancer\"},
  {\"op\":\"replace\",\"path\":\"/spec/ports/0/port\",\"value\":${GRAFANA_PORT}}]" >/dev/null
k -n "$ns" rollout status deployment/grafana --timeout=300s >/dev/null

i=0
until curl -fsS -m 5 -o /dev/null "$GRAFANA_URL/api/health" 2>/dev/null; do
  i=$((i+1)); [ "$i" -gt 60 ] && die "Grafana did not answer on $GRAFANA_URL"
  sleep 5
done
ok "Grafana is up at $GRAFANA_URL  (admin / GRAFANA_PASSWORD in .secrets/credentials.env) — dashboards under 'istio'"
