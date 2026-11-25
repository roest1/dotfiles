# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Overview

A modular Neovim configuration, forked from kickstart-modular.nvim. Plugins are managed by nvim's own **`vim.pack`**. Maintained by [@roest1](https://github.com/roest1). Requires Neovim 0.12+: `altfont.lua` needs 0.12's `blink` highlight attribute, `vim.pack` arrived in 0.12, and roslyn.nvim (off, see below) refuses to load below it.

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

**Entry point:** `init.lua` loads in order: leader key (`<space>`) → `options` → `keymaps` → `external.plugins` (`setup()`) → custom modules (`findreplace`, `copy`, `pasteimg`, `altfont`, `usage`). `oilgit` is the exception: `plugins/oil.lua`'s `setup` loads it, because it has nothing to do until oil does.

**Plugin loading:** `lua/external/plugins/init.lua` holds a hardcoded `modules` list. Each name is a file in `lua/external/plugins/` returning `{ add, setup, build }`: the repositories for `vim.pack.add`, a function that configures them, and optional build steps. `setup()` collects every `add` into one `vim.pack.add` call, then runs each `setup` in list order (theme first). A plugin is turned off by commenting its line; `roslyn` (C#) is off that way, with its file and its install step in `deps.sh` kept.

**Custom modules** (not plugins — loaded directly in `init.lua`):
- `lua/external/copy.lua` — `:Copy` command, copies file contents to clipboard for LLM sharing
- `lua/external/findreplace.lua` — `:Find` and `:FindReplace` using rg/fd
- `lua/external/pasteimg.lua` — paste an image from the clipboard into a buffer
- `lua/external/altfont.lua` — renders file buffers in a different terminal font from oil and the rest of the UI. See below.
- `lua/external/usage.lua` — `:KeymapUsage`, counts real presses of each mapping into `stdpath('state')`, outside the work tree. See "Pruning is measured" below.
- `lua/external/oilgit.lua` — `:OilGit`, the diffstat column in oil; loaded from `plugins/oil.lua`, not `init.lua`.
- `lua/external/theme.lua` — colorscheme lanes (`nvim.ui`, `nvim.editor`) read from machine-local `~/.config/dotfiles/theme.conf`; the editor lane is a per-window highlight namespace. Loaded from `plugins/theme.lua`'s `setup`, not `init.lua`. See "The color lanes" below.
- `lua/external/icons.lua` — which set draws a file's icon in oil and telescope: `icons = material` in `theme.conf`. Called from `theme.lua`, not `init.lua`. See "The icon set" below.
- `lua/external/filebuf.lua` — the one definition of "a file you write", shared by `altfont` and `theme` so the font lane and the color lane cannot disagree about which windows are the editor.

## The color lanes (`theme.lua`)

`~/.config/dotfiles/theme.conf` is every lane's file: `theme` writes it, `wezterm.lua` reads
the fonts and the terminal's colors, and `theme.lua` reads `nvim.ui.colors`,
`nvim.ui.transparent`, `nvim.editor.colors` and `nvim.editor.transparent`. Things not to undo:

- **A pick applies to a running nvim.** `theme.lua` watches the file's DIRECTORY (the file
  does not exist until the first pick) and re-applies when what the file asks of nvim has
  changed. It waits 100ms after the last event: `theme` truncates and then writes, and reading
  in between flashed both lanes to the default.
- **The editor lane gets a new highlight namespace on every apply.** A group cannot be taken
  out of a namespace, only emptied, and an empty group there still hides the ui scheme's.
- **Transparent takes the background out of what the scheme set; it does not replace the
  group.** `nvim_set_hl(0, 'Normal', { bg = 'none' })` replaces Normal whole, so the
  foreground went with it and a transparent lane drew its text in the terminal's color. That
  was invisible with rose-pine over a rose-pine terminal, and wrong for Dracula.
- **rose-pine is asked for its base back by name on an opaque load.** Its
  `disable_background = true` leaves `Normal = { bg = 'NONE' }` in its own overrides and a
  later `false` does not remove it, so opaque after transparent stayed transparent.
- **`M.load` is public for `theme`.** Its color preview runs a headless nvim, loads each
  scheme through `load` and reads the highlights back, so the preview is drawn by the code
  that draws the lane.
- **`nvim.ui = <scheme>` is still read**, underneath `nvim.ui.colors`. It was the spelling
  for the week this file was nvim's alone. `theme` rewrites it; take it out once no machine
  has one.
- **`nvim/tests/theme_spec.lua` (`make test`)** runs the reader on the files a machine can
  have, with three stand-in schemes and no plugins, and checks the watcher end to end.

## The icon set (`icons.lua`)

`icons = material` in `~/.config/dotfiles/theme.conf` swaps the Nerd Font glyphs oil and
telescope draw for Material Icon Theme, in color. `theme.lua` reads the key with the rest of
the file and hands it to `external/icons.lua`, at start and on every rewrite, so a pick on
`theme`'s Icons tab reaches a running nvim.

