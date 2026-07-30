-- Oil
-- Directory viewer
-- Keymaps:
-- `-` to open parent directory in current window
-- `<leader>-` to open parent directory in floating window

return {
  {
    'stevearc/oil.nvim',
    dependencies = { 'nvim-tree/nvim-web-devicons' },
    config = function()
      require('oil').setup {
        columns = { 'icon', 'size' },
        view_options = {
          show_hidden = true,
        },
      }

      -- Per-file git diffstat floated at the right edge (`:OilGit` to toggle)
      require('external.oilgit').setup()

      -- Toggle optional columns. Usage: :OilColumns mtime size
      -- Calling with no args prints the current column list.
      local OPTIONAL_ORDER = { 'mtime', 'size', 'atime', 'ctime', 'birthtime', 'type', 'permissions' }
      vim.api.nvim_create_user_command('OilColumns', function(opts)
        local oil = require 'oil'
        local cfg = require 'oil.config'
        local enabled = {}
        for _, col in ipairs(cfg.columns) do
          local name = type(col) == 'table' and col[1] or col
          if name ~= 'icon' then
            enabled[name] = true
          end
        end
        if #opts.fargs == 0 then
          local names = { 'icon' }
          for _, c in ipairs(OPTIONAL_ORDER) do
            if enabled[c] then
              table.insert(names, c)
            end
          end
          vim.notify('columns: ' .. table.concat(names, '  '), vim.log.levels.INFO, { title = 'oil' })
          return
        end
        for _, arg in ipairs(opts.fargs) do
          if enabled[arg] then
            enabled[arg] = nil
          else
            enabled[arg] = true
          end
        end
        local new_cols = { 'icon' }
        for _, c in ipairs(OPTIONAL_ORDER) do
          if enabled[c] then
            table.insert(new_cols, c)
          end
        end
        oil.set_columns(new_cols)
      end, {
        nargs = '*',
        complete = function(arg_lead)
          if arg_lead == '' then
            return OPTIONAL_ORDER
          end
          local out = {}
          for _, v in ipairs(OPTIONAL_ORDER) do
            if v:sub(1, #arg_lead) == arg_lead then
              table.insert(out, v)
            end
          end
          return out
        end,
        desc = 'Toggle oil display columns',
      })

      -- Open parent directory in current window
      vim.keymap.set('n', '-', '<CMD>Oil<CR>', { desc = 'Open parent directory' })

      -- Open parent directory in floating window
      vim.keymap.set('n', '<leader>-', require('oil').toggle_float)
    end,
  },
}
