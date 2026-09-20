#!/usr/bin/env bash
# Fetches the generated Concourse + Argo CD admin credentials from the cluster and writes them to
# a local, git-ignored file so you can log in to the UIs:
#
#     .secrets/credentials.env      (dir 0700, file 0600)
#
# The cluster's Secrets stay the source of truth; re-run this any time to refresh the file
# (e.g. after a cluster reset + bootstrap generates new passwords).
#
# Safety: refuses to write unless git confirms the path is ignored, so the file can never be
# committed by accident. The Docker Hub token is deliberately NOT copied here — it already lives
# in $DOCKER_PAT_SOURCE and one copy on disk is enough.
. "$(dirname "$0")/lib.sh"
need kubectl
need git

dir="$ROOT/.secrets"
file="$dir/credentials.env"
rel=".secrets/credentials.env"

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$ROOT" check-ignore -q "$rel" ||
    die "$rel is NOT ignored by git — refusing to write secrets there. Add '.secrets/' to .gitignore."
  if git -C "$ROOT" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    die "$rel is tracked by git — refusing to write. Remove it from the index first (git rm --cached $rel)."
  fi
fi

concourse_user="$(secret_value "$CONCOURSE_NAMESPACE" concourse-admin username)" ||
  die "Concourse admin secret not found — run scripts/10-concourse-secrets.sh"
concourse_pw="$(secret_value "$CONCOURSE_NAMESPACE" concourse-admin password)"
argocd_pw="$(secret_value "$ARGOCD_NAMESPACE" argocd-initial-admin-secret password)" ||
  die "Argo CD initial admin secret not found — run scripts/30-argocd.sh"

kiali_token=""
if secret_exists "$ISTIO_NAMESPACE" kiali-login-token; then
  kiali_token="$(secret_value "$ISTIO_NAMESPACE" kiali-login-token token)"
fi

grafana_pw=""
if secret_exists "$ISTIO_NAMESPACE" grafana-admin; then
  grafana_pw="$(secret_value "$ISTIO_NAMESPACE" grafana-admin GF_SECURITY_ADMIN_PASSWORD)"
fi
chaos_token=""
if secret_exists "$CHAOS_MESH_NAMESPACE" chaos-manager-token; then
  chaos_token="$(secret_value "$CHAOS_MESH_NAMESPACE" chaos-manager-token token)"
fi

headlamp_token=""
if secret_exists "$HEADLAMP_NAMESPACE" headlamp-admin-token; then
  headlamp_token="$(secret_value "$HEADLAMP_NAMESPACE" headlamp-admin-token token)"
fi

umask 077
mkdir -p "$dir"; chmod 700 "$dir"
tmp="$(mktemp "$dir/.credentials.XXXXXX")"
cat > "$tmp" <<EOF
# Local credentials for the hyper-light CI/CD platform on kube-context "$KUBE_CONTEXT".
# Generated $(date '+%Y-%m-%d %H:%M:%S') by scripts/60-local-secrets.sh — DO NOT COMMIT (git-ignored).
# Source of truth is the cluster; re-run the script to refresh this file.

CONCOURSE_URL=$CONCOURSE_URL
CONCOURSE_TEAM=$CONCOURSE_TEAM
CONCOURSE_USERNAME=$concourse_user
CONCOURSE_PASSWORD=$concourse_pw
FLY_TARGET=$FLY_TARGET

ARGOCD_URL=$ARGOCD_URL
ARGOCD_USERNAME=admin
ARGOCD_PASSWORD=$argocd_pw

# Kiali (Istio UI): paste KIALI_TOKEN into the login page. Empty if Kiali is not installed.
KIALI_URL=$KIALI_URL/kiali
KIALI_TOKEN=$kiali_token

GRAFANA_URL=$GRAFANA_URL
GRAFANA_USERNAME=admin
GRAFANA_PASSWORD=$grafana_pw

# Chaos Mesh dashboard: "Name" can be anything; paste CHAOS_MESH_TOKEN as the token.
CHAOS_MESH_URL=$CHAOS_MESH_URL
CHAOS_MESH_TOKEN=$chaos_token

# Headlamp (cluster UI): paste HEADLAMP_TOKEN at the login screen. It is cluster-admin.
HEADLAMP_URL=$HEADLAMP_URL
HEADLAMP_TOKEN=$headlamp_token
EOF
unset concourse_pw argocd_pw kiali_token grafana_pw chaos_token headlamp_token
chmod 600 "$tmp"
mv "$tmp" "$file"

ok "wrote $file (mode $(stat -f '%Lp' "$file" 2>/dev/null || stat -c '%a' "$file"), git-ignored)"
printf '    open it with:  cat %s\n' "$file"
