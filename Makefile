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
AMTOOL_ROUTE := $(CHECK) --entrypoint amtool $(ALERTMANAGER_IMAGE) config routes test \
	--config.file=/config/alertmanager/alertmanager.yml

ANSIBLE_ROLES := linux_hardening observability_stack

LOCK_IMAGE := python:3.12.15-slim-trixie
UV_VERSION := 0.13.5

# Terraform tooling, pinned by digest (checked against Docker Hub and GHCR).
TERRAFORM_IMAGE := hashicorp/terraform:1.17.0@sha256:4d1b496a256f2989bccdb04b9104a4ede97234b10fba90259e173e905ec4fb58
TFLINT_IMAGE := ghcr.io/terraform-linters/tflint:v0.65.0@sha256:2788f4d4fc663c0e953b011b01bf443fe5bfce7587ee916e588e6057b85d6359
TRIVY_IMAGE := ghcr.io/aquasecurity/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c
TERRAFORM_MODULES := terraform/modules/network terraform/modules/monitoring_host
TERRAFORM_ROOTS := terraform/environments/example
# h1 checksums for these platforms; others verify against the registry's signed zh sums.
TERRAFORM_LOCK_PLATFORMS := linux_amd64 windows_amd64

# As the calling user, so .terraform/ and the caches in .cache/ can be removed without sudo.
TF_DOCKER := docker run --rm --volume "$(CURDIR):/work" --workdir /work --user "$$(id -u):$$(id -g)" --env HOME=/tmp
TERRAFORM := $(TF_DOCKER) --env TF_IN_AUTOMATION=1 --env CHECKPOINT_DISABLE=1 --env TF_PLUGIN_CACHE_DIR=/work/.cache/terraform \
	--env TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE=true \
	$(if $(TERRAFORM_PROVIDER_MIRROR),--volume "$(TERRAFORM_PROVIDER_MIRROR):/mirror:ro" --env TF_CLI_CONFIG_FILE=/work/terraform/mirror.tfrc) \
	$(TERRAFORM_IMAGE)
TFLINT := $(TF_DOCKER) --workdir /work/terraform --env TFLINT_PLUGIN_DIR=/work/.cache/tflint --env GITHUB_TOKEN $(TFLINT_IMAGE)

.PHONY: help env secrets up down destroy ps logs reload smoke check-dashboards dashboards validate test-rules lint ansible-lint test-ansible tools lock ci \
	terraform terraform-init terraform-fmt terraform-lint terraform-scan test-terraform terraform-lock

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

reload: ## Apply configuration changes (SIGHUP where supported, restart elsewhere)
	$(COMPOSE) kill --signal SIGHUP prometheus alertmanager
	$(COMPOSE) restart loki alloy grafana alert-sink

smoke: ## End-to-end check of the running stack
	python3 scripts/smoke_test.py $(SMOKE_ARGS)

check-dashboards: ## Run every dashboard query against the running stack
	python3 scripts/check_dashboards.py $(DASHBOARD_ARGS)

dashboards: ## Regenerate Grafana dashboards from tools/dashboards/build.py
	python3 tools/dashboards/build.py

