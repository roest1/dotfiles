-- The file browser.
--   -           open the current file's directory
--   <leader>-   the same, in a floating window
return {
  add = {
    'https://github.com/stevearc/oil.nvim',
    'https://github.com/nvim-tree/nvim-web-devicons',
  },
  setup = function()
    require('oil').setup {
      columns = { 'icon' },
      view_options = {
        show_hidden = true,
      },
    }

    -- Per-file git diffstat floated at the right edge (`:OilGit` to toggle)
    require('external.oilgit').setup()

    vim.keymap.set('n', '-', '<CMD>Oil<CR>', { desc = 'Open parent directory' })
    vim.keymap.set('n', '<leader>-', require('oil').toggle_float)
  end,
}
