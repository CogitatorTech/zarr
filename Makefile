###############################################################################
# Configuration and Variables
################################################################################
ZIG_LOCAL  := $(HOME)/.local/share/zig/0.16.0/zig
ZIG        ?= $(shell test -x $(ZIG_LOCAL) && echo $(ZIG_LOCAL) || which zig)
BUILD_TYPE ?= Debug
BUILD_OPTS  = -Doptimize=$(BUILD_TYPE)
JOBS       ?= $(shell nproc || echo 2)
BUILD_DIR  := zig-out
CACHE_DIR  := .zig-cache
DOCS_DIR   := docs
DOCS_PORT  ?= 8085
RELEASE_MODE := ReleaseSmall

SHELL         := /usr/bin/env bash
.SHELLFLAGS   := -eu -o pipefail -c

################################################################################
# Targets
################################################################################

.PHONY: all build rebuild test format docs docs-serve clean release help shell setup-hooks test-hooks c-api interop
.DEFAULT_GOAL := help

help: ## Show the help messages for all targets
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' Makefile | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-12s %s\n", $$1, $$2}'

all: build test  ## Build and test

build: ## Build the static library (Mode=$(BUILD_TYPE))
	@echo "Building project in $(BUILD_TYPE) mode with $(JOBS) concurrent jobs..."
	$(ZIG) build $(BUILD_OPTS) -j$(JOBS)

rebuild: clean build  ## Clean and build

test: ## Run unit tests
	@echo "Running tests..."
	$(ZIG) build test $(BUILD_OPTS) -j$(JOBS)

c-api: ## Build the C Data Interface shared library (libzarr_c)
	@echo "Building the C Data Interface shared library..."
	$(ZIG) build c-api $(BUILD_OPTS) -j$(JOBS)

interop: c-api ## Round-trip the C Data Interface against pyarrow (skips if pyarrow absent)
	@echo "Running the pyarrow C Data Interface round-trip..."
	uv run python test/interop/roundtrip.py

release: ## Build in Release mode
	@echo "Building the project in Release mode..."
	@$(MAKE) BUILD_TYPE=$(RELEASE_MODE) build

format: ## Format Zig files
	@echo "Formatting Zig files..."
	$(ZIG) fmt .

docs: ## Generate API documentation into docs/api from src/lib.zig
	@echo "Generating API documentation into $(DOCS_DIR)/api..."
	@mkdir -p $(DOCS_DIR)/api
	$(ZIG) build docs --prefix $(DOCS_DIR) -j$(JOBS)

docs-serve: docs ## Serve the API documentation on http://localhost:$(DOCS_PORT)
	@echo "Serving docs at http://localhost:$(DOCS_PORT) (Ctrl-C to stop)..."
	python3 -m http.server $(DOCS_PORT) --directory $(DOCS_DIR)/api

clean: ## Remove build artifacts, cache, and generated docs
	@echo "Removing build artifacts, cache, and generated docs..."
	rm -rf $(BUILD_DIR) $(CACHE_DIR) $(DOCS_DIR)/api

shell: ## Enter the Nix development shell (requires Nix with flakes)
	@echo "Entering the Nix development shell..."
	nix develop

setup-hooks: ## Install Git hooks (pre-commit and pre-push)
	@echo "Installing Git hooks..."
	@pre-commit install --hook-type pre-commit
	@pre-commit install --hook-type pre-push
	@pre-commit install-hooks

test-hooks: ## Run Git hooks on all files manually
	@echo "Running Git hooks..."
	@pre-commit run --all-files
