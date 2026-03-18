-- lua/keymaps.lua
--
-- Core keybindings and autocommands.
-- Plugin-specific keymaps live in their own plugin files.

-- Clear search highlights with Escape
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- End of line: L (since 0 goes to beginning)
vim.keymap.set('n', 'L', '$')
vim.keymap.set('v', 'L', '$')

-- Remove carriage return characters (^M from Windows files)
vim.keymap.set('n', '<leader>cr', [[:%s/\r//g<CR>]], { desc = 'Remove ^M (carriage returns)' })

-- Split navigation with Ctrl+hjkl
vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

-- Diagnostics
vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

-- Highlight yanked text briefly
vim.api.nvim_create_autocmd('TextYankPost', {
  desc = 'Highlight when yanking (copying) text',
  group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
  callback = function()
    vim.hl.on_yank()
  end,
})

-- Yank entire buffer to system clipboard
vim.api.nvim_create_user_command('YankBuffer', function()
  vim.cmd 'normal! gg"+yG'
end, { desc = 'Copy entire buffer to system clipboard (OSC52)' })

vim.cmd [[
cnoreabbrev <expr> %y ((getcmdtype() == ':' && getcmdline() ==# '%y') ? 'YankBuffer' : '%y')
]]
