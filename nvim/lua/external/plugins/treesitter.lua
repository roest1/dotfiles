return {
  'nvim-treesitter/nvim-treesitter',
  lazy = false,
  build = ':TSUpdate',
  config = function()
    require('nvim-treesitter').install {
      'c_sharp',
      'lua',
      'json',
      'yaml',
      'bash',
      'markdown',
      'sql',
    }
  end,
}
