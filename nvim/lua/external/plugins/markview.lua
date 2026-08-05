-- markview
-- In-buffer markdown rendering: normal mode shows rendered headings, tables,
-- checkboxes, and LaTeX math (concealed to unicode); insert mode reverts to
-- raw source.
--   :Markview toggle   → turn rendering on/off for the buffer
-- lazy = false on the author's advice: the plugin manages its own filetype
-- activation, and lazy-loading it breaks that.
return {
  'OXY2DEV/markview.nvim',
  lazy = false,
  dependencies = { 'nvim-treesitter/nvim-treesitter' },
  opts = {},
}
