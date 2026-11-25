-- The file browser.
--   -           open the current file's directory
--   <leader>-   the same, in a floating window
return {
  add = {
    'https://github.com/stevearc/oil.nvim',
    'https://github.com/nvim-tree/nvim-web-devicons',
  },
  setup = function()
    -- Before oil loads: it chooses where icons come from once, on the way in.
    require('external.icons').wrap_oil()
    require('oil').setup {
      -- The icon set is a pick (`theme`, external/icons.lua), and the column's
      -- options are where its spacing and its fallback folder icon are set.
      columns = require('external.icons').oil_columns(),
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
