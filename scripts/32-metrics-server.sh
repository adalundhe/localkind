#!/usr/bin/env bash
# metrics-server: makes `kubectl top`, HPAs, and CPU/memory columns in k9s/Kiali work.
# kind's kubelets serve self-signed certificates, hence --kubelet-insecure-tls.
. "$(dirname "$0")/lib.sh"
need helm
need kubectl

h repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null 2>&1 || true
h repo update metrics-server >/dev/null
log "helm upgrade --install metrics-server (chart $METRICS_SERVER_CHART_VERSION)"
h upgrade --install metrics-server metrics-server/metrics-server --namespace kube-system \
  --version "$METRICS_SERVER_CHART_VERSION" --set 'args={--kubelet-insecure-tls}' \
  --wait --timeout 5m >/dev/null

i=0
until k top nodes >/dev/null 2>&1; do   # the first scrape takes ~30-60s after the pod is Ready
  i=$((i+1)); [ "$i" -gt 36 ] && die "metrics-server is running but 'kubectl top nodes' still fails"
  sleep 5
done
ok "metrics-server is serving: kubectl top nodes / kubectl top pods -A"
