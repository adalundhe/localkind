#!/usr/bin/env bash
# Hardens cluster DNS. Out of the box CoreDNS has exactly one upstream — Docker Desktop's built-in
# forwarder (192.168.65.254) — and that forwarder drops lookups under load: with a few builds
# running, CoreDNS logs `read udp ...->192.168.65.254:53: i/o timeout` and pods see
# "Could not resolve host: github.com". This:
#   - keeps Docker Desktop's resolver first (host.docker.internal, VPN/split DNS keep working) but
#     falls through to public resolvers when it times out (`policy sequential`)
#   - caches for 5 minutes instead of 30s and serves stale answers for up to an hour when every
#     upstream is unreachable, so hot names survive a blip
# Idempotent. A cluster reset restores the stock config, which is why bootstrap runs this.
. "$(dirname "$0")/lib.sh"
need kubectl
need jq

: "${DNS_FALLBACKS:=1.1.1.1 8.8.8.8}"

current="$(k -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}')"
[ -n "$current" ] || die "could not read the coredns ConfigMap in kube-system"

if printf '%s' "$current" | grep -q 'policy sequential'; then
  ok "CoreDNS already hardened — nothing to do"
  exit 0
fi
printf '%s' "$current" | grep -q 'forward \. /etc/resolv.conf {' ||
  die "unexpected Corefile layout (no stock 'forward . /etc/resolv.conf {' block) — not touching it"

desired="$(printf '%s\n' "$current" | sed -E \
  -e "s|^([[:space:]]*)forward \. /etc/resolv.conf \{|\1forward . /etc/resolv.conf ${DNS_FALLBACKS} {\n\1   policy sequential|" \
  -e "s|^([[:space:]]*)cache 30 \{|\1cache 300 {\n\1   serve_stale 1h|")"

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
jq -n --arg corefile "$desired" '{data: {Corefile: $corefile}}' > "$tmp"
k -n kube-system patch configmap coredns --type merge --patch-file "$tmp" >/dev/null
k -n kube-system rollout restart deployment/coredns >/dev/null
k -n kube-system rollout status deployment/coredns --timeout=120s >/dev/null
ok "CoreDNS hardened: upstreams = Docker Desktop resolver, then ${DNS_FALLBACKS}; cache 300s + serve_stale"
