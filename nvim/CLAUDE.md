# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Overview

`roest-nvim` is a modular Neovim configuration built on **lazy.nvim**, forked from kickstart-modular.nvim. Maintained by [@roest1](https://github.com/roest1). Requires Neovim 0.10+.

## Bootstrap & Dependencies

`bootstrap.sh` installs external dependencies across macOS (brew), Ubuntu/WSL (apt), and RHEL (dnf): runtimes (node, python3, cargo), core tools (ripgrep, fd, stylua, prettierd), formatters (ruff, eslint_d), and productivity tools (zoxide, fzf, bat, eza). The authoritative list lives in `lua/external/reqs.lua` and is consumed by both `bootstrap.sh` and `:checkhealth roest`.

Run `:checkhealth roest` to verify tool availability — logic in `lua/external/health.lua`.

## Architecture

**Entry point:** `init.lua` loads in order: leader key (`<space>`) → `options` → `keymaps` → `lazy-bootstrap` → `lazy-plugins` → custom modules (`findreplace`, `copy`, `reset`).

**Plugin loading:** `lua/lazy-plugins.lua` calls `lua/external/plugins/init.lua`, which holds a hardcoded `plugin_modules` list (currently 17 entries). Each plugin is a separate file in `lua/external/plugins/` returning a lazy.nvim spec table.

**Custom modules** (not lazy.nvim plugins — loaded directly in `init.lua`):
- `lua/external/copy.lua` — `:Copy` command, copies file contents to clipboard for LLM sharing
- `lua/external/findreplace.lua` — `:Find` and `:FindReplace` using rg/fd
- `lua/external/reset.lua` — `:ResetNvim` nuclear plugin reset

## Key Conventions

- Leader key MUST be set before any plugins load (done in `init.lua` before any `require`)
- Plugin files return a table (or list of tables) consumable by lazy.nvim
- LSP servers are configured in `lua/external/plugins/lsp.lua` via `mason-lspconfig` — add new servers to the `servers` table
- Formatters are configured in `lua/external/plugins/formatter.lua` (conform.nvim) by filetype
- Linters are configured in `lua/external/plugins/lint.lua` (nvim-lint) by filetype
- Completion is handled by `blink.cmp` (`lua/external/plugins/blink-cmp.lua`), which also provides LSP capabilities

## Adding a New Plugin

1. Create `lua/external/plugins/<name>.lua` returning a lazy.nvim spec
2. Add `'external/plugins/<name>'` to the `plugin_modules` list in `lua/external/plugins/init.lua`

## Help Documentation

Custom help files live in `doc/` (`:help roest-*`): keymaps, plugins, workflows, options, motions, commands, bash. After editing any doc file, regenerate tags with `:helptags ~/.config/nvim/doc`.

The README is a short orientation page (install + keymap quick-reference + pointers into `:help`). Vim-generic material (motions, operators, macros) belongs in `doc/`, not the README.
