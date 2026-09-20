#!/usr/bin/env bash
# One command from an empty cluster to a working CI/CD platform. Idempotent: safe to re-run at
# any time, and the way to recover after `docker desktop kubernetes reset-cluster`.
. "$(dirname "$0")/lib.sh"
here="$(dirname "$0")"

step() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; shift; "$@"; }

step "Preflight"                       "$here/00-preflight.sh"
step "Concourse: keys + passwords"     "$here/10-concourse-secrets.sh"
step "Concourse: install"              "$here/20-concourse.sh"
step "Argo CD: install + applications" "$here/30-argocd.sh"

# A bad Docker Hub token must not stop the platform coming up: CI still runs, only pushes fail.
registry_ok=1
step "Docker Hub credentials"          "$here/40-registry-credentials.sh" || registry_ok=0

step "CLIs: install + log in"          "$here/50-cli-login.sh"
step "Local credentials file"          "$here/60-local-secrets.sh"
step "Base images: warm the cache"     "$here/65-warm-images.sh"
step "Pipelines"                       "$here/70-pipelines.sh"

printf '\n'
"$here/access.sh" --no-passwords
printf 'Credentials: cat %s/.secrets/credentials.env   (git-ignored)\n\n' "$ROOT"

if [ "$registry_ok" = 0 ]; then
  warn "Docker Hub credentials were NOT installed (see the error above)."
  warn "Fix DOCKER_PAT in $DOCKER_PAT_SOURCE, then run: scripts/40-registry-credentials.sh"
  exit 2
fi
