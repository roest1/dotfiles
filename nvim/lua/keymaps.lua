--[[
File: lua/keymaps.lua

Summary:
--------
Defines core key mappings and autocommands to improve editing ergonomics.

Keybindings:
------------
- <Esc>       → Clears search highlights (`:nohlsearch`)
- 9           → Moves to end of line (both in normal and visual mode) — replaces `$`
- <C-h>       → Move to split window on the left
- <C-l>       → Move to split window on the right
- <C-j>       → Move to split window below
- <C-k>       → Move to split window above
- <leader>q   → Open diagnostic quickfix list

Autocommands:
-------------
- `TextYankPost` highlights yanked text briefly (helpful visual cue when copying)

References:
-----------
- `:help vim.keymap.set()`
- `:help wincmd`
- `:help hlsearch`
- `:help lua-guide-autocommands`
- `:help vim.hl.on_yank()`
]]

-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`

-- Clear highlights on search when pressing <Esc> in normal mode
--  See `:help hlsearch`
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- Diagnostic keymaps
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Use 9 to move cursor to the end of a line since 0 is to move to beginning
vim.keymap.set('n', '9', '$')
vim.keymap.set('v', '9', '$')

-- Remove carriage return character ^M
vim.keymap.set('n', '<leader>cr', [[:%s/\r//g<CR>]], { desc = 'Remove ^M (carriage returns)' })

-- Keybinds to make split navigation easier.
--  Use CTRL+<hjkl> to switch between windows
--
--  See `:help wincmd` for a list of all window commands
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

-- Diagnostic keymaps
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- [[ Basic Autocommands ]]
--  See `:help lua-guide-autocommands`

-- Highlight when yanking (copying) text
--  Try it with `yap` in normal mode
--  See `:help vim.hl.on_yank()`
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})
