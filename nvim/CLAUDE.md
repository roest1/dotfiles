# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Overview

A modular Neovim configuration built on **lazy.nvim**, forked from kickstart-modular.nvim. Maintained by [@roest1](https://github.com/roest1). Requires Neovim 0.12+: `altfont.lua` needs 0.12's `blink` highlight attribute, and roslyn.nvim (off, see below) refuses to load below it.

## Bootstrap & Dependencies

The editor toolchain is declared in the parent repo's `../deps.conf` under `[nvim]` — that's the single source of truth, and `make deps` here delegates to it. `nvim/deps.sh` holds only conditional fixups (dnf's `clang-devel` for bindgen, the Wayland/X11 clipboard backends for `:PasteImage`). The tool list for `:checkhealth external` lives in `lua/external/reqs.lua`.

Run `:checkhealth external` to verify tool availability — logic in `lua/external/health.lua`.

**JavaScript tools run under bun, with no node.** The six JS language servers and `prettier`
live in `lsp-servers/package.json`, installed by `bun` and run as `bun <path>`: servers via
explicit `cmd` overrides in `lua/external/lsp_servers.lua`, prettier via the `formatters`
block in `plugins/formatter.lua`. Mason was removed because it installs npm packages by
shelling out to `npm`, which only exists if node does. Prettier's `--stdin-filepath` exits
0 and writes *nothing* under bun while working under node, which is why `formatter.lua` uses
`--write` on a temp file. Don't "tidy" it back to stdin. The server args are not uniform
(`bash-language-server` wants `start`, not `--stdio`); `lsp-servers/verify.ts` proves each
with a real LSP handshake.

## Architecture

**Entry point:** `init.lua` loads in order: leader key (`<space>`) → `options` → `keymaps` → `lazy-bootstrap` → `lazy-plugins` → custom modules (`findreplace`, `copy`, `pasteimg`, `altfont`, `usage`). `oilgit` is the exception: oil's own `config` loads it, because it has nothing to do until oil does.

**Plugin loading:** `lua/lazy-plugins.lua` calls `lua/external/plugins/init.lua`, which holds a hardcoded `plugin_modules` list. Each plugin is a separate file in `lua/external/plugins/` returning a lazy.nvim spec table. A plugin is turned off by commenting its line there; `roslyn` (C#) is off that way, with its spec file and its install step in `deps.sh` kept so one line brings it back.

**Custom modules** (not lazy.nvim plugins — loaded directly in `init.lua`):
- `lua/external/copy.lua` — `:Copy` command, copies file contents to clipboard for LLM sharing
- `lua/external/findreplace.lua` — `:Find` and `:FindReplace` using rg/fd
- `lua/external/pasteimg.lua` — paste an image from the clipboard into a buffer
- `lua/external/altfont.lua` — renders file buffers in a different terminal font from oil and the rest of the UI. See below.
- `lua/external/usage.lua` — `:KeymapUsage`, counts real presses of each mapping into `stdpath('state')`, outside the work tree. See "Pruning is measured" below.
- `lua/external/oilgit.lua` — `:OilGit`, the diffstat column in oil; loaded from `plugins/oil.lua`, not `init.lua`.
- `lua/external/theme.lua` — colorscheme lanes (`nvim.ui`, `nvim.editor`) read from machine-local `~/.config/dotfiles/theme.conf`; the editor lane is a per-window highlight namespace. Loaded from `plugins/theme.lua`'s rose-pine `config`, not `init.lua`.
- `lua/external/filebuf.lua` — the one definition of "a file you write", shared by `altfont` and `theme` so the font lane and the color lane cannot disagree about which windows are the editor.

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
  help and quickfix are excluded the same way; only a file-backed
  buffer is `''`. The URL-scheme test next to it is the belt to that braces.

`:AltFont` reports what it decided and why; `:AltFont toggle` turns it off for
the session. `font` (in bash) picks which family the lane maps to.

## Key Conventions

- Leader key MUST be set before any plugins load (done in `init.lua` before any `require`)
- Plugin files return a table (or list of tables) consumable by lazy.nvim
- LSP servers are defined in `lua/external/lsp_servers.lua` (a plain table, kept out of the plugin spec so `nvim/tests/lsp_servers_spec.lua` can assert on it under `--clean`) and wired up in `lua/external/plugins/lsp.lua`. There is no Mason: native servers are declared in `../deps.conf`, JS ones in `lsp-servers/package.json` and run as `bun <path>` via explicit `cmd` overrides. TypeScript's `tsc` (TS 7, native) also comes from `lsp-servers/package.json` but runs as the platform binary directly, with no runtime
- Formatters are configured in `lua/external/plugins/formatter.lua` (conform.nvim) by filetype
- There is no lint plugin. Lint is a language server's diagnostics (`ruff` for Python, `sqruff` for SQL, shellcheck through `bashls`); nvim-lint was removed in 2026-11 when its one linter, ruff, moved to `ruff server`
- `plugins/lsp.lua` enables a server only if its binary is on PATH, so a machine that has not run `make install nvim` degrades instead of erroring; `:checkhealth external` names what is off
- There is no completion plugin. Completion is nvim's own (`vim.lsp.completion.enable` with `autotrigger`, set up in `plugins/lsp.lua`), which opens on a server's trigger characters. `blink.cmp` sat in the list as `enabled = false` from 2026-06 to 2026-10 and was deleted rather than kept off

## Adding a New Plugin

1. Create `lua/external/plugins/<name>.lua` returning a lazy.nvim spec
2. Add `'external/plugins/<name>'` to the `plugin_modules` list in `lua/external/plugins/init.lua`

## Help Documentation

`doc/dotfiles.txt` (`:help dotfiles`) is the whole of it: one page listing every key, command and automatic behavior this config adds. It replaced six pages (about 1,350 lines) in 2026-11 because nobody reread them; a page short enough to drill is the point, so resist growing it back into a reference. After editing it, regenerate tags with `:helptags ~/.config/nvim/doc`.

**It covers this config only.** Vim itself (motions, operators, registers) is `:help motion.txt`, which always matches the installed version. The shell is `h` in a terminal. Don't reintroduce a doc that crosses those lines.

The README is a short orientation page (install + keymap quick-reference + a pointer to `:help dotfiles`).

## Pruning is measured, and the docs are checked

Commit 37fa6ce (2026-06-17) deleted ~40 mappings on judgement, and `doc/`
kept describing every one of them until 2026-10, because the `h` rule that
keeps the shell honest had no equivalent for the editor. Two things now
exist so that does not repeat:

- **`:KeymapUsage`** (`lua/external/usage.lua`) counts real presses of every
  active mapping into `~/.local/state/nvim/keymap-usage.json`. That path is
  outside the work tree on purpose -- the same property that keeps
  `~/.bash_local` out of git -- so nothing here can commit a usage log by
  accident. Do not move it under `~/.config/nvim`, which is a symlink into
  the repo. `tools/usage.sh` in the repo root prints it next to the shell's
  history counts. The next cleanup deletes zeros; it does not guess.
  **Until 2026-11-23 it undercounted:** which-key's (since removed) nowait per-buffer triggers
  (`<Space>`, `g`, `[`, `]`, `z`, `<C-W>`, ...) were counted in place of the
  mapping behind them, so a zero under one of those prefixes means nothing
  before that date. `nvim/tests/usage_spec.lua` (`make test`) keeps it fixed.
- **CI checks `doc/` against `lua/` in both directions** (the `nvim`
  job): every `<leader>` key named in `doc/*.txt` or `README.md` must be
  defined under `lua/`, every `<leader>` key defined under `lua/` must be
  named in `doc/dotfiles.txt`, and every `nvim_create_user_command`
  must have a line there. A mapping and its help line change in the same
  commit.

## Pruning

Start from `:KeymapUsage` and `tools/usage.sh`. What they cannot see is anything passive: gutter signs, the oil diffstat, the font and color lanes, format on save. A zero for those means nothing, so ask before cutting one.

A cut is complete when the spec file or module, its `plugin_modules` or `init.lua` line, its lines in `doc/dotfiles.txt` and `README.md`, and any tool it alone needed in `../deps.conf` are all gone in the same commit. Language servers and formatters follow the filetypes actually edited by hand: bash, yaml, json, lua, python, rust, c, typescript, sql, plus xml, css and html.