validate: ## Validate Compose, Prometheus, Alertmanager, Loki and Alloy configuration
	$(COMPOSE) config --quiet
	$(CHECK) --entrypoint promtool $(PROMETHEUS_IMAGE) check config --syntax-only /config/prometheus/prometheus.yml
	@if ls config/prometheus/rules/*.yml >/dev/null 2>&1; then \
		$(CHECK) --entrypoint promtool $(PROMETHEUS_IMAGE) check rules $$(cd config && ls prometheus/rules/*.yml | sed 's|^|/config/|'); fi
	$(CHECK) --entrypoint amtool $(ALERTMANAGER_IMAGE) check-config /config/alertmanager/alertmanager.yml
	$(CHECK) $(LOKI_IMAGE) -config.file=/config/loki/loki.yml -verify-config
	$(CHECK) $(ALLOY_IMAGE) validate /config/alloy/config.alloy

test-rules: ## Unit-test alert rules (promtool) and Alertmanager routing (amtool)
	$(CHECK) --entrypoint promtool $(PROMETHEUS_IMAGE) test rules $$(cd config && ls prometheus/tests/*.test.yml | sed "s|^|/config/|")
	@$(AMTOOL_ROUTE) --verify.receivers=heartbeat alertname=Watchdog severity=none
	@$(AMTOOL_ROUTE) --verify.receivers=default alertname=TargetDown severity=critical
	@$(AMTOOL_ROUTE) --verify.receivers=default alertname=HostHighCpuUsage severity=warning
	@echo "routing tests passed"

lint: tools ## YAML, shell, dashboard and runbook checks
	$(TOOLS) yamllint --strict .
	docker run --rm --volume "$(CURDIR):/mnt:ro" --workdir /mnt $(SHELLCHECK_IMAGE) scripts/*.sh terraform/modules/*/files/*.sh
	$(TOOLS) python3 tools/dashboards/build.py --check
	$(TOOLS) python3 scripts/check_runbooks.py

ansible-lint: tools ## ansible-lint with the production profile
	docker run --rm --volume "$(CURDIR):/work" --workdir /work --env ANSIBLE_ROLES_PATH=/work/ansible/roles $(TOOLS_IMAGE) ansible-lint

# Molecule creates disposable test machines through the host's Docker daemon.
test-ansible: tools ## Molecule: apply the roles to disposable containers and verify them (ROLE=name for one)
	@for role in $(or $(ROLE),$(ANSIBLE_ROLES)); do \
		echo "== molecule test: $$role"; \
		docker run --rm --volume "$(CURDIR):/work" --volume /var/run/docker.sock:/var/run/docker.sock \
			--group-add "$$(stat -c %g /var/run/docker.sock)" --workdir "/work/ansible/roles/$$role" \
			--env ANSIBLE_FORCE_COLOR=1 --env MOLECULE_DOCKER_MIRROR=$(MOLECULE_DOCKER_MIRROR) \
			$(TOOLS_IMAGE) molecule test || exit 1; \
	done

tools: ## Build the tooling image (PIP_INDEX_URL=... for a PyPI mirror)
	docker build --quiet --tag $(TOOLS_IMAGE) $(if $(PIP_INDEX_URL),--build-arg PIP_INDEX_URL=$(PIP_INDEX_URL)) tools > /dev/null

lock: ## Re-resolve and hash-pin tools/requirements.txt
	docker run --rm --volume "$(CURDIR)/tools:/src" --workdir /src --user "$$(id -u):$$(id -g)" --env HOME=/tmp \
		$(if $(PIP_INDEX_URL),--env PIP_INDEX_URL=$(PIP_INDEX_URL) --env UV_DEFAULT_INDEX=$(PIP_INDEX_URL)) \
		$(LOCK_IMAGE) sh -c 'pip install --quiet --user uv==$(UV_VERSION) && \
		/tmp/.local/bin/uv pip compile --quiet --generate-hashes --python-version 3.12 \
		--python-platform x86_64-unknown-linux-gnu --custom-compile-command "make lock" \
		requirements.in --output-file requirements.txt'

terraform-init: ## Install providers for every Terraform module and environment (no backend)
	@mkdir -p .cache/terraform
	@for dir in $(TERRAFORM_MODULES); do \
		$(TERRAFORM) -chdir=$$dir init -backend=false -input=false -no-color > /dev/null || exit 1; done
	@# Environments must install exactly what their committed lock file pins.
	@for dir in $(TERRAFORM_ROOTS); do \
		$(TERRAFORM) -chdir=$$dir init -backend=false -input=false -no-color -lockfile=readonly > /dev/null || exit 1; done

terraform-fmt: ## Rewrite Terraform files in the canonical format
	$(TERRAFORM) fmt -recursive terraform

terraform-lint: terraform-init ## terraform fmt -check, terraform validate and tflint
	$(TERRAFORM) fmt -check -recursive -diff terraform
	@for dir in $(TERRAFORM_MODULES) $(TERRAFORM_ROOTS); do \
		printf '%s: ' "$$dir"; $(TERRAFORM) -chdir=$$dir validate -no-color || exit 1; done
	@mkdir -p .cache/tflint
	@$(TFLINT) --init > /dev/null
	$(TFLINT) --recursive --config /work/terraform/.tflint.hcl --format compact

terraform-scan: ## Trivy misconfiguration scan of the example environment and its modules
	@mkdir -p .cache/trivy
	$(TF_DOCKER) $(TRIVY_IMAGE) config --quiet --disable-telemetry --skip-version-check \
		--cache-dir /work/.cache/trivy --exit-code 1 \
		--severity MEDIUM,HIGH,CRITICAL --tf-vars terraform/environments/example/terraform.tfvars.example \
		terraform/environments/example

test-terraform: terraform-init ## terraform test with a mocked AWS provider (no account or credentials)
	@for dir in $(TERRAFORM_MODULES) $(TERRAFORM_ROOTS); do \
		echo "== $$dir"; $(TERRAFORM) -chdir=$$dir test -no-color || exit 1; done

terraform: terraform-lint terraform-scan test-terraform ## Every Terraform check that CI runs

terraform-lock: ## Re-pin provider checksums of the environments (needs registry.terraform.io)
	@for dir in $(TERRAFORM_ROOTS); do \
		$(TERRAFORM) -chdir=$$dir providers lock $(addprefix -platform=,$(TERRAFORM_LOCK_PLATFORMS)) || exit 1; done

ci: lint validate test-rules terraform ## Static checks that CI runs before the smoke test
