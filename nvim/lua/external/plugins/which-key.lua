-- which-key
-- Shows pending keybindings in a popup
-- So you never forget what <leader>s... does
--
-- One group, because one prefix has more than one key under it. Git [H]unk,
-- [T]oggle, Trouble and [C]ode were listed here for four months after commit
-- 37fa6ce deleted every mapping beneath them -- which-key happily shows an
-- empty group, so nothing complained. A group belongs here only once a
-- second mapping shares its prefix.
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
    },
  },
}