- **Nothing about the set is in this repo.** Which code point is which icon, and which file
  gets which, is read from `material-icons.tsv`, which roest1/fonts builds beside the font
  (`~/.config/wezterm/fonts`). A code point holds for one upstream release.
- **`get_icon` is wrapped; the plugin's override API is not used.** `override_by_filename`
  and `set_icon` are what nvim-web-devicons documents for this, and they only go one way: an
  override is merged into a table the plugin keeps and re-applies, and nothing takes one
  out. Picking the default again would leave Material on every name the plugin has no icon
  for. The wrapper asks the table only while the pick says so, and the plugin's tables are
  never touched.
- **The same guard as `altfont.lua`.** The icons are private-use characters in a font the
  terminal has. Outside WezTerm, or without the font linked, the pick is left alone;
  `require('external.icons').why` says which.
- **Two spaces after an icon.** `wezterm.lua` draws the font at 1.2 times the text's size,
  where an icon covers its own cell and most of the next. The wrapper returns the icon with
  one space, and oil's column is set not to pad it again (oil's padding plus its column gap
  would make three).
- **Every folder in oil gets one icon.** oil takes a folder's icon from its column's options
  and has no hook for a folder's name. Files get their own.
- **An icon pick does not reload a colorscheme.** `theme.read` returns the lanes and, second,
  the whole file; `icons` is not in the lanes table that `reload` compares.

`nvim/tests/icons_spec.lua` (`make test`) covers where the pick must not take, and that the
default comes back whole.

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
the session. `theme` (in bash) picks which family the lane maps to.

## Key Conventions

- Leader key MUST be set before any plugins load (done in `init.lua` before any `require`)
- Plugin files return `{ add, setup, build }`; the header of `plugins/init.lua` defines the three
- LSP servers are defined in `lua/external/lsp_servers.lua` (a plain table, kept out of the plugin spec so `nvim/tests/lsp_servers_spec.lua` can assert on it under `--clean`) and wired up in `lua/external/plugins/lsp.lua`. There is no Mason: native servers are declared in `../deps.conf`, JS ones in `lsp-servers/package.json` and run as `bun <path>` via explicit `cmd` overrides. TypeScript's `tsc` (TS 7, native) also comes from `lsp-servers/package.json` but runs as the platform binary directly, with no runtime
- Formatters are configured in `lua/external/plugins/formatter.lua` (conform.nvim) by filetype
- There is no lint plugin. Lint is a language server's diagnostics (`ruff` for Python, `sqruff` for SQL, shellcheck through `bashls`); nvim-lint was removed in 2026-11 when its one linter, ruff, moved to `ruff server`
- `plugins/lsp.lua` enables a server only if its binary is on PATH, so a machine that has not run `make install nvim` degrades instead of erroring; `:checkhealth external` names what is off
- There is no completion plugin. Completion is nvim's own (`vim.lsp.completion.enable` with `autotrigger`, set up in `plugins/lsp.lua`), which opens on a server's trigger characters. `blink.cmp` sat in the list as `enabled = false` from 2026-06 to 2026-10 and was deleted rather than kept off

## Adding a New Plugin

1. Create `lua/external/plugins/<name>.lua` returning `{ add = { <repository URLs> }, setup = function() ... end }`
2. Add `'<name>'` to `modules` in `lua/external/plugins/init.lua`
3. Start nvim, which installs it and adds its commit to `nvim-pack-lock.json`. Commit the lockfile with the other two files; `make test` fails while the list and the lockfile disagree

## Plugins are pinned by `nvim-pack-lock.json`

`vim.pack` records each plugin's commit in `nvim-pack-lock.json`, and the file is tracked, which is what nvim's docs recommend. Every machine runs the same plugin code, and an update is a diff in a PR.

- **`make -C nvim sync` applies the lockfile and never updates.** It checks out the pinned commits and deletes plugins no longer listed (`sync()` in `plugins/init.lua`). `make install nvim` runs it.
- **Updating is by hand:** `:lua vim.pack.update()`, read the changes, `:write`, commit the lockfile. Nothing proposes these bumps: no bot reads this file, and no advisory database covers Neovim plugins.
- **Removing a plugin needs sync before the commit.** `vim.pack` installs whatever the lockfile names, listed or not, so a line deleted from `modules` comes back until `sync` drops it from the lockfile.
- **Everything loads at startup.** `vim.pack` has no lazy loading; with 15 plugins there is nothing to defer. Don't rebuild lazy.nvim's `event`/`ft` triggers on top of it.
- **`confirm = false` on `vim.pack.add`** departs from the default, which asks before a first install. The lockfile already says which commits will be fetched, and `make install` runs headless.
- **Build steps** are the `build` field, run from one `PackChanged` autocmd registered before `vim.pack.add`: telescope-fzf-native's `make`, and `:TSUpdate` after a treesitter update.

History: lazy.nvim was the manager until 2026-11. Its `lazy-lock.json` was gitignored and `Lazy! sync` moved every plugin to its newest commit on each install, so the "pinned commits" this repo's docs claimed did not exist. rocks.nvim was considered and passed over: no advisory database lists LuaRocks either, and its README asks new users to wait for a rewrite.

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
