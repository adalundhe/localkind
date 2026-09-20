# Shared settings for every script in this repo.
# Every value can be overridden from the environment, e.g.
#   KUBE_CONTEXT=kind-other ./scripts/bootstrap.sh

# --- Where things run -------------------------------------------------------
: "${KUBE_CONTEXT:=docker-desktop}"   # Docker Desktop's kind-provisioned cluster
: "${GITHUB_ORG:=hyper-light}"
: "${DOCKER_USER:=lundheaudio}"       # Docker Hub account: login for DOCKER_PAT *and* the namespace that receives images + charts
: "${DOCKER_PAT_SOURCE:=$HOME/.zshrc}" # file containing `export DOCKER_PAT=...`

# --- Concourse ---------------------------------------------------------------
: "${CONCOURSE_NAMESPACE:=concourse}"
: "${CONCOURSE_RELEASE:=concourse}"
: "${CONCOURSE_CHART_VERSION:=20.3.0}" # app version 8.3.0
: "${CONCOURSE_IMAGE_TAG:=8.3.0}"
: "${CONCOURSE_PORT:=8080}"
: "${CONCOURSE_URL:=http://localhost:${CONCOURSE_PORT}}"
: "${CONCOURSE_TEAM:=main}"
: "${CONCOURSE_ADMIN_USER:=admin}"
: "${FLY_TARGET:=hl}"
: "${FLY_BIN:=$HOME/.local/bin/fly}"

# Namespace the Kubernetes credential manager reads pipeline secrets from:
# "<release>-<team>".
: "${CONCOURSE_TEAM_NAMESPACE:=${CONCOURSE_RELEASE}-${CONCOURSE_TEAM}}"

# --- Argo CD ----------------------------------------------------------------
: "${ARGOCD_NAMESPACE:=argocd}"
: "${ARGOCD_RELEASE:=argocd}"
: "${ARGOCD_CHART_VERSION:=10.9.2}"   # app version v3.5.3
: "${ARGOCD_PORT:=8081}"
: "${ARGOCD_URL:=http://localhost:${ARGOCD_PORT}}"
: "${ARGOCD_BIN:=$HOME/.local/bin/argocd}"

# --- Istio (ambient mode) ---------------------------------------------------
: "${ISTIO_NAMESPACE:=istio-system}"
: "${ISTIO_VERSION:=1.30.4}"
: "${GATEWAY_API_VERSION:=v1.5.1}"    # what Istio 1.30 is tested against; bump together

# Kiali (the Istio UI). 2.26.0 is what Istio 1.30.4 ships as its own addon; bump with Istio.
: "${KIALI_VERSION:=2.26.0}"
: "${KIALI_PORT:=8082}"
: "${KIALI_URL:=http://localhost:${KIALI_PORT}}"

export ISTIO_NAMESPACE ISTIO_VERSION GATEWAY_API_VERSION KIALI_VERSION KIALI_PORT KIALI_URL
export KUBE_CONTEXT GITHUB_ORG DOCKER_USER DOCKER_PAT_SOURCE \
  CONCOURSE_NAMESPACE CONCOURSE_RELEASE CONCOURSE_CHART_VERSION CONCOURSE_IMAGE_TAG \
  CONCOURSE_PORT CONCOURSE_URL CONCOURSE_TEAM CONCOURSE_ADMIN_USER FLY_TARGET FLY_BIN \
  CONCOURSE_TEAM_NAMESPACE \
  ARGOCD_NAMESPACE ARGOCD_RELEASE ARGOCD_CHART_VERSION ARGOCD_PORT ARGOCD_URL ARGOCD_BIN
