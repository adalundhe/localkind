#!/usr/bin/env bash
# Sets every pipeline in pipelines/*.yml from the local working tree and unpauses it.
#
# After this first run the `localkind` meta-pipeline takes over: it watches pipelines/ on the
# main branch of this repo on GitHub and re-applies every pipeline on each push. So:
#   - to change a pipeline for good: edit, commit, push (no fly needed)
#   - to try a change locally first:  scripts/70-pipelines.sh <name>   (the next push wins)
#
#   scripts/70-pipelines.sh            all pipelines
#   scripts/70-pipelines.sh slates     just one
. "$(dirname "$0")/lib.sh"

[ -x "$FLY_BIN" ] || die "fly not found at $FLY_BIN — run scripts/50-cli-login.sh"
fly() { "$FLY_BIN" -t "$FLY_TARGET" "$@"; }
fly status >/dev/null 2>&1 || die "fly target '$FLY_TARGET' is not logged in — run scripts/50-cli-login.sh"

if ! secret_exists "$CONCOURSE_TEAM_NAMESPACE" docker; then
  warn "no Docker Hub credentials in $CONCOURSE_TEAM_NAMESPACE/docker yet — CI jobs will run, but"
  warn "every 'publish' job will fail at the push until scripts/40-registry-credentials.sh succeeds."
fi

set_one() {
  local file="$1" name
  name="$(basename "$file" .yml)"
  # Only pass docker_user to pipelines that reference it; fly rejects undeclared-but-unused vars
  # silently today, but being exact keeps `--strict`-style checks meaningful.
  if grep -q '((docker_user))' "$file"; then
    fly set-pipeline --non-interactive -p "$name" -c "$file" -v "docker_user=$DOCKER_USER" >/dev/null
  else
    fly set-pipeline --non-interactive -p "$name" -c "$file" >/dev/null
  fi
  fly unpause-pipeline -p "$name" >/dev/null
  ok "pipeline $name  ->  $CONCOURSE_URL/teams/$CONCOURSE_TEAM/pipelines/$name"
}

if [ $# -gt 0 ]; then
  for name in "$@"; do
    [ -f "$ROOT/pipelines/$name.yml" ] || die "no such pipeline file: pipelines/$name.yml"
    set_one "$ROOT/pipelines/$name.yml"
  done
else
  for file in "$ROOT"/pipelines/*.yml; do set_one "$file"; done
fi
