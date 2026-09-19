#!/bin/sh
# Packages a Helm chart from the repo and pushes it to Docker Hub as an OCI artifact, pinned to
# the image that was just built — so "chart version X" always deploys "image version X" and
# Argo CD can never roll out a chart whose image does not exist yet.
#
# Why the chart is renamed on the way out: `helm push` names the OCI repository after the chart,
# and on Docker Hub that would be <user>/<chart> — the same repository as the image, with
# colliding version tags. Publishing as "<chart>-chart" gives each its own repository:
#     docker.io/<user>/slates:0.1.0-ci.412          (image)
#     oci://registry-1.docker.io/<user>/slates-chart  --version 0.1.0-ci.412   (chart)
# The repo's own Chart.yaml is never modified; only the packaged copy is.
#
# Inputs : repo/, version/version
# Params : CHART_PATH            chart directory inside the repo
#          CHART_NAME            published chart name, e.g. slates-chart
#          VALUES_EXPR           yq expression applied to values.yaml. $IMAGE_REPOSITORY and
#                                $VERSION are available to it via env()/strenv().
#          IMAGE_REPOSITORY      e.g. adalundhe/slates
#          REGISTRY_NAMESPACE    Docker Hub user/org that receives the chart
#          REGISTRY_USERNAME / REGISTRY_PASSWORD
set -eu

: "${CHART_PATH:?}" "${CHART_NAME:?}" "${VALUES_EXPR:?}" "${IMAGE_REPOSITORY:?}"
: "${REGISTRY_NAMESPACE:?}" "${REGISTRY_USERNAME:?}" "${REGISTRY_PASSWORD:?}"
: "${REGISTRY_HOST:=registry-1.docker.io}"

apk add --no-cache helm yq >/dev/null

VERSION="$(cat version/version)"
export VERSION IMAGE_REPOSITORY

[ -f "repo/$CHART_PATH/Chart.yaml" ] || { echo "no Chart.yaml under repo/$CHART_PATH" >&2; exit 1; }
work="$(mktemp -d)"
cp -R "repo/$CHART_PATH" "$work/$CHART_NAME"

original_name="$(yq -r '.name' "$work/$CHART_NAME/Chart.yaml")"
CHART_NAME="$CHART_NAME" yq -i '.name = strenv(CHART_NAME)' "$work/$CHART_NAME/Chart.yaml"
yq -i "$VALUES_EXPR" "$work/$CHART_NAME/values.yaml"

echo "chart   : $original_name -> $CHART_NAME $VERSION"
echo "image   : $IMAGE_REPOSITORY:$VERSION"
echo "--- values.yaml changes:"
diff -u "repo/$CHART_PATH/values.yaml" "$work/$CHART_NAME/values.yaml" | sed -n '3,40p' || true

helm package "$work/$CHART_NAME" --version "$VERSION" --app-version "$VERSION" --destination "$work/out"

# --password-stdin keeps the token out of argv; Concourse additionally redacts it from logs.
printf '%s' "$REGISTRY_PASSWORD" |
  helm registry login "$REGISTRY_HOST" --username "$REGISTRY_USERNAME" --password-stdin
helm push "$work/out/$CHART_NAME-$VERSION.tgz" "oci://$REGISTRY_HOST/$REGISTRY_NAMESPACE"
helm registry logout "$REGISTRY_HOST" >/dev/null 2>&1 || true

echo "published oci://$REGISTRY_HOST/$REGISTRY_NAMESPACE/$CHART_NAME:$VERSION"
