#!/usr/bin/env bash
# One-screen health view of the platform.
. "$(dirname "$0")/lib.sh"

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

section "Platform pods ($KUBE_CONTEXT)"
k get pods -n "$CONCOURSE_NAMESPACE" -o wide --no-headers 2>/dev/null | awk '{printf "  %-12s %-36s %-8s %-12s %s\n", "concourse", $1, $2, $3, $7}'
k get pods -n "$ARGOCD_NAMESPACE" --no-headers 2>/dev/null | awk '{printf "  %-12s %-52s %-8s %s\n", "argocd", $1, $2, $3}'

section "Docker Hub credentials"
if secret_exists "$CONCOURSE_TEAM_NAMESPACE" docker; then
  echo "  installed ($CONCOURSE_TEAM_NAMESPACE/docker) — pipelines can push"
else
  echo "  MISSING — publish jobs will fail. Run scripts/40-registry-credentials.sh"
fi

if [ -x "$FLY_BIN" ] && "$FLY_BIN" -t "$FLY_TARGET" status >/dev/null 2>&1; then
  section "Concourse workers";   "$FLY_BIN" -t "$FLY_TARGET" workers | sed 's/^/  /'
  section "Pipelines";           "$FLY_BIN" -t "$FLY_TARGET" pipelines | sed 's/^/  /'
  section "Latest build per job"
  "$FLY_BIN" -t "$FLY_TARGET" builds --count 200 --json 2>/dev/null |
    jq -r 'map(select(.pipeline_name != null)) | group_by(.pipeline_name + "/" + .job_name)
           | map(max_by(.id)) | sort_by(.pipeline_name, .job_name)[]
           | "  \(.pipeline_name)/\(.job_name)  #\(.name)  \(.status)"' | column -t | sed 's/^/  /'
else
  section "Concourse"; echo "  fly is not logged in — run scripts/50-cli-login.sh"
fi

section "Argo CD applications"
k -n "$ARGOCD_NAMESPACE" get applications.argoproj.io \
  -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,REVISION:.status.sync.revision' 2>/dev/null | sed 's/^/  /'
printf '\n'
