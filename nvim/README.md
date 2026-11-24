# nvim

Personal Neovim configuration. Modular, documented, and designed to be understood line-by-line. Rebuilt from [kickstart-modular.nvim](https://github.com/dam9000/kickstart-modular.nvim).

## Install

Requires Neovim 0.12+ (installed automatically) and a Nerd Font (e.g. [0xProto](https://github.com/ryanoasis/nerd-fonts/releases)) set as your terminal font.

This config lives in the [dotfiles](https://github.com/roest1/dotfiles) monorepo,
not in a standalone repo. `~/.config/nvim` is a **symlink** into `dotfiles/nvim`,
so the config is version-controlled in place — don't clone into it.

| Step               | Command                                                           |
| ------------------ | ----------------------------------------------------------------- |
| 1. Clone dotfiles  | `git clone https://github.com/roest1/dotfiles.git ~/dotfiles`      |
| 2. Install + sync  | `cd ~/dotfiles && make install nvim`                               |
| 3. Build help docs | `:helptags ~/.config/nvim/doc` &nbsp;→&nbsp; `:help dotfiles`         |

`make install nvim` links the config and installs the `[nvim]` section of
`../deps.conf`. From inside this directory, `make all` does the same thing by
delegating upward: `make deps` (the manifest's `[nvim]` section, so there's one
source of truth for the toolchain) then `make sync` (plugins at the commits in
`nvim-pack-lock.json`, plus tree-sitter parsers, headless). Both are idempotent. Verify with
`:checkhealth external` inside nvim.

**Installs:** neovim, git, make, unzip, ripgrep, fd, stylua, tree-sitter, ruff, plus the language servers — clangd, lua-language-server and lemminx as native binaries, and six JavaScript-based servers from `lsp-servers/package.json` installed with `bun`. `prettier` comes from that same manifest and is run the same way.

There is no Mason, and no node, npm or pip anywhere in the toolchain. Every server is declared ahead of time rather than fetched at first launch — see the "No node, npm or pip" footgun in the parent repo's `CLAUDE.md` for why.

**Other targets:** `make update` (git pull + reinstall), `make clean` (wipe plugin + cache state).

## Layout

<details>
<summary>Directory tree</summary>

```
~/.config/nvim/
├── init.lua                 Entry point
├── deps.sh                  Editor-toolchain installer
├── lua/
│   ├── options.lua          Editor settings (tabs, search, clipboard, etc.)
│   ├── keymaps.lua          Core keybindings
│   └── external/
│       ├── reqs.lua         Tool dependency list (used by deps + health)
│       ├── lsp_servers.lua  Language server definitions (cmd/args/settings)
│       ├── copy.lua         :Copy command (clipboard export for AI/docs)
│       ├── findreplace.lua  :Find / :FindReplace commands
│       ├── pasteimg.lua     :PasteImage command
│       ├── oilgit.lua       :OilGit diffstat column in Oil
│       ├── altfont.lua      :AltFont, the alternate-font carrier
│       ├── usage.lua        :KeymapUsage, counts real presses per mapping
│       ├── health.lua       :checkhealth integration
│       └── plugins/         One file per plugin
│           ├── formatter.lua       Formatter config (conform.nvim)
│           ├── gitsigns.lua        Git gutter signs + staging
│           ├── lsp.lua             Language server setup (no Mason)
│           ├── oil.lua             File browser
│           ├── roslyn.lua          C# language server (off; see plugins/init.lua)
│           ├── telescope.lua       Fuzzy finder
│           ├── theme.lua           Colorschemes on offer (default Rose Pine Moon)
│           └── treesitter.lua      Syntax highlighting
└── doc/                     Help files (:help dotfiles)
```

</details>

## Keymaps

Leader key is `Space`. New to vim motions? See `:help motion.txt` — the built-in
docs are authoritative and always match your version.

| Keys              | Action                    |
| ----------------- | ------------------------- |
| `<leader>sf`      | Find files                |
| `<leader>sg`      | Search text, plain by default |
| `-`               | File browser (Oil)        |
| `grd`             | Go to definition          |
| `grr`             | Find references           |
| `grn`             | Rename symbol             |
| `<leader>l`       | Format file               |

Full reference: `:help dotfiles`, one page, checked by CI against the config
in both directions. `:KeymapUsage` shows which of them you actually press.

## Maintenance

| Command        | What                                 |
| -------------- | ------------------------------------ |
| `:lua vim.pack.update()` | Update plugins: read the changes, `:write` to accept, then commit `nvim-pack-lock.json` |
| `:checkhealth`  | Verify tools + formatters            |
| `:KeymapUsage`  | Which mappings you never press       |

Language servers aren't managed from inside the editor. Native ones are declared
in `../deps.conf` (`make install nvim`); the JavaScript ones live in
`lsp-servers/package.json` — `bun install --cwd nvim/lsp-servers` to update,
`bun lsp-servers/verify.ts` to prove all six still complete an LSP handshake.

## License

MIT
