# SweeTTY instance-template helpers.
#
# Most real work happens on the honeypot host (provision.sh, deploy.sh). These
# targets are thin convenience wrappers plus the local checks that gate a
# commit. Pass TAG=vX.Y.Z to deploy.

SHELL := /bin/bash
ENV_FILE ?= sweetty.instance.env
SLOTDEPLOY_CONFIG ?= deploy/slotdeploy.yaml

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: check
check: check-emdash lint firewall-check haproxy-check ## Run every local gate (CI runs this)

.PHONY: check-emdash
check-emdash: ## Fail if an em dash appears in any tracked file
	@if git ls-files -z | xargs -0 grep -nP '\xe2\x80\x94' 2>/dev/null; then \
		echo "em dash found in a tracked file; remove it"; exit 1; \
	else \
		echo "no em dash in tracked files"; \
	fi

.PHONY: lint
lint: ## Shellcheck the scripts when shellcheck is installed
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bootstrap.sh provision/provision.sh provision/render-nftables.sh deploy/deploy.sh; \
	else \
		echo "shellcheck not installed; skipping (CI runs it)"; \
	fi

.PHONY: firewall-check
firewall-check: ## Render and syntax-check the nftables ruleset (needs nft)
	@if command -v nft >/dev/null 2>&1; then \
		provision/render-nftables.sh && nft -c -f /tmp/sweetty.nft.rendered && echo "nftables ruleset is valid"; \
	else \
		echo "nft not installed; skipping (run on the host or in CI)"; \
	fi

.PHONY: haproxy-check
haproxy-check: ## Syntax-check the optional HAProxy config (needs haproxy)
	@if command -v haproxy >/dev/null 2>&1; then \
		haproxy -c -f haproxy/haproxy.cfg && echo "haproxy config is valid"; \
	else \
		echo "haproxy not installed; skipping (run on the host or in CI)"; \
	fi

.PHONY: provision
provision: ## Provision the host (run ON the host, as root)
	sudo INSTANCE_ENV=$(ENV_FILE) provision/provision.sh

.PHONY: deploy
deploy: ## Deploy a pinned release: make deploy TAG=v0.3.0
	@test -n "$(TAG)" || { echo "set TAG=vX.Y.Z (never 'latest')"; exit 1; }
	deploy/deploy.sh $(TAG)

.PHONY: rollback
rollback: ## Roll back to the previously active slot
	slotdeploy rollback --config $(SLOTDEPLOY_CONFIG)

.PHONY: status
status: ## Show the active slot and deployed release
	slotdeploy status --config $(SLOTDEPLOY_CONFIG)
