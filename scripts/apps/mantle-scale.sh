#!/usr/bin/env bash
# The scale step's transfer and replication tests in the KIND cell (mantle's plan step 12;
# docs/design/kubernetes.md §6): mantle's transfer harness from a Job in the mantle namespace, on the
# cell scripts/apps/mantle-init.sh made and Argo CD runs, through both doors. The small sets go
# largest first, and halfway through the first one's native puts Chaos Mesh kills each founder's
# pod in turn (PodChaos pod-kill), each successor waited for until it is ready; every acknowledged
# object is then read back through each node. The large objects fill the cell until it refuses one
# as out of space through each door, so the volumes mantle-init.sh sized from this Mac's free space
# less its reserve bound what they hold. This Mac's free space is watched for the run's length: the
# Job is stopped if it falls below the reserve.
#
#   scripts/apps/mantle-scale.sh
#
#   MANTLE_DIR      a mantle checkout at the commit the cell runs, whose deploy/kind/harness.Dockerfile
#                   builds the harness's image   (default: ../mantle)
#   MANTLE_SMALL    the small sets, comma-separated   (default: 100000,10000,1000)
#   MANTLE_LARGE    the large objects' sizes   (default: 10G)
#   MANTLE_RESERVE  bytes this Mac keeps free   (default: 40G)
. "$(dirname "$0")/../lib.sh"
need kubectl
need docker

mantle_dir="${MANTLE_DIR:-$ROOT/../mantle}"
small="${MANTLE_SMALL:-100000,10000,1000}"
large="${MANTLE_LARGE:-10G}"
reserve="${MANTLE_RESERVE:-40G}"
ns=mantle
release=mantle
harness=mantle-harness:local

[ -f "$mantle_dir/deploy/kind/harness.Dockerfile" ] || die "no mantle checkout with the harness's Dockerfile at $mantle_dir (set MANTLE_DIR)"
k -n "$ns" get secret mantle-harness-cell >/dev/null 2>&1 || die "no cell: run scripts/apps/mantle-init.sh"
k -n "$ns" rollout status "statefulset/$release" --timeout=30m >/dev/null || die "the cell's founders are not ready"
case "$reserve" in
  *G) keep=$(( ${reserve%G} << 30 )) ;;
  *T) keep=$(( ${reserve%T} << 40 )) ;;
  *) keep="$reserve" ;;
esac

# The harness's image: the binary the cell runs, beside the stock S3 clients and kubectl at the
# cluster's own version, imported into each node's containerd.
image="$(k -n "$ns" get "statefulset/$release" -o jsonpath='{.spec.template.spec.containers[0].image}')"
server="$(k version -o json | python3 -c 'import json, sys; print(json.load(sys.stdin)["serverVersion"]["gitVersion"])')"
log "Building $harness from $mantle_dir on $image, kubectl $server"
docker pull -q "$image" >/dev/null
docker build -q -f "$mantle_dir/deploy/kind/harness.Dockerfile" --build-arg MANTLE="$image" \
  --build-arg KUBECTL="$server" -t "$harness" "$mantle_dir" >/dev/null
for node in $(k get nodes -o jsonpath='{.items[*].metadata.name}'); do
  docker save "$harness" | docker exec -i "$node" ctr -n k8s.io images import - >/dev/null
done
ok "$harness on every node"

k apply -f - >/dev/null <<YAML
apiVersion: v1
kind: ServiceAccount
metadata: {name: mantle-harness, namespace: $ns}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: mantle-harness, namespace: $ns}
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [get, list, watch, delete]
- apiGroups: [chaos-mesh.org]
  resources: [podchaos]
  verbs: [get, list, watch, create, delete]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: mantle-harness, namespace: $ns}
