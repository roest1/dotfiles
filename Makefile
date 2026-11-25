# dotfiles/Makefile
#
# Dotfiles + nvim monorepo. Fedora and RHEL (dnf).
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
export PATH := $(HOME)/.local/bin:$(HOME)/.local/share/mise/shims:$(HOME)/.cargo/bin:$(HOME)/.bun/bin:$(HOME)/.dotnet/tools:$(PATH)

UNAME := $(shell uname -s)
# make's own functions split their argument on whitespace, so $(abspath) and
# $(dir) cannot survive a path with a space in it: every later
# $(DOTFILES_DIR)/lib/... would resolve to /lib/... and `make help` would die
# before printing anything.
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
# section is.
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

# EVERY target belongs here, not just the ones that have bitten. A target that
# shares a name with a file or directory makes make answer "'<name>' is up to
# date" and run nothing -- a target that silently does nothing is worse than
# one that errors. `windows` did exactly that against the old windows/
# directory, and `lint` had the same latent bug.
#
# CI asserts this list stays complete, because the failure is invisible until
# a path happens to share a target's name.
.PHONY: help install link check status plugins lint sync prune test shell update sections mise-lock $(SECTIONS)

# One recipe line, not twelve, because lib/sgr.sh has to be sourced in the same
# shell that uses it — make runs each recipe line in its own.
#
# The escapes sit OUTSIDE awk's format specifiers, so %-12s still pads the
# target name alone and the columns land exactly where they did before. They
# are also empty unless stdout is a WezTerm terminal; see lib/sgr.sh.
help: ## Show this help
	@source "$(DOTFILES_DIR)/lib/sgr.sh"; \
	source "$(DOTFILES_DIR)/lib/tty.sh"; \
	body=$$( \
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
	  echo ""; \
	  printf "  %sdots%s  everything above, navigable — targets, sections, theme\n" "$$SG_B" "$$SG_OFF" \
	); \
	echo ""; \
	tty_banner "$$SG_B" "$$SG_OFF" "dotfiles — $(UNAME)" "$$body"

sections: ## List sections declared in deps.conf
	@echo "$(SECTIONS)" | tr ' ' '\n'

# Plugins (lib/plugins.sh) ride along only when NO section is named: `make
# install nvim` means this repo's [nvim] and nothing else, and a plugin's
# sections are not this repo's to name. `make link` links plugins already
# cloned but never clones one -- it promises no network.
PLUGINS := source "$(DOTFILES_DIR)/lib/plugins.sh" &&

install: ## Link config + install tools (optionally: make install <section>...)
	@DOTFILES_FETCH_SUBMODULES=1 bash "$(DOTFILES_DIR)/install.sh" $(ARGS)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_tools $(ARGS)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_post $(ARGS)
	@$(if $(ARGS),:,$(PLUGINS) plugins_fetch && plugins_run install || true)
	@$(MAKE) --no-print-directory check $(ARGS)

link: ## Symlink config only — no sudo, no network, nothing installed
	@bash "$(DOTFILES_DIR)/install.sh" $(ARGS)
	@$(if $(ARGS),:,$(PLUGINS) plugins_run link || true)

check: ## Verify enabled tools are present (optionally: make check <section>...)
	@source "$(DOTFILES_DIR)/lib/run.sh" && run_check $(ARGS) || true
	@$(if $(ARGS),:,$(PLUGINS) plugins_run check || true)

status: ## Sync status: is the machine what deps.conf says? (declared vs. actual)
	@source "$(DOTFILES_DIR)/lib/status.sh" && status_all $(ARGS) || true
	@$(if $(ARGS),:,$(PLUGINS) plugins_run status || true)

plugins: ## Clone + install the plugins in ~/.config/dotfiles/plugins
	@$(PLUGINS) plugins_fetch && plugins_run install && plugins_run check

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

