# dotfiles/Makefile
#
# Portable dotfiles installer for macOS, Linux (WSL), and RHEL.
# Every target is idempotent — safe to re-run.
#
# Usage:
#   make              Show help
#   make install      Symlink dotfiles into ~
#   make deps         Install CLI tools (brew on mac/WSL, dnf on RHEL)
#   make shell        Set default shell to bash
#   make update       Pull latest changes and re-install
#   make check        Verify tool availability
#   make all          deps + install + check

SHELL := /bin/bash
.DEFAULT_GOAL := help

UNAME := $(shell uname -s)
DOTFILES_DIR := $(shell cd "$(dir $(abspath $(lastword $(MAKEFILE_LIST))))" && pwd)

# Tools this config depends on (brew package names).
BREW_DEPS := bash zoxide fzf bat eza fd ripgrep gh jq

# RHEL/Fedora equivalents (dnf package names).
# zoxide is not in base RHEL repos — installed separately.
DNF_DEPS := fzf bat fd-find ripgrep gh jq eza

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

deps: ## Install CLI tools (auto-detects package manager)
	@if command -v dnf >/dev/null 2>&1; then \
		echo ""; \
		echo "Detected dnf (RHEL/Fedora)"; \
		echo "-------------------------------------------"; \
		echo "Enabling EPEL (if not already)..."; \
		sudo dnf install -y epel-release 2>/dev/null \
			|| sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-$$(rpm -E %rhel).noarch.rpm 2>/dev/null \
			|| echo "  EPEL already enabled or not needed"; \
		echo "Installing: $(DNF_DEPS)"; \
		sudo dnf install -y $(DNF_DEPS) 2>&1 | tail -1; \
		echo ""; \
		echo "Installing zoxide..."; \
		if ! command -v zoxide >/dev/null 2>&1; then \
			curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh; \
		else \
			echo "  zoxide already installed"; \
		fi; \
	elif command -v brew >/dev/null 2>&1 || [ "$(UNAME)" = "Darwin" ]; then \
		$(MAKE) _brew_deps; \
	else \
		echo "No supported package manager found (need brew or dnf)."; \
		echo "Install Homebrew: https://brew.sh"; \
		exit 1; \
	fi
	@echo ""
	@echo "Done. Run 'make check' to verify."

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

update: ## Pull latest changes and re-install
	@echo "Pulling latest..."
	@git -C "$(DOTFILES_DIR)" pull --ff-only
	@$(MAKE) install

check: ## Verify tool availability
	@echo ""
	@echo "Checking tools..."
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

.PHONY: _ensure_brew _brew_deps

_ensure_brew:
	@if ! command -v brew >/dev/null 2>&1; then \
		echo "Homebrew not found. Installing..."; \
		/bin/bash -c "$$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; \
	fi

_brew_deps: _ensure_brew
	@echo ""
	@echo "Installing tools via Homebrew: $(BREW_DEPS)"
	@echo "-------------------------------------------"
	@brew install $(BREW_DEPS) 2>&1 | grep -v 'already installed' || true
