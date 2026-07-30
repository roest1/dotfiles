# dotfiles/Makefile
#
# Portable dotfiles + nvim monorepo. macOS (brew), Ubuntu/WSL (apt), RHEL (dnf).
# Every target is idempotent — safe to re-run.
#
# Two axes: WHICH area, and HOW FAR (symlink only vs. also install tools).
#
#                  symlink only        symlink + tools
#     bash         make link-bash      make bash
#     nvim         make link-nvim      make nvim
#     dev          —                   make dev
#     everything   make link           make all
#
# `make link` is the one for a locked-down work machine: full config, no sudo,
# no network, nothing downloaded. `make bash` is the one for a machine where
# neovim isn't allowed — it produces a complete working shell on its own.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# make(1) spawns a non-interactive, non-login shell, which never reads .bashrc —
# so tool directories that only .bashrc puts on PATH are invisible here. Without
# this line the check-* targets report false MISSINGs for anything installed by
# cargo, bun, or a user-prefixed npm.
export PATH := $(HOME)/.local/bin:$(HOME)/.cargo/bin:$(HOME)/.bun/bin:$(HOME)/.npm-global/bin:$(PATH)

UNAME := $(shell uname -s)
DOTFILES_DIR := $(shell cd "$(dir $(abspath $(lastword $(MAKEFILE_LIST))))" && pwd)

# --------------------------------------------------------------------------- #
#  Targets                                                                     #
# --------------------------------------------------------------------------- #

.PHONY: help all bash nvim dev link link-bash link-nvim \
        deps-bash deps-nvim deps-dev sync shell update \
        check check-bash check-nvim check-dev

help: ## Show this help
	@echo ""
	@echo "dotfiles — $(UNAME)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  make %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""

# ---- composite ------------------------------------------------------------

all: link deps-bash deps-nvim deps-dev sync check ## Everything: both areas + dev runtimes

bash: link-bash deps-bash check-bash ## Bash config + shell tools (no editor)

nvim: link-nvim deps-nvim sync check-nvim ## Nvim config + editor toolchain

dev: deps-dev check-dev ## Project runtimes only (bun)

# ---- symlinks only (no sudo, no network) ----------------------------------

link: ## Symlink everything, install nothing
	@bash "$(DOTFILES_DIR)/install.sh" bash nvim

link-bash: ## Symlink bash config only
	@bash "$(DOTFILES_DIR)/install.sh" bash

link-nvim: ## Symlink nvim config only (~/.config/nvim -> this repo)
	@bash "$(DOTFILES_DIR)/install.sh" nvim

# ---- tool installation, per area ------------------------------------------

deps-bash: ## Install shell tools (fzf, bat, eza, fd, rg, gh, jq, zoxide)
	@bash "$(DOTFILES_DIR)/bash/deps.sh"

deps-nvim: ## Install editor toolchain (neovim, node, formatters, tree-sitter)
	@bash "$(DOTFILES_DIR)/nvim/deps.sh"

deps-dev: ## Install project runtimes (bun)
	@bash "$(DOTFILES_DIR)/dev/deps.sh"

sync: ## Install/update nvim plugins + parsers (headless)
	@$(MAKE) -C "$(DOTFILES_DIR)/nvim" sync

# ---- verification ---------------------------------------------------------

check: check-bash check-nvim check-dev ## Verify every area

check-bash: ## Verify shell tools
	@echo ""
	@echo "bash — shell tools"
	@echo "-------------------------------------------"
	@all_ok=true; \
	for cmd in zoxide fzf bat eza rg fd gh jq; do \
		if command -v "$$cmd" >/dev/null 2>&1; then \
			printf "  %-12s ok\n" "$$cmd"; \
		elif [ "$$cmd" = "bat" ] && command -v batcat >/dev/null 2>&1; then \
			printf "  %-12s ok (batcat)\n" "$$cmd"; \
		elif [ "$$cmd" = "fd" ] && command -v fdfind >/dev/null 2>&1; then \
			printf "  %-12s ok (fdfind)\n" "$$cmd"; \
		else \
			printf "  %-12s MISSING\n" "$$cmd"; all_ok=false; \
		fi; \
	done; \
	$$all_ok && echo "  all present" || echo "  run 'make deps-bash'"
	@echo ""

check-nvim: ## Verify editor toolchain
	@echo "nvim — editor toolchain"
	@echo "-------------------------------------------"
	@if [ ! -e "$(HOME)/.config/nvim" ]; then \
		echo "  not installed (run 'make nvim')"; \
	else \
		all_ok=true; \
		for cmd in nvim node npm python3 tree-sitter stylua prettier prettierd ruff eslint_d; do \
			if command -v "$$cmd" >/dev/null 2>&1; then \
				printf "  %-12s ok\n" "$$cmd"; \
			else \
				printf "  %-12s MISSING\n" "$$cmd"; all_ok=false; \
			fi; \
		done; \
		$$all_ok && echo "  all present" || echo "  run 'make deps-nvim'"; \
	fi
	@echo ""

check-dev: ## Verify project runtimes
	@echo "dev — project runtimes"
	@echo "-------------------------------------------"
	@if command -v bun >/dev/null 2>&1; then \
		printf "  %-12s ok (%s)\n" "bun" "$$(bun --version)"; \
	else \
		printf "  %-12s MISSING — run 'make deps-dev'\n" "bun"; \
	fi
	@echo ""

# ---- misc -----------------------------------------------------------------

shell: ## Set default shell to bash
ifeq ($(UNAME),Darwin)
	@current=$$(dscl . -read /Users/$$USER UserShell 2>/dev/null | awk '{print $$2}'); \
	if echo "$$current" | grep -q bash; then \
		echo "Already using bash ($$current)"; \
	else \
		bash_path=""; \
		if [ -x /opt/homebrew/bin/bash ]; then \
			bash_path=/opt/homebrew/bin/bash; \
		elif [ -x /usr/local/bin/bash ]; then \
			bash_path=/usr/local/bin/bash; \
		else \
			bash_path=/bin/bash; \
		fi; \
		echo "Switching default shell to $$bash_path"; \
		if ! grep -qxF "$$bash_path" /etc/shells 2>/dev/null; then \
			echo "$$bash_path not in /etc/shells — adding (requires sudo):"; \
			echo "$$bash_path" | sudo tee -a /etc/shells; \
		fi; \
		chsh -s "$$bash_path"; \
		echo "Done. Open a new terminal to use bash."; \
	fi
else
	@current=$$(getent passwd $$USER 2>/dev/null | cut -d: -f7); \
	if echo "$$current" | grep -q bash; then \
		echo "Already using bash ($$current)"; \
	else \
		echo "Current shell: $$current"; \
		echo "Switching default shell to /bin/bash"; \
		chsh -s /bin/bash; \
		echo "Done. Log out and back in to use bash."; \
	fi
endif

update: ## Pull latest changes and re-link
	@echo "Pulling latest..."
	@git -C "$(DOTFILES_DIR)" pull --ff-only
	@$(MAKE) link