test: ## Run the Lua unit tests (no plugins, no network)
	@command -v nvim >/dev/null 2>&1 || { echo "nvim not installed — skipping"; exit 0; }
	@# Logs go to $TMPDIR: inside Claude's sandbox /tmp and ~/.local/state are
	@# read-only, and nvim would drop its log in the working tree instead.
	@NVIM_LOG_FILE="$${TMPDIR:-/tmp}/dotfiles-nvim.log" nvim --clean --headless --cmd "set runtimepath+=$(DOTFILES_DIR)/nvim" \
		-c "luafile $(DOTFILES_DIR)/nvim/tests/lsp_servers_spec.lua" -c "qa!" 2>&1 \
		| tee "$${TMPDIR:-/tmp}/dotfiles-test.txt"
	@grep -q "ALL PASS" "$${TMPDIR:-/tmp}/dotfiles-test.txt" || { echo "tests failed"; exit 1; }
	@# The keymap counter writes keymap-usage.json: a fresh scratch state dir each run.
	@XDG_STATE_HOME=$$(mktemp -d) NVIM_LOG_FILE="$${TMPDIR:-/tmp}/dotfiles-nvim.log" nvim --clean --headless --cmd "set runtimepath+=$(DOTFILES_DIR)/nvim" \
		-c "luafile $(DOTFILES_DIR)/nvim/tests/usage_spec.lua" -c "qa!" 2>&1 \
		| tee "$${TMPDIR:-/tmp}/dotfiles-usage-test.txt"
	@grep -q "ALL PASS" "$${TMPDIR:-/tmp}/dotfiles-usage-test.txt" || { echo "usage tests failed"; exit 1; }
	@NVIM_LOG_FILE="$${TMPDIR:-/tmp}/dotfiles-nvim.log" nvim --clean --headless --cmd "set runtimepath+=$(DOTFILES_DIR)/nvim" \
		-c "luafile $(DOTFILES_DIR)/nvim/tests/plugins_spec.lua" -c "qa!" 2>&1 \
		| tee "$${TMPDIR:-/tmp}/dotfiles-plugins-test.txt"
	@grep -q "ALL PASS" "$${TMPDIR:-/tmp}/dotfiles-plugins-test.txt" || { echo "plugin list and nvim-pack-lock.json disagree"; exit 1; }
	@# The two readers of ~/.config/dotfiles/theme.conf. Both set XDG_CONFIG_HOME
	@# to a scratch directory themselves, so neither sees this machine's picks.
	@NVIM_LOG_FILE="$${TMPDIR:-/tmp}/dotfiles-nvim.log" nvim --clean --headless --cmd "set runtimepath+=$(DOTFILES_DIR)/nvim" \
		-c "luafile $(DOTFILES_DIR)/nvim/tests/theme_spec.lua" -c "qa!" 2>&1 \
		| tee "$${TMPDIR:-/tmp}/dotfiles-theme-test.txt"
	@grep -q "ALL PASS" "$${TMPDIR:-/tmp}/dotfiles-theme-test.txt" || { echo "nvim's theme.conf reader failed"; exit 1; }
	@NVIM_LOG_FILE="$${TMPDIR:-/tmp}/dotfiles-nvim.log" nvim --clean --headless --cmd "set runtimepath+=$(DOTFILES_DIR)/nvim" \
		-c "luafile $(DOTFILES_DIR)/nvim/tests/icons_spec.lua" -c "qa!" 2>&1 \
		| tee "$${TMPDIR:-/tmp}/dotfiles-icons-test.txt"
	@grep -q "ALL PASS" "$${TMPDIR:-/tmp}/dotfiles-icons-test.txt" || { echo "nvim's icon set reader failed"; exit 1; }
	@NVIM_LOG_FILE="$${TMPDIR:-/tmp}/dotfiles-nvim.log" nvim --clean --headless \
		-c "luafile $(DOTFILES_DIR)/wezterm/tests/theme_spec.lua" -c "qa!" 2>&1 \
		| tee "$${TMPDIR:-/tmp}/dotfiles-wezterm-theme-test.txt"
	@grep -q "ALL PASS" "$${TMPDIR:-/tmp}/dotfiles-wezterm-theme-test.txt" || { echo "wezterm's theme.conf reader failed"; exit 1; }
	@# LSP servers: only meaningful once they're installed, so skip rather than fail
	@if command -v bun >/dev/null 2>&1 && [ -d "$(DOTFILES_DIR)/nvim/lsp-servers/node_modules" ]; then \
		bun "$(DOTFILES_DIR)/nvim/lsp-servers/verify.ts" | tee "$${TMPDIR:-/tmp}/dotfiles-lsp.txt"; \
		grep -q "ALL PASS" "$${TMPDIR:-/tmp}/dotfiles-lsp.txt" || { echo "lsp handshake failed"; exit 1; }; \
	else \
		echo "lsp servers not installed — skipping handshake test"; \
	fi

# --------------------------------------------------------------------------- #
#  Misc                                                                        #
# --------------------------------------------------------------------------- #

# `sudo chsh`, not a bare `chsh`. Bare chsh asks for the USER'S password
# through PAM, which is a prompt all the same, and `dots` streams any target
# that cannot reach sudo into a pane that cannot show a prompt. Going through
# sudo keeps this target in the console's ESCALATES list (tui/dots), where it
# detaches and the prompt fires in the open. The Darwin half of this recipe
# (dscl, /etc/shells, a brew bash) went with macOS support on 2026-10-26.
shell: ## Set default shell to bash
	@current=$$(getent passwd $$USER 2>/dev/null | cut -d: -f7); \
	if echo "$$current" | grep -q bash; then \
		echo "Already using bash ($$current)"; \
	else \
		echo "Current shell: $$current"; \
		echo "Switching default shell to /bin/bash (sudo):"; \
		sudo chsh -s /bin/bash "$$USER"; \
		echo "Done. Log out and back in to use bash."; \
	fi
