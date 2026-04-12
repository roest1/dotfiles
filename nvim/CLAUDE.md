# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is "roest-nvim", a modular Neovim configuration built on **lazy.nvim**. It was forked from kickstart-modular.nvim.

## Bootstrap & Dependencies

`bootstrap.sh` installs all external dependencies across macOS (brew), Ubuntu/WSL (apt), and RHEL (dnf). It handles runtimes (node, python3, cargo), core tools (rg, fd, stylua, prettierd), formatters (ruff, eslint_d), and productivity tools (zoxide, fzf, bat, eza).

Run `:checkhealth roest` to verify tool availability — defined in `lua/external/health.lua`.

## Architecture

**Entry point:** `init.lua` loads in order: leader key (`<space>`) → `options` → `keymaps` → `lazy-bootstrap` → `lazy-plugins` → custom modules (findreplace, copy, reset).

**Plugin loading:** `lua/lazy-plugins.lua` calls `lua/external/plugins/init.lua`, which has a hardcoded list of 16 plugin module paths. Each plugin is a separate file in `lua/external/plugins/` returning a lazy.nvim spec table.

**Custom modules** (not lazy.nvim plugins, loaded directly in init.lua):
- `lua/external/copy.lua` — `:Copy` command, copies file contents to clipboard for LLM sharing
- `lua/external/findreplace.lua` — `:Find` and `:FindReplace` using rg/fd
- `lua/external/reset.lua` — `:ResetNvim` nuclear plugin reset

## Key Conventions

- Leader key MUST be set before any plugins load (done in init.lua before requires)
- Plugin files return a table (or list of tables) consumable by lazy.nvim
- LSP servers are configured in `lua/external/plugins/lsp.lua` via mason-lspconfig; add new servers to the `servers` table
- Formatters are configured in `lua/external/plugins/formatter.lua` (conform.nvim) by filetype
- Linters are configured in `lua/external/plugins/lint.lua` (nvim-lint) by filetype
- Completion is handled by blink.cmp (`lua/external/plugins/blink-cmp.lua`), which also provides LSP capabilities

## Adding a New Plugin

1. Create `lua/external/plugins/<name>.lua` returning a lazy.nvim spec
2. Add `'external/plugins/<name>'` to the `plugin_modules` list in `lua/external/plugins/init.lua`

## Help Documentation

Custom help files live in `doc/` (`:help roest-*`). These document keymaps, plugins, workflows, options, motions, and commands.
