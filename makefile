.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\n\033[1;31mUsage:\033[0m\n  make \033[3;1;36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1;31m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Labels

.PHONY: labels
labels: ## Sync GitHub labels from .github/labels.yml (requires gh CLI with repo write access)
	python3 scripts/sync_labels.py

##@ Development

# License headers are managed by google/addlicense, run straight from its Go
# module with `go run` (needs a local Go toolchain; no container, no vendored
# binary). addlicense never duplicates a header (it skips files that already have
# one), so it is idempotent, unlike the old scripts/format_license.py it replaced
# (see #74). The canonical style is the full Apache 2.0 block in
# .github/license-header.tmpl. Scope mirrors the old tool: Python, shell, YAML,
# and Dockerfiles, excluding chart/ and vendored trees. Docs (*.md and similar)
# intentionally carry no header.
ADDLICENSE_VERSION := v1.2.0
ADDLICENSE := go run github.com/google/addlicense@$(ADDLICENSE_VERSION)
# addlicense v1.2.0 does not expand `**` in path arguments, so we pass an explicit
# file list from git (tracked files only, with chart/ and vendored trees excluded).
LICENSE_FILES = $(shell git ls-files '*.py' '*.sh' '*.yaml' '*.yml' 'Dockerfile' '*/Dockerfile' ':!:chart/**' ':!:**/vendor/**' ':!:**/node_modules/**')

.PHONY: license-fmt
license-fmt: ## Add Apache license headers to source files (google/addlicense; idempotent).
	@$(ADDLICENSE) -f .github/license-header.tmpl $(LICENSE_FILES)

.PHONY: license-check
license-check: ## Verify in-scope source files carry a license header (CI gate).
	@$(ADDLICENSE) -check -f .github/license-header.tmpl $(LICENSE_FILES)

.PHONY: test-deps
test-deps: ## Install Python test dependencies
	@if [ ! -d "venv" ]; then \
		echo "Creating virtual environment..."; \
		python3 -m venv venv; \
	fi
	./venv/bin/pip install -r tests/requirements.txt

.PHONY: test-base-images
test-base-images: test-deps ## Build prebuilt test base images for a package. Usage: make test-base-images PACKAGE=<name> [NO_CACHE=1]
	@if [ -z "$(PACKAGE)" ]; then \
		echo "ERROR: PACKAGE variable is required. Usage: make test-base-images PACKAGE=<package-name>"; \
		exit 1; \
	fi
	@./venv/bin/python scripts/build_test_base_images.py --package "$(PACKAGE)" $(if $(NO_CACHE),--no-cache)

.PHONY: test
test: test-deps ## Run Docker-based tests (in parallel)
	@for pkg in $$(ls tests/integration | grep -v '^__'); do \
		./venv/bin/python scripts/build_test_base_images.py --package "$$pkg" || exit 1; \
	done
	@if [ -n "$$TEST_WORKERS" ]; then \
		./venv/bin/pytest tests/integration/ -n $$TEST_WORKERS -v --durations=10 --durations-min=10.0; \
	else \
		./venv/bin/pytest tests/integration/ -n auto -v --durations=10 --durations-min=10.0; \
	fi

.PHONY: test-harness
test-harness: test-deps ## Run tests for the shared Docker test harness itself
	./venv/bin/pytest tests/helpers/ -v

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

# Changelogs are generated from git history by scripts/gen-changelog.sh, which
# takes release boundaries from `git tag` (a single `git cliff --include-path`
# call drops most release sections in this monorepo). CHANGELOG.md is machine-
# owned; hand-authored notes live in the sibling RELEASE_NOTES.md. See
# docs/release-process.md.

.PHONY: changelog
changelog: ## Regenerate a package CHANGELOG.md. Interactive picker with no PACKAGE; one-shot with PACKAGE=nvidia-setup [VERSION=0.3.0 to label the cut version]. Machine-owned; do not hand-edit.
	@bash scripts/gen-changelog.sh $(PACKAGE) $(VERSION)

.PHONY: changelog-preview
changelog-preview: ## Preview unreleased changes for a package. Usage: make changelog-preview PACKAGE=nvidia-setup
	@if [ -z "$(PACKAGE)" ]; then \
		echo "ERROR: PACKAGE is required. Usage: make changelog-preview PACKAGE=nvidia-setup"; \
		exit 1; \
	fi
	@git cliff \
		--offline \
		--include-path "$(PACKAGE)/**" \
		--tag-pattern "$(PACKAGE)/.*" \
		--unreleased \
		--strip all

.PHONY: release-tag
release-tag: ## Interactively cut a release tag: prompts for package + bump (+ optional RC), creates the tag, and optionally pushes it (push triggers the CI release).
	@bash scripts/release-tag.sh

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
	@if ! grep -Eq "^FROM.*(skyhook|nodewright)-packages" "$(PACKAGE)/Dockerfile"; then \
		echo "ERROR: Package $(PACKAGE) does not inherit from skyhook-packages or nodewright-packages. Use 'make validate-standalone' instead."; \
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