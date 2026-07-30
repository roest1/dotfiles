-- which-key
-- Shows pending keybindings in a popup
-- So you never forget what <leader>s... does
return {
  'folke/which-key.nvim',
  event = 'VimEnter',
  opts = {
    delay = 300, -- ms before popup shows (matches your timeoutlen)
    icons = {
      mappings = vim.g.have_nerd_font,
    },
    spec = {
      { '<leader>s', group = '[S]earch' },
      { '<leader>h', group = 'Git [H]unk' },
      { '<leader>t', group = '[T]oggle' },
      { '<leader>x', group = 'Trouble' },
      { '<leader>c', group = '[C]ode' },
    },
  },
}
