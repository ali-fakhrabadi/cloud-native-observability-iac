# Operator interface for the observability stack. Everything runs in containers: the only
# host requirements are Docker (Compose v2), GNU make, bash, openssl and python3.

# Optional settings such as PIP_INDEX_URL come from .env, like the stack configuration.
-include .env

COMPOSE := docker compose -f docker-compose.observability.yml

# Validation runs the exact binaries of the pinned images.
PROMETHEUS_IMAGE := prom/prometheus:v3.15.1
ALERTMANAGER_IMAGE := prom/alertmanager:v0.34.1
LOKI_IMAGE := grafana/loki:3.7.9
ALLOY_IMAGE := grafana/alloy:v1.21.2
SHELLCHECK_IMAGE := koalaman/shellcheck:v0.11.0

TOOLS_IMAGE := observability-tools:local
TOOLS := docker run --rm --volume "$(CURDIR):/work" --workdir /work $(TOOLS_IMAGE)
CHECK := docker run --rm --volume "$(CURDIR)/config:/config:ro"

LOCK_IMAGE := python:3.12.15-slim-trixie
UV_VERSION := 0.13.5

.PHONY: help env secrets up down destroy ps logs reload smoke validate lint tools lock ci

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_.-]+:.*## / {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

env: ## Create .env from .env.example (never overwrites)
	@test -f .env && echo ".env exists, left unchanged" || (cp .env.example .env && echo "created .env")

secrets: ## Generate missing secrets in ./secrets (never overwrites)
	@bash scripts/generate_secrets.sh

up: ## Start the stack and wait until every service is healthy
	@test -s secrets/grafana_admin_password || (echo "run 'make secrets' first" && exit 1)
	$(COMPOSE) up --detach --wait --wait-timeout 180 --remove-orphans

down: ## Stop the stack (data volumes are kept)
	$(COMPOSE) down

destroy: ## Stop the stack and DELETE all metrics, logs and dashboard state
	$(COMPOSE) down --volumes

ps: ## Service status
	$(COMPOSE) ps

logs: ## Follow logs (SERVICE=grafana to filter)
	$(COMPOSE) logs --follow --tail 100 $(SERVICE)

reload: ## Re-read Prometheus and Alertmanager configuration without a restart
	$(COMPOSE) kill --signal SIGHUP prometheus alertmanager

smoke: ## End-to-end check of the running stack
	python3 scripts/smoke_test.py $(SMOKE_ARGS)

validate: ## Validate Compose, Prometheus, Alertmanager, Loki and Alloy configuration
	$(COMPOSE) config --quiet
	$(CHECK) --entrypoint promtool $(PROMETHEUS_IMAGE) check config --syntax-only /config/prometheus/prometheus.yml
	@if ls config/prometheus/rules/*.yml >/dev/null 2>&1; then \
		$(CHECK) --entrypoint promtool $(PROMETHEUS_IMAGE) check rules $$(cd config && ls prometheus/rules/*.yml | sed 's|^|/config/|'); fi
	$(CHECK) --entrypoint amtool $(ALERTMANAGER_IMAGE) check-config /config/alertmanager/alertmanager.yml
	$(CHECK) $(LOKI_IMAGE) -config.file=/config/loki/loki.yml -verify-config
	$(CHECK) $(ALLOY_IMAGE) validate /config/alloy/config.alloy

lint: tools ## YAML and shell linting
	$(TOOLS) yamllint --strict .
	docker run --rm --volume "$(CURDIR):/mnt:ro" --workdir /mnt $(SHELLCHECK_IMAGE) scripts/*.sh

tools: ## Build the linting image (PIP_INDEX_URL=... for a PyPI mirror)
	docker build --quiet --tag $(TOOLS_IMAGE) $(if $(PIP_INDEX_URL),--build-arg PIP_INDEX_URL=$(PIP_INDEX_URL)) tools > /dev/null

lock: ## Re-resolve and hash-pin tools/requirements.txt
	docker run --rm --volume "$(CURDIR)/tools:/src" --workdir /src --user "$$(id -u):$$(id -g)" --env HOME=/tmp \
		$(if $(PIP_INDEX_URL),--env PIP_INDEX_URL=$(PIP_INDEX_URL) --env UV_DEFAULT_INDEX=$(PIP_INDEX_URL)) \
		$(LOCK_IMAGE) sh -c 'pip install --quiet --user uv==$(UV_VERSION) && \
		/tmp/.local/bin/uv pip compile --quiet --generate-hashes --python-version 3.12 \
		--python-platform x86_64-unknown-linux-gnu --custom-compile-command "make lock" \
		requirements.in --output-file requirements.txt'

ci: lint validate ## Static checks that CI runs before the smoke test
