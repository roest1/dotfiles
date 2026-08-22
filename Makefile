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
# make's own functions split their argument on whitespace, so $(abspath) and
# $(dir) cannot survive a path with a space in it. On a clone at
# /mnt/c/Users/Riley Oest/dotfiles they saw TWO words and rejoined the pieces as
# "/mnt/c/Users/ Oest/dotfiles/" -- the cd then failed, $(shell) returned empty,
# and every later $(DOTFILES_DIR)/lib/... resolved to /lib/..., so `make help`
# died three times before printing anything.
#
# CURDIR is set by make itself and never passes through a make function, so it
# survives the space. The trade is that this Makefile must be run from its own
# directory or via `make -C <dir>` (which sets CURDIR), not `make -f <path>`
# from somewhere else -- which is how it is invoked everywhere in this repo and
# in its docs.
#
# Every USE has to be quoted too, for the same reason cd did: an unquoted
# $(DOTFILES_DIR) in a recipe is two arguments.
DOTFILES_DIR := $(CURDIR)

# Sections come from the manifest, not from this file.
#
# Through lib/manifest.sh rather than a local sed, so one parser decides what a
# section is. Every section here is installable from bash; the Windows host is
# not a section at all, because windows/install.ps1 declares its own payload.
SECTIONS := $(shell bash -c 'source "$(DOTFILES_DIR)/lib/manifest.sh" && manifest_sections')

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

.PHONY: help install link check status sync prune test shell update sections mise-lock mono-font $(SECTIONS)

# One recipe line, not twelve, because lib/sgr.sh has to be sourced in the same
# shell that uses it — make runs each recipe line in its own.
#
# The escapes sit OUTSIDE awk's format specifiers, so %-12s still pads the
# target name alone and the columns land exactly where they did before. They
# are also empty unless stdout is a WezTerm terminal; see lib/sgr.sh.
help: ## Show this help
	@source "$(DOTFILES_DIR)/lib/sgr.sh"; \
	echo ""; \
	printf "%sdotfiles — %s%s\n" "$$SG_B" "$(UNAME)" "$$SG_OFF"; \
	echo ""; \
	awk -v b="$$SG_B" -v r="$$SG_R" -v o="$$SG_OFF" \
	    'BEGIN {FS = ":.*##"} /^[a-zA-Z_-]+:.*##/ \
	     {printf "  %smake %-12s%s %s%s\n", b, $$1, r, $$2, o}' $(MAKEFILE_LIST); \
	echo ""; \
	printf "  %sSections (from deps.conf):%s %s\n" "$$SG_B" "$$SG_OFF" "$(SECTIONS)"; \
	printf "%s    make install nvim        install just that section%s\n" "$$SG" "$$SG_OFF"; \
	printf "%s    make link bash           link just that section's config%s\n" "$$SG" "$$SG_OFF"; \
	printf "%s    make check nvim          verify just that section%s\n" "$$SG" "$$SG_OFF"; \
	echo ""; \
	printf "%s  To skip a single tool, comment it out in deps.conf.%s\n" "$$SG" "$$SG_OFF"; \
	echo ""

sections: ## List sections declared in deps.conf
	@echo "$(SECTIONS)" | tr ' ' '\n'

