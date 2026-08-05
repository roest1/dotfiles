# roest-nvim/Makefile
#
# Portable installer for macOS, Linux (WSL), and Fedora/RHEL.
# Every target is idempotent — safe to re-run.
#
# Usage:
#   make              Show help
#   make deps         Install nvim + external deps (via ../deps.conf)
#   make sync         Install/update plugins + compile TS parsers (headless)
#   make update       git pull + deps + sync
#   make clean        Wipe plugin + cache state (matches :ResetNvim)
#   make all          deps + sync
#
# Verify install with :checkhealth external inside nvim.

SHELL := /bin/bash
.DEFAULT_GOAL := help

UNAME := $(shell uname -s)
NVIM_DIR := $(shell cd "$(dir $(abspath $(lastword $(MAKEFILE_LIST))))" && pwd)

# Paths wiped by `make clean` — matches lua/external/reset.lua
CLEAN_PATHS := $(HOME)/.local/share/nvim $(HOME)/.cache/nvim

# --------------------------------------------------------------------------- #
#  Targets                                                                     #
# --------------------------------------------------------------------------- #

.PHONY: help all deps sync servers update clean

# How long a package version must have existed before we'll resolve to it.
# Malicious releases are typically detected and unpublished within hours, so
# refusing brand-new versions sidesteps the window where a compromised release
# is live but not yet caught. 7 days.
#
# This only affects RESOLUTION, which is why it lives on `servers` and not on
# the install steps: those all run --frozen-lockfile and resolve nothing.
SERVER_COOLDOWN := 604800

help: ## Show this help
	@echo ""
	@echo "roest-nvim — $(UNAME)"
	@echo ""
	@echo "  Not sure?  First time → make all    •    Updating → make update"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  make %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""

all: deps sync ## Install everything (deps + sync)

deps: ## Install nvim + external deps (delegates to the repo manifest)
	@# The toolchain is declared in ../deps.conf, so there is one source of
	@# truth. deps.sh here is only platform fixups and runs as part of that.
	@$(MAKE) --no-print-directory -C "$(NVIM_DIR)/.." install nvim

sync: ## Install/update plugins + compile TS parsers (headless)
	@command -v nvim >/dev/null 2>&1 || { echo "nvim not found — run 'make deps' first"; exit 1; }
	@echo ""
	@echo "Syncing lazy.nvim plugins..."
	@nvim --headless "+Lazy! sync" +qa 2>&1 | tail -20
	@echo ""
	@echo "Updating tree-sitter parsers..."
	@nvim --headless "+TSUpdate" +qa 2>&1 | tail -5
	@echo ""
	@echo "Done."

# Note: `bun update` also rewrites the declared ranges in package.json to match
# what it resolved (^5.7.0 becomes ^5.9.3). That is bun's behaviour, not a bug
# here, but it means this target always dirties package.json even when no
# resolved version moved — so read the diff before committing rather than
# assuming an empty run left nothing behind.
servers: ## Update the JS language servers (cooldown applied, regenerates yarn.lock)
	@command -v bun >/dev/null 2>&1 || { echo "bun not found — run 'make deps' first"; exit 1; }
	@echo ""
	@echo "Updating language servers (ignoring releases newer than $$(( $(SERVER_COOLDOWN) / 86400 )) days)..."
	@cd "$(NVIM_DIR)/lsp-servers" && bun update --minimum-release-age=$(SERVER_COOLDOWN)
	@# yarn.lock is generated output that exists only so GitHub's dependency
	@# graph can read the tree. Regenerate it in the same breath, because CI
	@# fails if the two disagree and forgetting is the obvious way to trip it.
	@cd "$(NVIM_DIR)/lsp-servers" && bun install --yarn
	@echo ""
	@echo "Checking for advisories..."
	@cd "$(NVIM_DIR)/lsp-servers" && bun audit || true
	@echo ""
	@echo "Review the bun.lock / yarn.lock diff, then commit both."

update: ## Pull latest changes and re-run deps + sync
	@if [ -n "$$(git -C "$(NVIM_DIR)" status --porcelain)" ]; then \
		echo "Local changes present — commit/stash first, or 'make all' to rebuild without pulling."; \
		exit 1; \
	fi
	@echo "Pulling latest..."
	@git -C "$(NVIM_DIR)" pull --ff-only
	@$(MAKE) deps
	@$(MAKE) sync

clean: ## Wipe plugin + cache state (forces reinstall on next launch)
	@echo ""
	@echo "This will delete:"
	@for p in $(CLEAN_PATHS); do echo "  $$p"; done
	@read -r -p "Continue? [y/N] " ans; \
		case "$$ans" in \
			[yY]|[yY][eE][sS]) \
				for p in $(CLEAN_PATHS); do \
					if [ -d "$$p" ]; then \
						rm -rf "$$p" && echo "  deleted $$p"; \
					else \
						echo "  (absent) $$p"; \
					fi; \
				done; \
				echo ""; \
				echo "Done. Run 'make sync' or open nvim to reinstall plugins."; \
				;; \
			*) \
				echo "Canceled."; \
				;; \
		esac
	@echo ""
