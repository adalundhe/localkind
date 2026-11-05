#!/usr/bin/env bash
# One-time step before Argo CD can deploy mantle.
#
# The mantle chart installs each founder's identity and keys from a Secret, <release>-N-founder, and
# never generates one: a founder's certificate is its node id's anchor and every peer pins it
# (mantle's docs/design/kubernetes.md §3). This makes the cell with mantle's own `mantle init`, run
# from the image Concourse published, each founder reached at its pod's Service's name, the
# harness's gateway pinned in every founder (`mantle init gateway`), and sets each founder's pack
# (`mantle pack`) as its Secret, and the cell's own pack as mantle-harness-cell for the transfer
# harness's Job. Key material goes from a 0700 temp dir straight into the cluster, never into this
# repo. (It is visible to anyone who can read Secrets in the mantle namespace.)
#
#   scripts/apps/mantle-init.sh       make the cell and set its Secrets; refuses if they exist
#
#   MANTLE_IMAGE     the image to run mantle from   (default: $DOCKER_USER/mantle:latest)
#   MANTLE_FOUNDERS  the cell's founders; needs that many nodes (required anti-affinity)   (default: 3)
#   MANTLE_RESERVE   bytes this Mac keeps free   (default: 40G)
#   MANTLE_VOLUME    each founder's volume, bytes or with a K, M, G or T suffix   (default: this
#                    Mac's free space less MANTLE_RESERVE, a third each: the cluster's disks are a
#                    sparse file on it, far larger than what it can hold)
. "$(dirname "$0")/../lib.sh"
need kubectl
need docker

image="${MANTLE_IMAGE:-$DOCKER_USER/mantle:latest}"
founders="${MANTLE_FOUNDERS:-3}"
reserve="${MANTLE_RESERVE:-40G}"
ns=mantle
release=mantle

if k -n "$ns" get secret "$release-0-founder" >/dev/null 2>&1; then
  ok "mantle's founders have their Secrets already: nothing to do (a new cell needs the old one's claims and Secrets removed first)"
  exit 0
fi
# A founder to a node (required anti-affinity), the control plane's taint tolerated by the app's
# values (argocd/apps/mantle.yaml), so every node of the cluster can hold one.
nodes="$(k get nodes --no-headers | wc -l | tr -d ' ')"
[ "$nodes" -ge "$founders" ] || die "mantle needs $founders nodes (one founder each, required anti-affinity); this cluster has $nodes"

bytes() {
  case "$1" in
    *T) echo $(( ${1%T} << 40 )) ;;
    *G) echo $(( ${1%G} << 30 )) ;;
    *M) echo $(( ${1%M} << 20 )) ;;
    *K) echo $(( ${1%K} << 10 )) ;;
    *) echo "$1" ;;
  esac
}
if [ -n "${MANTLE_VOLUME:-}" ]; then
  volume="$(bytes "$MANTLE_VOLUME")"
else
  free=$(( $(df -k "$HOME" | awk 'NR == 2 { print $4 }') << 10 ))
  keep="$(bytes "$reserve")"
  [ "$free" -gt "$keep" ] || die "this Mac has $free bytes free, no more than the $keep it keeps"
  volume=$(( (free - keep) / founders ))
fi
log "Each founder's volume: $volume bytes"

tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
mantle() { docker run --rm --user "$(id -u):$(id -g)" --volume "$tmp:/work" "$image" "$@"; }
args=(init /work/cell --max-nodes "$founders" --max-volumes "$founders")
for n in $(seq 0 $(( founders - 1 ))); do
  args+=(--node "quic=0.0.0.0:7000,plane=0.0.0.0:7001,s3=0.0.0.0:7480,reach=$release-$n.$ns.svc.cluster.local,name=$release-$n.$ns.svc.cluster.local,name=$release-s3.$ns.svc.cluster.local,domain=node-$n,volume=/volume:$volume")
done
log "Making the cell with $image"
mantle "${args[@]}" > "$tmp/init.txt"
mantle init gateway /work/cell/gateway --cell /work/cell >/dev/null

k get namespace "$ns" >/dev/null 2>&1 || k create namespace "$ns" >/dev/null
# Founder N is the Nth `node` line init said, as it was the Nth --node.
n=0
while read -r _ _ dir _; do
  mantle pack "${dir%:}" "/work/founder-$n" >/dev/null
  k -n "$ns" create secret generic "$release-$n-founder" --from-file=founder="$tmp/founder-$n" >/dev/null
  n=$(( n + 1 ))
done < <(grep '^node ' "$tmp/init.txt")
[ "$n" -eq "$founders" ] || die "init said $n founders, not $founders"
mantle pack /work/cell /work/cell.pack >/dev/null
k -n "$ns" create secret generic mantle-harness-cell --from-file=cell="$tmp/cell.pack" >/dev/null
ok "mantle's $founders founders and the harness's cell are Secrets in namespace $ns: Argo CD's next sync starts them"

cat <<NEXT

    Each founder is ready once the cell enlisted it:
      kubectl --context $KUBE_CONTEXT -n $ns rollout status statefulset/$release

NEXT
