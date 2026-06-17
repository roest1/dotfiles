# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Overview

A modular Neovim configuration built on **lazy.nvim**, forked from kickstart-modular.nvim. Maintained by [@roest1](https://github.com/roest1). Requires Neovim 0.10+.

## Bootstrap & Dependencies

`bootstrap.sh` installs external dependencies across macOS (brew), Ubuntu/WSL (apt), and RHEL (dnf): runtimes (node, python3, cargo), core tools (ripgrep, fd, stylua, prettierd), formatters (ruff, eslint_d), and productivity tools (zoxide, fzf, bat, eza). The authoritative list lives in `lua/external/reqs.lua` and is consumed by both `bootstrap.sh` and `:checkhealth external`.

Run `:checkhealth external` to verify tool availability — logic in `lua/external/health.lua`.

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

## Maintenance & Audit

As the config grows, unused components accumulate (plugins you disabled, keybinds for removed tools, settings that conflict). Periodically audit to keep the ~5,000 lines manageable. Use this framework:

### Unused External Plugins

**Discovery:** List `plugin_modules` in `lua/external/plugins/init.lua`, then check for actual use:

```lua
-- For each plugin_module entry, answer: Is it used?
-- ✓ Has active keybinds (grep lua/keymaps.lua)
-- ✓ Referenced in help docs (grep doc/*.txt for [plugin-name])
-- ✓ Has custom setup/config that's irreplaceable
-- ✗ Keybinds removed in previous cleanups (grep git log -p for deletions)
-- ? Uncertain: check :help [plugin-name] to understand its default behavior
```

**Action:** Plugins with no keybinds, no references, and default config candidates for removal. Remove from `plugin_modules` list, delete the file from `lua/external/plugins/`, and remove any keybinds/help from `lua/keymaps.lua` and `doc/roest-keymaps.txt`.

### Unused Custom Modules

**Discovery:** Check `init.lua` for loaded modules. Each should have a `:command` that appears in `doc/roest-commands.txt` with actual usage notes.

```lua
-- lua/external/findreplace.lua  → :Find, :FindReplace in roest-commands.txt?
-- lua/external/copy.lua         → :Copy in roest-commands.txt?
-- lua/external/reset.lua        → :ResetNvim in roest-commands.txt?
-- lua/external/oilgit.lua       → :OilGit in roest-plugins.txt (oil section)?
-- lua/external/pasteimg.lua     → :PasteImage in roest-plugins.txt (oil section)?
```

**Action:** Remove from `init.lua` and delete the module file if undocumented or not referenced in help.

### Unused Keybinds

**Discovery:** `lua/keymaps.lua` is the source of truth. Cross-check against:
- Plugins actually in `plugin_modules`
- LSP servers in `lsp.lua`
- Formatter/linter filetypes in `formatter.lua` / `lint.lua`
- Help docs in `doc/roest-keymaps.txt`

```bash
# Example: grep for removed plugin keybinds
git log -p lua/keymaps.lua | grep -E '^\-.*keymap.set' | head -20
```

**Action:** Remove obsolete keybinds (e.g., `<leader>e` if its plugin was removed). Update `doc/roest-keymaps.txt` to match.

### Unused Settings & Options

**Discovery:** `lua/options.lua` is small, but check for:
- Autocmds that reference removed plugins
- Highlight overrides for plugins no longer loaded
- Vim settings configured for removed language servers

```bash
grep -n 'nvim_create_autocmd\|nvim_set_hl' lua/options.lua
# For each autocmd/hl, verify the plugin/tool still exists
```

**Action:** Remove dead autocmds, highlight groups, and settings tied to removed tools.

### Unused LSP Servers, Formatters, Linters

**Discovery:** Each language server in `lsp.lua`, formatter in `formatter.lua`, and linter in `lint.lua` should be either:
- Active for filetypes you actively edit (lua, typescript, python, etc.)
- A well-understood fallback (e.g., lua_ls for all Lua)

Check your actual file editing patterns:
```bash
# What filetypes do you edit?
git log --name-only --pretty=format: | sort | uniq | grep -oE '\.\w+$' | sort | uniq -c | sort -rn
```

**Action:** Remove servers/formatters/linters for filetypes you don't edit. Keep LSP servers general (lua_ls, typescript-language-server) unless you have a specific reason (e.g., a project-specific configuration).

### Doc Tag Regeneration

After any of the above cleanup, regenerate doc tags:

```vim
:helptags ~/.config/nvim/doc
```

Verify no stale references remain in `doc/tags` (git diff should show only removals, not additions for deleted plugins).
