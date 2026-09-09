# claudex image build and verification.
#
# Local builds are single-architecture and use whichever engine is installed.
# Multi-architecture builds and registry pushes happen in CI; see
# .github/workflows/release.yml.

SHELL := /bin/bash
.DEFAULT_GOAL := help

ENGINE ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)
REGISTRY ?= ghcr.io
NAMESPACE ?= colossaltuna
NAME ?= claudex
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
PLATFORMS ?= linux/amd64,linux/arm64

BASE_IMAGE := $(REGISTRY)/$(NAMESPACE)/$(NAME)-base
CLAUDE_IMAGE := $(REGISTRY)/$(NAMESPACE)/$(NAME)-claude
CODEX_IMAGE := $(REGISTRY)/$(NAMESPACE)/$(NAME)-codex

# Agent versions float by default. Pin them for a reproducible build:
#   make build CLAUDE_CODE_VERSION=2.1.266 CODEX_VERSION=0.153.4
CLAUDE_CODE_VERSION ?= latest
CODEX_VERSION ?= latest

BUILD_ARGS := \
	--build-arg CLAUDE_CODE_VERSION=$(CLAUDE_CODE_VERSION) \
	--build-arg CODEX_VERSION=$(CODEX_VERSION)

WORKSPACE ?= $(CURDIR)

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

## --- build ----------------------------------------------------------------

.PHONY: build
build: build-base build-claude build-codex ## Build all three images for the host architecture

.PHONY: build-base
build-base: ## Build the base image (all tooling, no agent)
	$(ENGINE) build --target base $(BUILD_ARGS) -t $(BASE_IMAGE):$(VERSION) -t $(BASE_IMAGE):latest -f Containerfile .

.PHONY: build-claude
build-claude: ## Build the Claude Code image
	$(ENGINE) build --target claude $(BUILD_ARGS) -t $(CLAUDE_IMAGE):$(VERSION) -t $(CLAUDE_IMAGE):latest -f Containerfile .

.PHONY: build-codex
build-codex: ## Build the Codex image
	$(ENGINE) build --target codex $(BUILD_ARGS) -t $(CODEX_IMAGE):$(VERSION) -t $(CODEX_IMAGE):latest -f Containerfile .

## --- verify ---------------------------------------------------------------

.PHONY: test
test: test-base test-claude test-codex test-arbitrary-uid ## Run the smoke test against every image

.PHONY: test-base
test-base: ## Smoke test the base image
	$(ENGINE) run --rm $(BASE_IMAGE):$(VERSION) claudex-smoke

.PHONY: test-claude
test-claude: ## Smoke test the Claude Code image
	$(ENGINE) run --rm $(CLAUDE_IMAGE):$(VERSION) claudex-smoke

.PHONY: test-codex
test-codex: ## Smoke test the Codex image
	$(ENGINE) run --rm $(CODEX_IMAGE):$(VERSION) claudex-smoke

.PHONY: test-arbitrary-uid
test-arbitrary-uid: ## Smoke test the base image under an unknown UID (OpenShift-style)
	$(ENGINE) run --rm --user 1000670000:0 $(BASE_IMAGE):$(VERSION) claudex-smoke

.PHONY: lint
lint: lint-containerfile lint-shell lint-helm ## Run every linter

.PHONY: lint-containerfile
lint-containerfile: ## Lint the Containerfile with hadolint
	$(ENGINE) run --rm -i -v $(CURDIR)/.hadolint.yaml:/.hadolint.yaml:ro hadolint/hadolint:latest-debian hadolint --config /.hadolint.yaml - < Containerfile

.PHONY: lint-shell
lint-shell: ## Lint the shell scripts with shellcheck
	$(ENGINE) run --rm -v $(CURDIR):/mnt:ro -w /mnt koalaman/shellcheck:stable \
		scripts/claudex-entrypoint scripts/claudex-claude scripts/claudex-codex \
		scripts/claudex-upgrade scripts/claudex-smoke scripts/claudex-lib.sh scripts/profile.sh

.PHONY: lint-helm
lint-helm: ## Lint and render the Helm chart
	helm lint deploy/helm/claudex
	helm template claudex deploy/helm/claudex > /dev/null

.PHONY: versions
versions: ## Print the tool and agent versions baked into the built images
	@$(ENGINE) run --rm $(CLAUDE_IMAGE):$(VERSION) bash -lc 'node --version; python3 --version; uv --version; claude --version'
	@$(ENGINE) run --rm $(CODEX_IMAGE):$(VERSION) bash -lc 'codex --version'

.PHONY: size
size: ## Report the size of each built image
	@$(ENGINE) images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep '$(NAME)-' || true

## --- run ------------------------------------------------------------------

.PHONY: shell
shell: ## Interactive shell in the base image with the repo mounted at /workspace
	$(ENGINE) run --rm -it -v $(WORKSPACE):/workspace:z $(BASE_IMAGE):$(VERSION) bash

.PHONY: run-claude
run-claude: ## Run Claude Code Remote Control against $(WORKSPACE)
	$(ENGINE) run --rm -it \
		-v $(WORKSPACE):/workspace:z \
		-v claudex-home:/home/dev \
		$(CLAUDE_IMAGE):$(VERSION)

.PHONY: run-codex
run-codex: ## Run the Codex app-server against $(WORKSPACE)
	$(ENGINE) run --rm -it \
		-v $(WORKSPACE):/workspace:z \
		-v claudex-home:/home/dev \
		$(CODEX_IMAGE):$(VERSION)

.PHONY: compose-up
compose-up: ## Start both agents with the reference compose file
	$(ENGINE) compose -f deploy/compose.yaml up

.PHONY: compose-down
compose-down: ## Stop the compose stack
	$(ENGINE) compose -f deploy/compose.yaml down

## --- publish --------------------------------------------------------------

.PHONY: push
push: ## Refuse to push by hand; publishing happens on a v* git tag in CI
	@echo "Images are published by .github/workflows/release.yml on a v* tag." >&2
	@echo "Tag a release instead:  git tag v0.1.0 && git push origin v0.1.0" >&2
	@exit 1

.PHONY: clean
clean: ## Remove locally built images
	-$(ENGINE) rmi $(BASE_IMAGE):$(VERSION) $(BASE_IMAGE):latest \
		$(CLAUDE_IMAGE):$(VERSION) $(CLAUDE_IMAGE):latest \
		$(CODEX_IMAGE):$(VERSION) $(CODEX_IMAGE):latest 2>/dev/null
