# roest-nvim/Makefile
#
# Portable installer for macOS, Linux (WSL), and Fedora/RHEL.
# Every target is idempotent — safe to re-run.
#
# Usage:
#   make              Show help
#   make deps         Install nvim + external deps (runs bootstrap.sh)
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

.PHONY: help all deps sync update clean

help: ## Show this help
	@echo ""
	@echo "roest-nvim — $(UNAME)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  make %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""

all: deps sync ## Install everything (deps + sync)

deps: ## Install nvim + external deps (runs bootstrap.sh)
	@bash "$(NVIM_DIR)/bootstrap.sh"

sync: ## Install/update plugins + compile TS parsers (headless)
	@command -v nvim >/dev/null 2>&1 || { echo "nvim not found — run 'make deps' first"; exit 1; }
	@echo ""
	@echo "Syncing lazy.nvim plugins..."
	@nvim --headless "+Lazy! sync" +qa 2>&1 | tail -20
	@echo ""
	@echo "Updating tree-sitter parsers..."
	@nvim --headless "+TSUpdateSync" +qa 2>&1 | tail -5
	@echo ""
	@echo "Done."

update: ## Pull latest changes and re-run deps + sync
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
