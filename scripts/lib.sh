#!/usr/bin/env bash
# Sourced by every script. Written for macOS's bash 3.2: no associative arrays, no mapfile.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../env.sh
. "$ROOT/env.sh"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERR\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# Every cluster call is pinned to KUBE_CONTEXT so a stray current-context can never redirect it.
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
h() { helm --kube-context "$KUBE_CONTEXT" "$@"; }

ensure_namespace() {
  k get namespace "$1" >/dev/null 2>&1 || k create namespace "$1" >/dev/null
}

secret_exists() { k -n "$1" get secret "$2" >/dev/null 2>&1; }

# secret_value <namespace> <secret> <key>  -> decoded value on stdout
secret_value() {
  k -n "$1" get secret "$2" -o "jsonpath={.data.$3}" | base64 --decode
}

random_password() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}" || true; }
