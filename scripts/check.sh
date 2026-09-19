#!/usr/bin/env bash
# Pre-commit sanity: syntax-check every script, validate every pipeline, and make sure nothing
# secret is about to be committed. Run before `git commit` (or wire it up as a pre-commit hook:
#   ln -s ../../scripts/check.sh .git/hooks/pre-commit).
. "$(dirname "$0")/lib.sh"
cd "$ROOT"
fail=0

log "Shell syntax"
for f in scripts/*.sh scripts/apps/*.sh ci/scripts/*.sh env.sh; do
  if [ "${f##*/}" = "version.sh" ] || [ "${f##*/}" = "publish-chart.sh" ]; then sh -n "$f"; else bash -n "$f"; fi ||
    { warn "syntax error in $f"; fail=1; }
done
[ "$fail" = 0 ] && ok "all scripts parse"

log "Pipelines"
if [ -x "$FLY_BIN" ]; then
  for f in pipelines/*.yml; do
    if "$FLY_BIN" validate-pipeline --strict -c "$f" -v docker_user="$DOCKER_USER" >/dev/null 2>&1; then
      ok "$f"
    else
      warn "$f is invalid:"; "$FLY_BIN" validate-pipeline --strict -c "$f" -v docker_user="$DOCKER_USER" 2>&1 | sed 's/^/      /' >&2; fail=1
    fi
  done
else
  warn "fly not installed — skipped pipeline validation (scripts/50-cli-login.sh installs it)"
fi

log "Secret scan (everything git tracks or would track)"
files="$(mktemp)"; needles="$(mktemp)"; chmod 600 "$needles"
trap 'rm -f "$files" "$needles"' EXIT
git ls-files --cached --others --exclude-standard > "$files"

# 1. Shapes that should never appear in this repo.
patterns='dckr_pat_[A-Za-z0-9_-]{20,}|dckr_oat_[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}'
hits="$(tr '\n' '\0' < "$files" | xargs -0 grep -IlE -- "$patterns" 2>/dev/null | grep -v '^scripts/check.sh$' || true)"
if [ -n "$hits" ]; then warn "secret-shaped content in: $(echo $hits)"; fail=1; else ok "no secret-shaped strings"; fi

# 2. The *actual* live secrets, matched exactly. Values are only ever held in a 0600 temp file
#    and compared with grep -F; they are never printed.
{
  if [ -n "${DOCKER_PAT:-}" ]; then printf '%s\n' "$DOCKER_PAT"
  elif [ -r "$DOCKER_PAT_SOURCE" ]; then
    grep -E '^[[:space:]]*(export[[:space:]]+)?DOCKER_PAT=' "$DOCKER_PAT_SOURCE" | tail -1 |
      sed -E "s/^[[:space:]]*(export[[:space:]]+)?DOCKER_PAT=//; s/^\"([^\"]*)\".*/\1/; s/^'([^']*)'.*/\1/; s/[[:space:]].*\$//"
  fi
  secret_value "$CONCOURSE_NAMESPACE" concourse-admin password 2>/dev/null; echo
  secret_value "$CONCOURSE_NAMESPACE" concourse-db password 2>/dev/null; echo
  secret_value "$ARGOCD_NAMESPACE" argocd-initial-admin-secret password 2>/dev/null; echo
  [ -f .secrets/credentials.env ] && sed -n 's/^[A-Z_]*PASSWORD=//p' .secrets/credentials.env
} 2>/dev/null | awk 'length($0) >= 8' | sort -u > "$needles"
count="$(wc -l < "$needles" | tr -d ' ')"
if [ "$count" -gt 0 ]; then
  hits="$(tr '\n' '\0' < "$files" | xargs -0 grep -IlF -f "$needles" 2>/dev/null || true)"
  if [ -n "$hits" ]; then warn "a LIVE secret value appears in: $(echo $hits)"; fail=1
  else ok "none of the $count live secret values appear in any tracked or untracked-unignored file"; fi
else
  warn "could not load any live secret values to compare against (cluster unreachable?) — pattern scan only"
fi

# 3. The local credentials file must stay ignored.
if git check-ignore -q .secrets/credentials.env; then ok ".secrets/ is git-ignored"; else warn ".secrets/ is NOT git-ignored"; fail=1; fi

[ "$fail" = 0 ] && { printf '\n'; ok "all checks passed"; } || die "checks failed"