# ─── The wrong clone ─────────────────────────────────────────────────────────
#
# A checkout under /mnt/ is the WINDOWS host's clone seen from the guest. It
# exists so wezterm.exe can read a config on C:, and `make install` in it would
# point ~/.bashrc, ~/.config/nvim and the rest at a 9p mount -- slow on every
# shell start, and gone the moment the drive is not mounted. install.sh also
# prunes orphans, so the guest's real links would be removed on the way past.
#
# Read-only targets stay allowed: `make help` and `make status` there are
# harmless, and status is actively useful -- it is what tells you this clone is
# behind origin/main.
.PHONY: _guard_wrong_clone
_guard_wrong_clone:
	@case "$(CURDIR)" in \
	  /mnt/*) \
	    echo "This is the Windows host's clone ($(CURDIR))."; \
	    echo ""; \
	    echo "  Installing from here would link your WSL config onto /mnt/c."; \
	    echo "  Use the Linux clone for that:"; \
	    echo "      cd ~/dotfiles && make $(firstword $(MAKECMDGOALS))"; \
	    echo ""; \
	    echo "  This clone is installed from PowerShell on the host instead:"; \
	    echo "      powershell -NoProfile -ExecutionPolicy Bypass -File .\\windows\\install.ps1"; \
	    exit 1 ;; \
	esac

install: _guard_wrong_clone ## Link config + install tools (optionally: make install <section>...)
	@bash "$(DOTFILES_DIR)/install.sh" $(ARGS)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_tools $(ARGS)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_post $(ARGS)
	@$(MAKE) --no-print-directory check $(ARGS)

link: _guard_wrong_clone ## Symlink config only — no sudo, no network, nothing installed
	@bash "$(DOTFILES_DIR)/install.sh" $(ARGS)

check: ## Verify enabled tools are present (optionally: make check <section>...)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_check $(ARGS) || true

status: ## Sync status: is the machine what deps.conf says? (declared vs. actual)
	@source "$(DOTFILES_DIR)/lib/status.sh" && status_all $(ARGS) || true

# No file list here either — tools/lint.sh holds it, and .githooks/pre-commit
# and the CI job call the same script. This is the whole-tree sweep, which is
# what CI runs; the hook passes only what is staged.
lint: ## Run shellcheck over every shell source (same check CI runs)
	@bash "$(DOTFILES_DIR)/tools/lint.sh"

sync: ## Install/update nvim plugins + parsers (headless)
	@$(MAKE) -C "$(DOTFILES_DIR)/nvim" sync

# `mise prune` is two unrelated jobs behind one name: it prunes tracked
# configuration links AND unused tool versions. The config half runs first and
# needs no confirmation; the tool half prompts. So in any non-interactive
# context — a script, this Makefile, CI — bare `mise prune` does the config
# half, prints "pruned configuration links", removes nothing, and looks like it
# worked. That is not a flag worth remembering under pressure, so it lives here
# instead. Shows what will go, then does it.
prune: ## Remove superseded mise tool versions (shows them first)
	@command -v mise >/dev/null 2>&1 || { echo "mise not installed — nothing to prune"; exit 0; }
	@if [ -z "$$(mise ls --prunable 2>/dev/null)" ]; then \
		echo "no superseded mise versions"; \
	else \
		echo "superseded versions:"; \
		mise ls --prunable | sed 's/^/  /'; \
		mise prune --tools -y; \
	fi

# deps.conf declares the tool set; this derives the version pins from it and
# turns them into a checksummed, per-platform lockfile. Same arrangement as
# nvim/lsp-servers: one authored file, one generated file, CI asserting both
# still agree. Run after adding or removing a mise-provided tool, or to bump.
mise-lock: ## Regenerate mise.toml from deps.conf and refresh mise.lock
	@bash "$(DOTFILES_DIR)/tools/gen-mise.sh"
	@cd "$(DOTFILES_DIR)" && mise lock

# Science Gothic Mono is generated the same way mise.toml is: an authored
# generator plus a committed artifact. The .ttf files live in wezterm/fonts and
# are linked into ~/.config/wezterm, so a fresh machine needs no python, no
# network and no font tooling — only this target does. Re-run after an upstream
# Science Gothic release.
mono-font: ## Regenerate wezterm/fonts from upstream Science Gothic
	@command -v uv >/dev/null 2>&1 || { echo "uv not installed — declared in deps.conf [bash]"; exit 1; }
	@src=$$(mktemp); \
	if curl -fsSL -o "$$src" \
	     "https://raw.githubusercontent.com/google/fonts/main/ofl/sciencegothic/ScienceGothic%5BCTRS,slnt,wdth,wght%5D.ttf"; then \
	  uv run "$(DOTFILES_DIR)/wezterm/mkmono.py" "$$src" "$(DOTFILES_DIR)/wezterm/fonts"; \
	else \
	  echo "download failed — wezterm/fonts left as-is"; rm -f "$$src"; exit 1; \
	fi; \
	rm -f "$$src"

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
