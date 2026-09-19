#!/usr/bin/env bash
# One-time step before Argo CD can deploy slates.
#
# The slates chart requires a TLS identity (certificate + private key) per pod and never generates
# them: the certificate is each node's stable anchor and every peer pins it. This mints
# self-signed *test* identities with slates' own tool and hands them to the live Argo CD
# Application as Helm values. Key material goes from a 0700 temp dir straight into the cluster —
# never into this repo. (It is visible to anyone who can read Applications in the argocd
# namespace; bring identities from a real authority for anything that matters.)
#
#   scripts/apps/slates-identities.sh            mint + install, refuses if identities exist
#   scripts/apps/slates-identities.sh --rotate   replace them (re-keys the fleet: every pin changes)
#
#   SLATES_DIR       slates checkout to run `cargo xtask` in   (default: ../slates)
#   SLATES_REPLICAS  fleet size; needs that many nodes (required anti-affinity)   (default: 3)
. "$(dirname "$0")/../lib.sh"
need kubectl
need jq
need cargo

rotate=0; [ "${1:-}" = "--rotate" ] && rotate=1
slates_dir="${SLATES_DIR:-$ROOT/../slates}"
replicas="${SLATES_REPLICAS:-3}"
ns="$ARGOCD_NAMESPACE"

[ -f "$slates_dir/xtask/Cargo.toml" ] || die "no slates checkout at $slates_dir (set SLATES_DIR)"
k -n "$ns" get application slates >/dev/null 2>&1 || die "Argo CD application 'slates' not found — run scripts/30-argocd.sh"

if k -n "$ns" get application slates -o jsonpath='{.spec.source.helm.values}' | grep -q '^certificates:'; then
  [ "$rotate" = 1 ] || { ok "slates already has identities — nothing to do (use --rotate to replace them)"; exit 0; }
  warn "rotating identities: every node's pinned certificate changes"
fi

nodes="$(k get nodes --no-headers -l '!node-role.kubernetes.io/control-plane' | wc -l | tr -d ' ')"
[ "$nodes" -ge "$replicas" ] || die "slates needs $replicas schedulable nodes (required anti-affinity); this cluster has $nodes workers"

tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
log "Minting $replicas self-signed identities with 'cargo xtask kind certs' in $slates_dir"
( cd "$slates_dir" && cargo xtask kind certs --replicas "$replicas" --out "$tmp/identities.yaml" )
grep -q '^certificates:' "$tmp/identities.yaml" || die "unexpected output from 'cargo xtask kind certs'"

# Pods are named <fullname>-N and identities are keyed by pod name, hence fullnameOverride.
{ printf 'fullnameOverride: slates\nreplicas: %s\n' "$replicas"; cat "$tmp/identities.yaml"; } > "$tmp/values.yaml"
jq -Rs '{spec: {source: {helm: {values: .}}}}' "$tmp/values.yaml" > "$tmp/patch.json"
k -n "$ns" patch application slates --type merge --patch-file "$tmp/patch.json" >/dev/null
ok "identities installed on the slates Application — Argo CD will sync within a minute"

cat <<NEXT

    Once the pods are Running, initialise consensus ONCE (readiness passes before this is done):
      kubectl --context $KUBE_CONTEXT -n slates rollout status statefulset/slates
      kubectl --context $KUBE_CONTEXT -n slates exec slates-0 -- /slates bootstrap root
      kubectl --context $KUBE_CONTEXT -n slates exec slates-0 -- /slates status

NEXT
