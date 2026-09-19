#!/bin/sh
# Derives one version for everything a build publishes (image tag, chart version, appVersion).
#
#   <base>-ci.<commit count>      e.g. 0.1.0-ci.412
#
#   base          first `version` line of $VERSION_FILE (Cargo.toml, pyproject.toml, Chart.yaml)
#   commit count  `git rev-list --count HEAD` — monotonic on a branch, so SemVer ordering matches
#                 commit order and Argo CD's ">=0.0.0-0" constraint always resolves to the newest
#                 build. (Numeric pre-release identifiers compare numerically: ci.9 < ci.10.)
#
# Rebuilding the same commit yields the same version, so re-runs are idempotent.
#
# Inputs : repo/                 (git resource, full history)
# Outputs: version/version       the version
#          version/tags          extra image tags (the registry-image resource adds `latest`)
#          version/labels        OCI labels for oci-build-task's LABELS_FILE
set -eu

: "${VERSION_FILE:?path inside the repo that holds the base version}"
: "${SOURCE_URL:=}"

command -v git >/dev/null 2>&1 || apk add --no-cache git >/dev/null

cd repo
git config --global --add safe.directory "$PWD"

[ -f "$VERSION_FILE" ] || { echo "version file '$VERSION_FILE' not found in repo" >&2; exit 1; }
base="$(grep -m1 -E '^version[[:space:]]*[:=]' "$VERSION_FILE" |
  sed -E 's/^version[[:space:]]*[:=][[:space:]]*//; s/^["'\'']//; s/["'\''].*$//; s/[[:space:]].*$//')"
echo "$base" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
  { echo "could not read a plain x.y.z version from $VERSION_FILE (got '$base')" >&2; exit 1; }

count="$(git rev-list --count HEAD)"
sha="$(git rev-parse HEAD)"
short="$(git rev-parse --short=7 HEAD)"
version="${base}-ci.${count}"

cd ..
printf '%s' "$version" > version/version
printf '%s sha-%s' "$version" "$short" > version/tags
{
  printf 'org.opencontainers.image.version=%s\n' "$version"
  printf 'org.opencontainers.image.revision=%s\n' "$sha"
  [ -n "$SOURCE_URL" ] && printf 'org.opencontainers.image.source=%s\n' "$SOURCE_URL"
} > version/labels

echo "version : $version"
echo "commit  : $sha"
echo "tags    : $(cat version/tags) latest"
