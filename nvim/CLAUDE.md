# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Overview

A modular Neovim configuration built on **lazy.nvim**, forked from kickstart-modular.nvim. Maintained by [@roest1](https://github.com/roest1). Requires Neovim 0.12+ — set by roslyn.nvim, which refuses to load below it.

## Bootstrap & Dependencies

The editor toolchain is declared in the parent repo's `../deps.conf` under `[nvim]` — that's the single source of truth, and `make deps` here delegates to it. `nvim/deps.sh` holds only platform-conditional fixups (dnf's `clang-devel` for bindgen, apt's `fdfind`→`fd`, WSL/macOS/Linux clipboard backends for `:PasteImage`). The tool list for `:checkhealth external` lives in `lua/external/reqs.lua`.

Run `:checkhealth external` to verify tool availability — logic in `lua/external/health.lua`.

## Architecture

**Entry point:** `init.lua` loads in order: leader key (`<space>`) → `options` → `keymaps` → `lazy-bootstrap` → `lazy-plugins` → custom modules (`findreplace`, `copy`, `pasteimg`, `reset`, `altfont`).

**Plugin loading:** `lua/lazy-plugins.lua` calls `lua/external/plugins/init.lua`, which holds a hardcoded `plugin_modules` list (currently 17 entries). Each plugin is a separate file in `lua/external/plugins/` returning a lazy.nvim spec table.

**Custom modules** (not lazy.nvim plugins — loaded directly in `init.lua`):
- `lua/external/copy.lua` — `:Copy` command, copies file contents to clipboard for LLM sharing
- `lua/external/findreplace.lua` — `:Find` and `:FindReplace` using rg/fd
- `lua/external/pasteimg.lua` — paste an image from the clipboard into a buffer
- `lua/external/reset.lua` — `:ResetNvim` nuclear plugin reset
- `lua/external/altfont.lua` — renders file buffers in a different terminal font from oil and the rest of the UI. See below.

## The alternate-font carrier (`altfont.lua`)

The file you are editing is drawn in a different font from oil, telescope, the
statusline, the gutter, and whatever is in the next pane. That is a terminal
trick, not an editor feature, and it is worth knowing how it works before
touching either half.

wezterm can select a font from an SGR attribute (`font_rules`) and can pin the
blink rate to zero so a blink attribute never animates. That turns blink into a
spare per-cell bit meaning "draw this in the other font". `wezterm/wezterm.lua`
spends SGR 6 (rapid blink) on Science Gothic Mono for `make` output;
`altfont.lua` is the writer for **SGR 5** (slow blink), which the same config
maps to the `editor` font.

Neovim can emit it because `blink` is a real highlight attribute in 0.12 and the
TUI writes SGR 5 for it. Delivery is a decoration provider adding one ephemeral
extmark per visible line with `hl_mode = 'combine'`, so the attribute is *added*
to whatever treesitter, LSP semantic tokens and the colorscheme already decided.
Combining is what keeps colours, bold and italic intact, and it is also why this
needs no list of highlight groups — LSP semantic-token groups are created long
after startup and would never be on such a list.

Three things not to "tidy":

- **Per-cell is the point.** The obvious alternative is asking wezterm to swap
  the window's font when nvim is focused. wezterm has no per-pane font, so that
  would take oil with it, and would drop out the moment nvim's split lost focus.
- **The guard is `lib/sgr.sh`'s guard.** Outside wezterm, SGR 5 means blinking
  text, so `altfont.lua` checks `TERM_PROGRAM=WezTerm` *and* a linked
  `~/.config/wezterm/fonts` before emitting anything. Both directions are
  asserted in CI, because neither is visible to whoever writes the code.
- **`buftype` is what excludes oil**, which is `acwrite`. Terminals, telescope,
  trouble, help and quickfix are excluded the same way; only a file-backed
  buffer is `''`. The URL-scheme test next to it is the belt to that braces.

`:AltFont` reports what it decided and why; `:AltFont toggle` turns it off for
the session. `font` (in bash) picks which family the lane maps to.

## Key Conventions

- Leader key MUST be set before any plugins load (done in `init.lua` before any `require`)
- Plugin files return a table (or list of tables) consumable by lazy.nvim
- LSP servers are defined in `lua/external/lsp_servers.lua` (a plain table, kept out of the plugin spec so `nvim/tests/lsp_servers_spec.lua` can assert on it under `--clean`) and wired up in `lua/external/plugins/lsp.lua`. There is no Mason: native servers are declared in `../deps.conf`, JS ones in `lsp-servers/package.json` and run as `bun <path>` via explicit `cmd` overrides
- Formatters are configured in `lua/external/plugins/formatter.lua` (conform.nvim) by filetype
- Linters are configured in `lua/external/plugins/lint.lua` (nvim-lint) by filetype
- Completion is handled by `blink.cmp` (`lua/external/plugins/blink-cmp.lua`), which also provides LSP capabilities

## Adding a New Plugin

1. Create `lua/external/plugins/<name>.lua` returning a lazy.nvim spec
2. Add `'external/plugins/<name>'` to the `plugin_modules` list in `lua/external/plugins/init.lua`

## Help Documentation

Custom help files live in `doc/` (`:help dotfiles-*`): keymaps, plugins, workflows, options, commands, harpoon. After editing any doc file, regenerate tags with `:helptags ~/.config/nvim/doc`.

**These docs cover this config only.** Two things they deliberately do not cover:

- **Vim itself** — motions, operators, text objects, registers. `:help motion.txt` is authoritative and always matches the installed version; a local copy can only drift. `doc/dotfiles-motions.txt` was exactly that and was removed (258 lines, of which 10 mentioned this config at all).
- **The shell** — that's `h` in a terminal. `doc/dotfiles-bash.txt` put bash docs in the editor's help and had already gone stale, still telling you to run `./bootstrap.sh` from the nvim config and `brew install` the tools that `deps.conf` now owns.

The rule: the shell documents the shell, the editor documents the editor, and neither documents vim or git themselves. Don't reintroduce a doc that crosses those lines.

The README is a short orientation page (install + keymap quick-reference + pointers into `:help`).

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

**Action:** Plugins with no keybinds, no references, and default config candidates for removal. Remove from `plugin_modules` list, delete the file from `lua/external/plugins/`, and remove any keybinds/help from `lua/keymaps.lua` and `doc/dotfiles-keymaps.txt`.

### Unused Custom Modules

**Discovery:** Check `init.lua` for loaded modules. Each should have a `:command` that appears in `doc/dotfiles-commands.txt` with actual usage notes.

```lua
-- lua/external/findreplace.lua  → :Find, :FindReplace in dotfiles-commands.txt?
-- lua/external/copy.lua         → :Copy in dotfiles-commands.txt?
-- lua/external/reset.lua        → :ResetNvim in dotfiles-commands.txt?
-- lua/external/oilgit.lua       → :OilGit in dotfiles-plugins.txt (oil section)?
-- lua/external/pasteimg.lua     → :PasteImage in dotfiles-plugins.txt (oil section)?
```

**Action:** Remove from `init.lua` and delete the module file if undocumented or not referenced in help.

### Unused Keybinds

**Discovery:** `lua/keymaps.lua` is the source of truth. Cross-check against:
- Plugins actually in `plugin_modules`
- LSP servers in `lsp.lua`
- Formatter/linter filetypes in `formatter.lua` / `lint.lua`
- Help docs in `doc/dotfiles-keymaps.txt`

```bash
# Example: grep for removed plugin keybinds
git log -p lua/keymaps.lua | grep -E '^\-.*keymap.set' | head -20
```

**Action:** Remove obsolete keybinds (e.g., `<leader>e` if its plugin was removed). Update `doc/dotfiles-keymaps.txt` to match.

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
