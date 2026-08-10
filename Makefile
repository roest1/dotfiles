# dotfiles/Makefile
#
# Portable dotfiles + nvim monorepo. macOS (brew), Ubuntu/WSL (apt), RHEL (dnf).
# Every target is idempotent — safe to re-run.
#
# Everything this repo installs or links is declared in deps.conf. This file
# does not know what a "bash" or an "nvim" is; it reads sections from the
# manifest. Adding a program means adding a section there, not editing here.
#
#   make install              everything enabled in deps.conf
#   make install nvim         one section  (repeatable: make install bash nvim)
#   make link                 symlinks only — no sudo, no network
#   make check                verify what's enabled is actually present
#
# To skip a tool, comment it out in deps.conf. There is no flag.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# make(1) spawns a non-interactive, non-login shell, which never reads .bashrc —
# so tool directories that only .bashrc puts on PATH are invisible here. Without
# this line the check target reports false MISSINGs for anything installed by
# cargo, bun, uv or mise.
export PATH := $(HOME)/.local/bin:$(HOME)/.local/share/mise/shims:$(HOME)/.cargo/bin:$(HOME)/.bun/bin:$(PATH)

UNAME := $(shell uname -s)
DOTFILES_DIR := $(shell cd "$(dir $(abspath $(lastword $(MAKEFILE_LIST))))" && pwd)

# Sections come from the manifest, not from this file.
#
# Through lib/manifest.sh rather than a local sed, so this honours `platform`.
# A `platform windows` section cannot be installed from bash — install.sh
# refuses it by design — so listing it in `make help` would advertise a target
# that deliberately fails.
SECTIONS := $(shell bash -c 'source $(DOTFILES_DIR)/lib/manifest.sh && manifest_sections')

# Section names passed on the command line (`make install nvim`) are arguments,
# not targets, so they get a no-op rule to stop make complaining.
#
# This MUST be an allowlist of real section names, not a blocklist of known
# targets: with filter-out, every goal that wasn't listed — help, sync, shell,
# update, sections — got a stub rule that silently overrode the real one, which
# is why `make help` printed "overriding recipe for target 'help'".
ARGS := $(filter $(SECTIONS),$(MAKECMDGOALS))
$(eval $(ARGS):;@:)

# --------------------------------------------------------------------------- #
#  Targets                                                                     #
# --------------------------------------------------------------------------- #

.PHONY: help install link check status sync test shell update sections $(SECTIONS)

help: ## Show this help
	@echo ""
	@echo "dotfiles — $(UNAME)"
	@echo ""
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ {printf "  make %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo ""
	@echo "  Sections (from deps.conf): $(SECTIONS)"
	@echo "    make install nvim        install just that section"
	@echo "    make link bash           link just that section's config"
	@echo "    make check nvim          verify just that section"
	@echo ""
	@echo "  To skip a single tool, comment it out in deps.conf."
	@echo ""

sections: ## List sections declared in deps.conf
	@echo "$(SECTIONS)" | tr ' ' '\n'

install: ## Link config + install tools (optionally: make install <section>...)
	@bash "$(DOTFILES_DIR)/install.sh" $(ARGS)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_tools $(ARGS)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_post $(ARGS)
	@$(MAKE) --no-print-directory check $(ARGS)

link: ## Symlink config only — no sudo, no network, nothing installed
	@bash "$(DOTFILES_DIR)/install.sh" $(ARGS)

check: ## Verify enabled tools are present (optionally: make check <section>...)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_check $(ARGS) || true

status: ## Sync status: is the machine what deps.conf says? (declared vs. actual)
	@source "$(DOTFILES_DIR)/lib/status.sh" && status_all $(ARGS) || true

sync: ## Install/update nvim plugins + parsers (headless)
	@$(MAKE) -C "$(DOTFILES_DIR)/nvim" sync

test: ## Run the Lua unit tests (no plugins, no network)
	@command -v nvim >/dev/null 2>&1 || { echo "nvim not installed — skipping"; exit 0; }
	@nvim --clean --headless --cmd "set runtimepath+=$(DOTFILES_DIR)/nvim" \
		-c "luafile $(DOTFILES_DIR)/nvim/tests/lsp_servers_spec.lua" -c "qa!" 2>&1 \
		| tee /tmp/dotfiles-test.txt
	@grep -q "ALL PASS" /tmp/dotfiles-test.txt || { echo "tests failed"; exit 1; }
	@# LSP servers: only meaningful once they're installed, so skip rather than fail
	@if command -v bun >/dev/null 2>&1 && [ -d "$(DOTFILES_DIR)/nvim/lsp-servers/node_modules" ]; then \
		bun "$(DOTFILES_DIR)/nvim/lsp-servers/verify.ts" | tee /tmp/dotfiles-lsp.txt; \
		grep -q "ALL PASS" /tmp/dotfiles-lsp.txt || { echo "lsp handshake failed"; exit 1; }; \
	else \
		echo "lsp servers not installed — skipping handshake test"; \
	fi

# --------------------------------------------------------------------------- #
#  Misc                                                                        #
# --------------------------------------------------------------------------- #

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
