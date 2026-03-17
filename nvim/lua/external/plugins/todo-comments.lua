-- todo-comments
-- Highlights TODO, FIXME, HACK, NOTE, WARN, PERF in comments
-- and makes them searchable via Telescope
--
-- Keymaps:
--   <leader>st   Search all TODOs in project
--   ]t           Jump to next TODO
--   [t           Jump to previous TODO
return {
  'folke/todo-comments.nvim',
  event = 'VimEnter',
  dependencies = { 'nvim-lua/plenary.nvim' },
  opts = {
    signs = true,
  },
  keys = {
    {
      ']t',
      function()
        require('todo-comments').jump_next()
      end,
      desc = 'Next [T]odo comment',
    },
    {
      '[t',
      function()
        require('todo-comments').jump_prev()
      end,
      desc = 'Prev [T]odo comment',
    },
    {
      '<leader>st',
      '<cmd>TodoTelescope<cr>',
      desc = '[S]earch [T]odos',
    },
  },
}
