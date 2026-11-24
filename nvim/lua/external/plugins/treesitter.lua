-- Parsers, which are what syntax highlighting is drawn from.
return {
  add = { 'https://github.com/nvim-treesitter/nvim-treesitter' },
  build = {
    -- A new plugin commit can expect newer parsers. A first install needs
    -- nothing here: setup below installs whatever is missing.
    ['nvim-treesitter'] = function(data)
      if data.kind == 'update' and vim.fn.exists ':TSUpdate' == 2 then
        vim.cmd 'TSUpdate'
      end
    end,
  },
  setup = function()
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
      'rust',
      'toml',
    }
  end,
}
