# roest-nvim

Personal Neovim configuration. Modular, documented, and designed to be understood line-by-line. Rebuilt from [kickstart-modular.nvim](https://github.com/dam9000/kickstart-modular.nvim).

## Install

Requires Neovim 0.10+ and a Nerd Font (e.g. [0xProto](https://github.com/ryanoasis/nerd-fonts/releases)) set as your terminal font.

| Step               | Command                                                             |
| ------------------ | ------------------------------------------------------------------- |
| 1. Install Neovim  | `brew install neovim` &nbsp;·&nbsp; `sudo apt install neovim`       |
| 2. Clone config    | `git clone https://github.com/roest1/roest-nvim.git ~/.config/nvim` |
| 3. Bootstrap tools | `cd ~/.config/nvim && chmod +x bootstrap.sh && ./bootstrap.sh`      |
| 4. First launch    | `nvim` &nbsp;(Lazy + Mason auto-install)                            |
| 5. Build help docs | `:helptags ~/.config/nvim/doc` &nbsp;→&nbsp; `:help roest`          |

**Bootstrap installs:** ripgrep, fd, stylua, prettierd, ruff, eslint_d, zoxide, fzf, bat, eza, plus runtimes (node, python3, cargo). Mason handles LSP servers on first launch. Run `:checkhealth roest` to verify everything.

## Layout

<details>
<summary>Directory tree</summary>

```
~/.config/nvim/
├── init.lua                 Entry point
├── bootstrap.sh             One-command dependency installer
├── lua/
│   ├── options.lua          Editor settings (tabs, search, clipboard, etc.)
│   ├── keymaps.lua          Core keybindings
│   ├── lazy-bootstrap.lua   Plugin manager setup
│   ├── lazy-plugins.lua     Plugin loader
│   └── external/
│       ├── reqs.lua         Tool dependency list (used by bootstrap + health)
│       ├── copy.lua         :Copy command (clipboard export for AI/docs)
│       ├── findreplace.lua  :Find / :FindReplace commands
│       ├── reset.lua        :ResetNvim command
│       ├── health.lua       :checkhealth integration
│       └── plugins/         One file per plugin
│           ├── blink-cmp.lua       Autocompletion
│           ├── formatter.lua       Auto-format on save (conform.nvim)
│           ├── gitsigns.lua        Git gutter signs + staging
│           ├── glow.lua            Markdown preview
│           ├── harpoon.lua         Working file set
│           ├── lint.lua            Async linting (nvim-lint)
│           ├── lsp.lua             Language servers + Mason
│           ├── mini.lua            Surround + autopairs
│           ├── oil.lua             File browser
│           ├── roslyn.lua          C# language server
│           ├── telescope.lua       Fuzzy finder
│           ├── theme.lua           Rose Pine Moon colorscheme
│           ├── todo-comments.lua   TODO/FIXME highlighting
│           ├── treesitter.lua      Syntax highlighting
│           ├── trouble.lua         Diagnostics panel
│           ├── undotree.lua        Visual undo history
│           └── which-key.lua       Keymap discovery popup
└── doc/                     Help files (:help roest)
```

</details>

## Keymaps

Leader key is `Space`. New to vim motions? See `:help roest-motions`.

| Keys              | Action                    |
| ----------------- | ------------------------- |
| `<leader>sf`      | Find files                |
| `<leader>sg`      | Grep across project       |
| `<leader>/`       | Fuzzy search current file |
| `-`               | File browser (Oil)        |
| `<leader>a`       | Add file to Harpoon       |
| `<C-n>` / `<C-p>` | Next/prev Harpoon file    |
| `grd`             | Go to definition          |
| `grr`             | Find references           |
| `grn`             | Rename symbol             |
| `<leader>l`       | Format file               |
| `<leader>e`       | Show error popup          |

Full reference: `:help roest-keymaps`

## Documentation

| Command                 | What                       |
| ----------------------- | -------------------------- |
| `:help roest`           | Start here                 |
| `:help roest-keymaps`   | All keybindings            |
| `:help roest-plugins`   | Plugin reference           |
| `:help roest-workflows` | "How do I..." recipes      |
| `:help roest-commands`  | Custom commands            |
| `:help roest-motions`   | Vim motions cheatsheet     |
| `:help roest-bash`      | Bash productivity commands |

## Maintenance

| Command        | What                                 |
| -------------- | ------------------------------------ |
| `:Lazy update` | Update plugins                       |
| `:Mason`       | Manage LSP servers                   |
| `:checkhealth` | Verify tools + formatters            |
| `:ResetNvim`   | Nuclear reset (reinstall everything) |

## License

MIT
