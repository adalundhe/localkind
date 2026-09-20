#!/usr/bin/env bash
# Installs Tilt (host CLI) for the inner dev loop: edit -> rebuilt image -> running in the
# cluster in seconds, without Git, Concourse, Docker Hub or Argo CD in the path.
#
# No registry is needed: Docker Desktop's kind nodes pull through a mirror of the local Docker
# image store, and Tilt knows not to push on the docker-desktop context. See examples/tilt/.
. "$(dirname "$0")/lib.sh"
need curl
need shasum
need tar

have="$("$TILT_BIN" version 2>/dev/null | sed -E 's/^v?([0-9.]+).*/\1/' || true)"
if [ "$have" = "$TILT_VERSION" ]; then ok "tilt $TILT_VERSION already at $TILT_BIN"; exit 0; fi

case "$(uname -s)" in Darwin) os=mac ;; *) os=linux ;; esac
case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=x86_64 ;; esac
asset="tilt.${TILT_VERSION}.${os}.${arch}.tar.gz"
base="https://github.com/tilt-dev/tilt/releases/download/v${TILT_VERSION}"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
log "Installing tilt $TILT_VERSION ($os/$arch) to $TILT_BIN"
curl -fsSL -m 300 "$base/$asset" -o "$tmp/$asset"
expected="$(curl -fsSL -m 30 "$base/checksums.txt" | awk -v a="$asset" '$2 == a {print $1}')"
actual="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
[ -n "$expected" ] && [ "$expected" = "$actual" ] ||
  die "checksum mismatch for $asset (expected '${expected:-<none published>}', got '$actual')"
tar -xzf "$tmp/$asset" -C "$tmp" tilt
mkdir -p "$(dirname "$TILT_BIN")"
xattr -d com.apple.quarantine "$tmp/tilt" 2>/dev/null || true
mv "$tmp/tilt" "$TILT_BIN"
ok "tilt $("$TILT_BIN" version | awk '{print $1}') at $TILT_BIN (sha256 verified) — try: cd examples/tilt && tilt up"