subjects: [{kind: ServiceAccount, name: mantle-harness, namespace: $ns}]
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: mantle-harness}
---
apiVersion: v1
kind: ConfigMap
metadata: {name: mantle-chaos, namespace: $ns}
data:
  kill-each.sh: |
    # Each founder's pod killed in turn by Chaos Mesh (pod-kill: its containers end at once, as a
    # crash ends them), each successor waited for until it is made again, a pod of a new UID, and
    # ready (enlisted in its run) before the next is killed. kubectl's waits need a positive bound;
    # a day bounds a pod's return, which takes the founder's start, far below it.
    set -eu
    namespace="\$1"
    for n in 0 1 2; do
      pod="$release-\$n"
      before="\$(kubectl -n "\$namespace" get pod "\$pod" -o jsonpath='{.metadata.uid}')"
      kubectl -n "\$namespace" apply -f - <<CHAOS
    apiVersion: chaos-mesh.org/v1alpha1
    kind: PodChaos
    metadata: {name: kill-\$pod, namespace: \$namespace}
    spec:
      action: pod-kill
      mode: one
      selector:
        namespaces: [\$namespace]
        labelSelectors: {statefulset.kubernetes.io/pod-name: \$pod}
    CHAOS
      # The successor is the pod of this name with another UID: a wait by name alone could take
      # the successor for the pod it waits on, so the UID is read until it changes.
      until now="\$(kubectl -n "\$namespace" get pod "\$pod" -o jsonpath='{.metadata.uid}' 2>/dev/null)" \\
        && [ -n "\$now" ] && [ "\$now" != "\$before" ]; do
        sleep 1
      done
      kubectl -n "\$namespace" wait --for=condition=Ready "pod/\$pod" --timeout=24h
      kubectl -n "\$namespace" delete podchaos "kill-\$pod" --wait=true --timeout=24h
      echo "killed \$pod; its successor is ready"
    done
---
apiVersion: batch/v1
kind: Job
metadata: {name: mantle-scale, namespace: $ns}
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: mantle-harness
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        fsGroup: 65532
        seccompProfile: {type: RuntimeDefault}
      initContainers:
      - name: install
        image: $harness
        imagePullPolicy: Never
        command: [mantle, install, /pack/cell, /cell]
        volumeMounts:
        - {name: pack, mountPath: /pack, readOnly: true}
        - {name: cell, mountPath: /cell}
      containers:
      - name: harness
        image: $harness
        imagePullPolicy: Never
        command: [mantle, bench, transfer, /runs/scale, --cell, /cell, --small, "$small", --large, "$large", --disrupt, "sh /chaos/kill-each.sh $ns"]
        volumeMounts:
        - {name: cell, mountPath: /cell}
        - {name: runs, mountPath: /runs}
        - {name: chaos, mountPath: /chaos, readOnly: true}
      volumes:
      - {name: pack, secret: {secretName: mantle-harness-cell, defaultMode: 0440}}
      - {name: cell, emptyDir: {}}
      - {name: runs, emptyDir: {}}
      - {name: chaos, configMap: {name: mantle-chaos}}
YAML
ok "the scale Job runs: small $small, large $large"

# This Mac's free space, watched for the run's length, against its reserve: below it the Job is
# stopped, and the run fails.
low=0
while :; do
  state="$(k -n "$ns" get job mantle-scale -o jsonpath='{.status.succeeded}{.status.failed}')"
  [ -n "$state" ] && break
  free=$(( $(df -k "$HOME" | awk 'NR == 2 { print $4 }') << 10 ))
  if [ "$free" -lt "$keep" ]; then
    warn "this Mac has $free bytes free, below its reserve of $keep: stopping the run"
    k -n "$ns" delete job mantle-scale --wait=true >/dev/null
    low=1
    break
  fi
  sleep 30
done
k -n "$ns" logs job/mantle-scale --all-containers=true || true
[ "$low" = 0 ] || die "stopped below the reserve"
[ "$(k -n "$ns" get job mantle-scale -o jsonpath='{.status.succeeded}')" = 1 ] || die "the scale Job did not complete: a check was not exact, or the harness failed"
ok "every check of the scale step exact in the KIND cell"
