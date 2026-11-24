-- Entry point. `:help dotfiles` is the one page that says what this config adds.
--
-- Order matters once: the leader key must be set before any plugin loads, or
-- their <leader> mappings bind to the wrong key.
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

-- [[ Setting options ]]
require 'options'

-- [[ Basic Keymaps ]]
require 'keymaps'

-- [[ Install and configure plugins ]] The list is lua/external/plugins/init.lua.
require('external.plugins').setup()

require('external.findreplace').setup()
require('external.copy').setup()
require('external.pasteimg').setup()
require('external.altfont').setup()
require('external.usage').setup()
