# roest-nvim

Personal Neovim configuration. Modular, documented, and designed to be understood line-by-line.

Forked from [kickstart-modular.nvim](https://github.com/dam9000/kickstart-modular.nvim) and rebuilt into something personal.

## Install

### 1. Prerequisites

You need Neovim 0.10+ and a Nerd Font. The bootstrap script handles the rest.

```sh
# Install Neovim (if you don't have it)
brew install neovim    # macOS/Linuxbrew
# or: sudo apt install neovim  (Ubuntu PPA recommended for latest)

# Install a Nerd Font (required for icons)
# Download 0xProto: https://github.com/ryanoasis/nerd-fonts/releases
# Set it as your terminal font
```

### 2. Clone

```sh
git clone https://github.com/roest1/roest-nvim.git ~/.config/nvim
```

### 3. Bootstrap

```sh
cd ~/.config/nvim
chmod +x bootstrap.sh
./bootstrap.sh
```

This installs all external tools: core utilities (ripgrep, fd), formatters (stylua, prettierd, ruff), and productivity tools (zoxide, fzf, bat, eza).

### 4. First launch

```sh
nvim
```

Lazy installs all plugins automatically. Mason installs LSP servers on first open.
Run `:checkhealth` to verify everything is working.

### 5. Build help docs

```vim
:helptags ~/.config/nvim/doc
```

Now `:help roest` works.

## What's in here

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
│           ├── blink-cmp.lua    Autocompletion
│           ├── formatter.lua    Auto-format on save (conform.nvim)
│           ├── gitsigns.lua     Git gutter signs + staging
│           ├── glow.lua         Markdown preview
│           ├── harpoon.lua      Working file set
│           ├── lint.lua         Async linting (nvim-lint)
│           ├── lsp.lua          Language servers + Mason
│           ├── mini.lua         Surround + autopairs
│           ├── oil.lua          File browser
│           ├── roslyn.lua       C# language server
│           ├── telescope.lua    Fuzzy finder
│           ├── theme.lua        Rose Pine Moon colorscheme
│           ├── todo-comments.lua  TODO/FIXME highlighting
│           ├── treesitter.lua   Syntax highlighting
│           ├── trouble.lua      Diagnostics panel
│           ├── undotree.lua     Visual undo history
│           └── which-key.lua    Keymap discovery popup
└── doc/                     Help files (:help roest)
```

## How this config works (Stuff I use)

### Commands: <operator> <count> <motion>

- all three are [optional] ($2^3 = 8$ styles of vim commands)

* `:<count>` (go to line)
* `<motion>`
* `<count><motion>`
* `<operator>[<operator>]` (line-wise)
* `<operator>[<count>]<motion>`
* `<count><operator><motion>`

### Operators

- `d`: delete
- `y`: yank (copy)
- `p` / `P`: put (paste)
- `<` / `>`: change indent (tip: use on selected text and then `.` to apply the indent multiple time)
- `~`: toggle case

### Motions

- `h`: ←
- `j`: ↓
- `k`: ↑
- `l`: →

- `^`: First non-whitespace character
- `0`: Beginning of line
- `L`: End of line
- `w`: Next word (start)
- `e`: Next word (end)
- `b`: Previous word

- `gg`: Beginning of file
- `G`: End of file
- `{` / `}`: Paragraph up / down
- `%`: Jump to matching "()", "{}", "[]"

### Commands I like to use

- `:%y`: Copy all text in a file
- `:term`: Open up terminal in window
- `:term python --args %`: Run current file as python program with args (replace interpreter/compiler)

### Macros

Macros let you record and replay sequences (vim commands)

1. Record: `q<letter>` (ex: "qa" starts recording into register `a`)
2. Do vim commands
3. Stop Recording: `q`

- `@a`: Replay macro from register _a_
- `@@`: Replay last macro

### Window Splits

- `:vsplit` or `:vsp`: Vertical split
- `:split` or `:sp`: Horizontal split
- `<Ctrl>+w` `hjkl`: Move between splits
- `<space>-`: Floating directory nav (see oil)
- `-`: directory nav (see oil)

### Quick reference

Leader key is `Space`.

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
