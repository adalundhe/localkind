#!/usr/bin/env bash
# One-time step after Argo CD first syncs focal.
#
# focal's host pods mount a Secret of invitations that only the *running founder* can mint, so
# they sit in ContainerCreating until it exists. This issues one invitation per host pod and
# installs them as that Secret — the same thing focal's own deploy/kubernetes/invitations.sh does,
# but discovering the host pods from the StatefulSets instead of hard-coding their names.
#
# Invitations are single-use and expire; re-run for any host that never joined.
. "$(dirname "$0")/../lib.sh"
need kubectl
need jq

ns="${FOCAL_NAMESPACE:-focal}"
secret="${FOCAL_INVITATIONS_SECRET:-focal-invitations}"   # chart value `invitationsSecret`

k get namespace "$ns" >/dev/null 2>&1 ||
  die "namespace $ns does not exist yet — has Argo CD synced the focal app? ($ARGOCD_URL/applications/focal)"

log "Waiting for focal-founder-0 to be Ready"
k -n "$ns" wait --for=condition=Ready pod/focal-founder-0 --timeout=600s >/dev/null

hosts="$(k -n "$ns" get statefulsets -o json |
  jq -r '.items[] | select(.metadata.name != "focal-founder")
         | .metadata.name as $n | range(0; .spec.replicas) | "\($n)-\(.)"')"
[ -n "$hosts" ] || die "no host StatefulSets found in $ns"

tmp="$(mktemp -d)"; chmod 700 "$tmp"; trap 'rm -rf "$tmp"' EXIT
args=()
for host in $hosts; do
  log "Inviting $host"
  k -n "$ns" exec focal-founder-0 -c focal -- \
    /focal --data-dir /var/lib/focal cluster invite --node "$host" --output - > "$tmp/$host.invite"
  [ -s "$tmp/$host.invite" ] || die "founder returned an empty invitation for $host"
  args+=("--from-file=$host.invite=$tmp/$host.invite")
done

k -n "$ns" delete secret "$secret" --ignore-not-found >/dev/null
k -n "$ns" create secret generic "$secret" "${args[@]}" >/dev/null
ok "installed $secret for: $(echo $hosts | tr '\n' ' ')"
printf '    watch them join:  kubectl --context %s -n %s get pods -w\n' "$KUBE_CONTEXT" "$ns"
