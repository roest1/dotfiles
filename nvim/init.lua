--[[

Important Links / references:
-----------------------------

Inspiration from: https://github.com/dam9000/kickstart-modular.nvim.git


How Neovim integrates Lua: `:help lua-guide` 
- (or HTML version): https://neovim.io/doc/user/lua-guide.html

Neovim Tutor: `:Tutor`

Help: `:help`
- (or telescope version): `<space>sh` to [s]earch the [h]elp documentation
- several `:help X` options for relevant settings, plugins, or Neovim features

Check Health: `:checkhealth` 
- tells you what plugins are missing or misconfigured

--]]

-- Set <space> as the leader key
-- See `:help mapleader`
--  NOTE: Must happen before plugins are loaded (otherwise wrong leader will be used)
vim.g.mapleader = ' ' -- global leader key
vim.g.maplocalleader = ' ' -- used for mappings that only make sense in certain filetypes or buffers

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = true

-- [[ Setting options ]]
require 'options'

-- [[ Basic Keymaps ]]
require 'keymaps'

-- [[ Install `lazy.nvim` plugin manager ]]
require 'lazy-bootstrap'

-- [[ Configure and install plugins ]]
require 'lazy-plugins'
