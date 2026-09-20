# Thin, discoverable wrappers around scripts/. Every target is idempotent.
.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help bootstrap preflight dns concourse argocd istio kiali grafana metrics-server chaos-mesh tilt credentials login secrets warm pipelines access open status focal-invitations slates-identities check

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

bootstrap: ## Empty cluster -> working platform (run this first, and after any cluster reset)
	@scripts/bootstrap.sh

preflight: ## Check tools, cluster, ports and DOCKER_PAT without changing anything
	@scripts/00-preflight.sh

dns: ## Harden CoreDNS (fallback resolvers + longer cache); re-applied by bootstrap after a reset
	@scripts/05-cluster-dns.sh

concourse: ## Install/upgrade Concourse (after editing concourse/values.yaml)
	@scripts/10-concourse-secrets.sh && scripts/20-concourse.sh

argocd: ## Install/upgrade Argo CD and re-apply argocd/projects + argocd/apps
	@scripts/30-argocd.sh

istio: ## Install/upgrade Istio (ambient mode) + Gateway API CRDs
	@scripts/35-istio.sh

kiali: ## Install/upgrade Kiali (the Istio UI) + Prometheus
	@scripts/37-kiali.sh

grafana: ## Install/upgrade Grafana with Istio's dashboards (generated admin password)
	@scripts/38-grafana.sh

metrics-server: ## Install/upgrade metrics-server (kubectl top, HPAs)
	@scripts/32-metrics-server.sh

chaos-mesh: ## Install/upgrade Chaos Mesh (pod + network fault injection) and its dashboard
	@scripts/39-chaos-mesh.sh

tilt: ## Install the Tilt CLI for the inner dev loop (see examples/tilt)
	@scripts/80-tilt.sh

credentials: ## Verify DOCKER_PAT with Docker Hub and (re)install it in the cluster
	@scripts/40-registry-credentials.sh

login: ## Install fly + argocd CLIs if needed and log both in (fly tokens last 24h)
	@scripts/50-cli-login.sh

secrets: ## Refresh the git-ignored .secrets/credentials.env from the cluster
	@scripts/60-local-secrets.sh

warm: ## Pre-pull every pipeline base image into Concourse's cache, one at a time
	@scripts/65-warm-images.sh

pipelines: ## Set + unpause every pipeline from the working tree
	@scripts/70-pipelines.sh

access: ## Print UI URLs, usernames and passwords
	@scripts/access.sh

open: ## Open both UIs in the browser
	@scripts/access.sh --no-passwords --open

status: ## Pods, workers, pipelines, latest builds, Argo CD apps
	@scripts/status.sh

focal-invitations: ## One-time: mint focal host invitations after its first sync
	@scripts/apps/focal-invitations.sh

slates-identities: ## One-time: mint slates pod identities so its chart can render
	@scripts/apps/slates-identities.sh

check: ## Validate every pipeline + script, and scan the tree for secrets
	@scripts/check.sh
