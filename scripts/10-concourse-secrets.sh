#!/usr/bin/env bash
# Generates Concourse's signing/SSH keys plus the admin and database passwords, and stores them
# as Kubernetes Secrets. Nothing secret is written into this repo or passed on a command line.
#
# Idempotent: existing secrets are never regenerated. Rotating the host/worker keys would orphan
# registered workers, and rotating the DB password would lock Concourse out of its own database.
. "$(dirname "$0")/lib.sh"
need docker
need kubectl

ns="$CONCOURSE_NAMESPACE"
web_secret="${CONCOURSE_RELEASE}-web"       # names the chart expects when secrets.create=false
worker_secret="${CONCOURSE_RELEASE}-worker"
image="concourse/concourse:${CONCOURSE_IMAGE_TAG}"

ensure_namespace "$ns"

# Scratch space lives under the repo (always shared with Docker Desktop) and is gitignored.
tmp="$ROOT/.tmp-secrets"
rm -rf "$tmp"; mkdir -p "$tmp"; chmod 700 "$tmp"
trap 'rm -rf "$tmp"' EXIT

label() { k -n "$ns" label secret "$1" app.kubernetes.io/managed-by=hyperlight-platform --overwrite >/dev/null; }

have_web=0; have_worker=0
secret_exists "$ns" "$web_secret" && have_web=1
secret_exists "$ns" "$worker_secret" && have_worker=1

if [ "$have_web" != "$have_worker" ]; then
  die "only one of $web_secret / $worker_secret exists in $ns. They hold two halves of the same key pairs — delete both and re-run."
fi

if [ "$have_web" = 1 ]; then
  ok "key secrets $web_secret and $worker_secret already exist — left untouched"
else
  log "Generating Concourse keys with $image"
  gen() { docker run --rm -v "$tmp:/keys" "$image" generate-key -t "$1" -f "/keys/$2" >/dev/null; }
  gen rsa session_signing_key
  gen ssh tsa_host_key
  gen ssh worker_key

  admin_pw="$(random_password 28)"
  printf '%s:%s' "$CONCOURSE_ADMIN_USER" "$admin_pw" > "$tmp/local_users"
  printf '%s' "$CONCOURSE_ADMIN_USER" > "$tmp/admin_user"
  printf '%s' "$admin_pw" > "$tmp/admin_pw"
  unset admin_pw

  k -n "$ns" create secret generic "$web_secret" \
    --from-file=host-key="$tmp/tsa_host_key" \
    --from-file=session-signing-key="$tmp/session_signing_key" \
    --from-file=worker-key-pub="$tmp/worker_key.pub" \
    --from-file=local-users="$tmp/local_users" >/dev/null
  k -n "$ns" create secret generic "$worker_secret" \
    --from-file=host-key-pub="$tmp/tsa_host_key.pub" \
    --from-file=worker-key="$tmp/worker_key" >/dev/null
  # Same admin credentials in a convenient shape for `fly login` and humans.
  k -n "$ns" delete secret concourse-admin --ignore-not-found >/dev/null
  k -n "$ns" create secret generic concourse-admin \
    --from-file=username="$tmp/admin_user" \
    --from-file=password="$tmp/admin_pw" >/dev/null
  label "$web_secret"; label "$worker_secret"; label concourse-admin
  ok "created $web_secret, $worker_secret, concourse-admin"
fi

if secret_exists "$ns" concourse-db; then
  ok "database password secret concourse-db already exists — left untouched"
else
  printf '%s' "$(random_password 32)" > "$tmp/db_pw"
  k -n "$ns" create secret generic concourse-db --from-file=password="$tmp/db_pw" >/dev/null
  label concourse-db
  ok "created concourse-db"
fi
