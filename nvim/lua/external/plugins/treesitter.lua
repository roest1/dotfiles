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
      'markdown_inline',
      'latex',
      'sql',
      'typescript',
      'javascript',
      'tsx',
      'terraform',
      'python',
    }
  end,
}
