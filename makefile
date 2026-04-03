.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\n\033[1;31mUsage:\033[0m\n  make \033[3;1;36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1;31m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Labels

.PHONY: labels
labels: ## Sync GitHub labels from .github/labels.yml (requires gh CLI with repo write access)
	python3 scripts/sync_labels.py

##@ Development

.PHONY: license-fmt
license-fmt: ## adds license header to code.
	python3 ./scripts/format_license.py --root-dir . --license-file ./LICENSE

.PHONY: test-deps
test-deps: ## Install Python test dependencies
	@if [ ! -d "venv" ]; then \
		echo "Creating virtual environment..."; \
		python3 -m venv venv; \
	fi
	./venv/bin/pip install -r tests/requirements.txt

.PHONY: test
test: test-deps ## Run Docker-based tests (in parallel)
	@if [ -n "$$TEST_WORKERS" ]; then \
		./venv/bin/pytest tests/integration/ -n $$TEST_WORKERS -v --durations=10 --durations-min=10.0; \
	else \
		./venv/bin/pytest tests/integration/ -n auto -v --durations=10 --durations-min=10.0; \
	fi

.PHONY: test-package
test-package: test-deps ## Run tests for a specific package. Usage: make test-package PACKAGE=<package-name>
	@if [ -z "$(PACKAGE)" ]; then \
		echo "ERROR: PACKAGE variable is required. Usage: make test-package PACKAGE=<package-name>"; \
		exit 1; \
	fi
	@# Convert package name from hyphen to underscore for test directory (e.g., nvidia-setup -> nvidia_setup)
	@TEST_PACKAGE=$$(echo "$(PACKAGE)" | tr '-' '_'); \
	TEST_DIR="tests/integration/$$TEST_PACKAGE"; \
	if [ ! -d "$$TEST_DIR" ]; then \
		echo "WARNING: Test directory $$TEST_DIR not found for package $(PACKAGE). Skipping tests."; \
		exit 0; \
	fi; \
	echo "Running tests for package: $(PACKAGE) (test directory: $$TEST_DIR)"; \
	if [ -n "$$TEST_WORKERS" ]; then \
		./venv/bin/pytest $$TEST_DIR -n $$TEST_WORKERS -v --durations=10 --durations-min=10.0; \
	else \
		./venv/bin/pytest $$TEST_DIR -n auto -v --durations=10 --durations-min=10.0; \
	fi


##@ Changelog

.PHONY: changelog
changelog: ## Generate/update CHANGELOG.md for a package. Usage: make changelog PACKAGE=nvidia-setup
	@if [ -z "$(PACKAGE)" ]; then \
		echo "ERROR: PACKAGE is required. Usage: make changelog PACKAGE=nvidia-setup"; \
		exit 1; \
	fi
	git cliff \
		--include-path "$(PACKAGE)/**" \
		--tag-pattern "$(PACKAGE)/.*" \
		-o $(PACKAGE)/CHANGELOG.md
	@echo "Updated $(PACKAGE)/CHANGELOG.md"

.PHONY: changelog-preview
changelog-preview: ## Preview unreleased changes for a package. Usage: make changelog-preview PACKAGE=nvidia-setup
	@if [ -z "$(PACKAGE)" ]; then \
		echo "ERROR: PACKAGE is required. Usage: make changelog-preview PACKAGE=nvidia-setup"; \
		exit 1; \
	fi
	git cliff \
		--include-path "$(PACKAGE)/**" \
		--tag-pattern "$(PACKAGE)/.*" \
		--unreleased \
		--strip header

##@ Validation

.PHONY: validate-standalone
validate-standalone: ## Validate a standalone package (not inherited). Usage: make validate-standalone PACKAGE=<package-name>
	@if [ -z "$(PACKAGE)" ]; then \
		echo "ERROR: PACKAGE variable is required. Usage: make validate-standalone PACKAGE=<package-name>"; \
		exit 1; \
	fi
	@if [ ! -f "$(PACKAGE)/config.json" ]; then \
		echo "ERROR: config.json not found for package $(PACKAGE)"; \
		exit 1; \
	fi
	@echo "Validating standalone package: $(PACKAGE)"
	@CONTAINER_CMD=$$(command -v podman >/dev/null 2>&1 && echo podman || echo docker); \
	$$CONTAINER_CMD run --rm \
		--entrypoint python \
		-v $(PWD):/workspace \
		-w /workspace \
		ghcr.io/nvidia/skyhook/agent:latest \
		/workspace/scripts/validate.py /workspace/$(PACKAGE)/config.json

.PHONY: validate-inherited
validate-inherited: ## Validate an inherited package (inherits from skyhook-packages). Usage: make validate-inherited PACKAGE=<package-name>
	@if [ -z "$(PACKAGE)" ]; then \
		echo "ERROR: PACKAGE variable is required. Usage: make validate-inherited PACKAGE=<package-name>"; \
		exit 1; \
	fi
	@if [ ! -f "$(PACKAGE)/Dockerfile" ]; then \
		echo "ERROR: Dockerfile not found for package $(PACKAGE)"; \
		exit 1; \
	fi
	@if ! grep -q "^FROM.*skyhook-packages" "$(PACKAGE)/Dockerfile"; then \
		echo "ERROR: Package $(PACKAGE) does not inherit from skyhook-packages. Use 'make validate-standalone' instead."; \
		exit 1; \
	fi
	@echo "Building container for validation: $(PACKAGE)"
	@VALIDATION_IMAGE="skyhook-packages-validation-$(PACKAGE):temp"; \
	EXTRACT_DIR="$(PWD)/.validation-extract-$(PACKAGE)"; \
	CONTAINER_CMD=$$(command -v podman >/dev/null 2>&1 && echo podman || echo docker); \
	$$CONTAINER_CMD build --tag $$VALIDATION_IMAGE $(PACKAGE) || { \
		echo "ERROR: Failed to build container for validation"; \
		exit 1; \
	}; \
	echo "Extracting /skyhook-package from built container..."; \
	mkdir -p $$EXTRACT_DIR; \
	$$CONTAINER_CMD create --name validation-extract-temp $$VALIDATION_IMAGE || true; \
	$$CONTAINER_CMD cp validation-extract-temp:/skyhook-package $$EXTRACT_DIR/ || { \
		echo "ERROR: Failed to extract /skyhook-package from container"; \
		$$CONTAINER_CMD rm validation-extract-temp || true; \
		rm -rf $$EXTRACT_DIR; \
		exit 1; \
	}; \
	$$CONTAINER_CMD rm validation-extract-temp; \
	echo "Validating package: $(PACKAGE)"; \
	$$CONTAINER_CMD run --rm \
		--entrypoint python \
		-v $$EXTRACT_DIR/skyhook-package:/skyhook-package:ro \
		-v $(PWD)/scripts/validate.py:/tmp/validate.py:ro \
		ghcr.io/nvidia/skyhook/agent:latest \
		/tmp/validate.py /skyhook-package/config.json || { \
		echo "ERROR: Validation failed for $(PACKAGE)"; \
		$$CONTAINER_CMD rmi $$VALIDATION_IMAGE || true; \
		rm -rf $$EXTRACT_DIR; \
		exit 1; \
	}; \
	echo "✓ Validation passed for $(PACKAGE)"; \
	$$CONTAINER_CMD rmi $$VALIDATION_IMAGE || true; \
	rm -rf $$EXTRACT_DIR