# dotfiles/Makefile
#
# Portable dotfiles installer for macOS and Linux (WSL).
# Every target is idempotent — safe to re-run.
#
# Usage:
#   make              Show help
#   make install      Symlink dotfiles into ~
#   make deps         Install CLI tools via Homebrew
#   make shell        Set default shell to bash (macOS)
#   make update       Pull latest changes and re-install
#   make check        Verify tool availability
#   make all          deps + install + check

SHELL := /bin/bash
.DEFAULT_GOAL := help

UNAME := $(shell uname -s)
DOTFILES_DIR := $(shell cd "$(dir $(abspath $(lastword $(MAKEFILE_LIST))))" && pwd)

# Tools this config depends on (brew package names).
BREW_DEPS := bash zoxide fzf bat eza fd ripgrep gh jq

# --------------------------------------------------------------------------- #
#  Targets                                                                     #
# --------------------------------------------------------------------------- #

.PHONY: help all install deps shell update check

help: ## Show this help
	@echo ""
	@echo "dotfiles — $(UNAME)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  make %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""

all: deps install check ## Install everything (deps + install + check)

install: ## Symlink dotfiles into ~
	@bash "$(DOTFILES_DIR)/install.sh"

deps: _ensure_brew ## Install CLI tools via Homebrew
	@echo ""
	@echo "Installing tools: $(BREW_DEPS)"
	@echo "-------------------------------------------"
	@brew install $(BREW_DEPS) 2>&1 | grep -v 'already installed' || true
	@echo ""
	@echo "Done. Run 'make check' to verify."

shell: ## Set default shell to bash (macOS)
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
	@echo "Not macOS — your shell is already bash."
endif

update: ## Pull latest changes and re-install
	@echo "Pulling latest..."
	@git -C "$(DOTFILES_DIR)" pull --ff-only
	@$(MAKE) install

check: ## Verify tool availability
	@echo ""
	@echo "Checking tools..."
	@echo "-------------------------------------------"
	@all_ok=true; \
	for cmd in zoxide fzf bat eza rg fd nvim gh jq; do \
		if command -v "$$cmd" >/dev/null 2>&1; then \
			printf "  %-12s ok\n" "$$cmd"; \
		elif [ "$$cmd" = "bat" ] && command -v batcat >/dev/null 2>&1; then \
			printf "  %-12s ok (batcat)\n" "$$cmd"; \
		else \
			printf "  %-12s MISSING\n" "$$cmd"; \
			all_ok=false; \
		fi; \
	done; \
	echo "-------------------------------------------"; \
	if $$all_ok; then \
		echo "All tools installed."; \
	else \
		echo "Run 'make deps' to install missing tools."; \
	fi
	@echo ""

# --------------------------------------------------------------------------- #
#  Internal helpers                                                            #
# --------------------------------------------------------------------------- #

.PHONY: _ensure_brew

_ensure_brew:
	@if ! command -v brew >/dev/null 2>&1; then \
		echo "Homebrew not found. Installing..."; \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; \
	fi
