#!/usr/bin/env bash
# Pulls every base image the pipelines use into Concourse's cache, ONE AT A TIME, before any
# pipeline is unpaused.
#
# Why: on a cold cluster, unpausing everything starts ~18 jobs that each pull a 100-600 MB image
# at the same moment. Docker Desktop's network path does not survive that many parallel flows —
# pulls stall, then die with "TLS handshake timeout", "unexpected EOF" or DNS failures. Fetched
# sequentially the same images take a few minutes in total. Concourse keys the cache by image
# source + digest (shared by every pipeline) and streams it worker-to-worker inside the cluster,
# so each image only has to cross the NAT once.
#
# The image list is derived from pipelines/*.yml, so it cannot drift. Cheap when already warm.
. "$(dirname "$0")/lib.sh"

[ -x "$FLY_BIN" ] || die "fly not found at $FLY_BIN — run scripts/50-cli-login.sh"
"$FLY_BIN" -t "$FLY_TARGET" status >/dev/null 2>&1 || die "fly target '$FLY_TARGET' is not logged in — run scripts/50-cli-login.sh"

images="$(grep -h -E '^[[:space:]]+source: \{repository: [^,}]+(, tag: "[^"]+")?\}' "$ROOT"/pipelines/*.yml |
  sed -E 's/.*repository: ([^,}]+)(, tag: "([^"]+)")?\}.*/\1 \3/' | sort -u)"
[ -n "$images" ] || die "found no base images in pipelines/*.yml"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
total="$(printf '%s\n' "$images" | wc -l | tr -d ' ')"; n=0; failed=""

while read -r repo tag; do
  n=$((n+1)); ref="$repo${tag:+:$tag}"
  {
    printf 'platform: linux\nimage_resource:\n  type: registry-image\n  source:\n    repository: %s\n' "$repo"
    [ -n "$tag" ] && printf '    tag: "%s"\n' "$tag"
    printf 'run:\n  path: sh\n  args: ["-c", "true"]\n'
  } > "$tmp/task.yml"

  attempt=1
  while :; do
    log "[$n/$total] $ref (attempt $attempt)"
    start="$(date +%s)"
    # fly execute needs a directory to upload as the build's inputs; give it an empty one.
    if ( cd "$tmp" && "$FLY_BIN" -t "$FLY_TARGET" execute -c task.yml >"$tmp/out.log" 2>&1 ); then
      ok "$ref cached ($(( $(date +%s) - start ))s)"; break
    fi
    if [ "$attempt" -ge 4 ]; then
      warn "$ref failed after $attempt attempts: $(grep -E 'ERRO|error|failed' "$tmp/out.log" | tail -1)"
      failed="$failed $ref"; break
    fi
    attempt=$((attempt+1)); sleep 10
  done
done <<EOF_IMAGES
$images
EOF_IMAGES

[ -z "$failed" ] || die "could not cache:$failed — check connectivity (is the Mac going to sleep?) and re-run"
ok "all $total base images are cached"
