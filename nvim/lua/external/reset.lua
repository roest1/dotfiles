-- This will clear all neovim cache
-- and force reinstall all plugins

-- ~/.config/nvim/lua/external/reset.lua
--
-- Safely wipes Neovim cache + lazy plugin state
-- Useful when plugins get corrupted or out-of-sync.
--
-- Usage:
--   :ResetNvim        -> prompts for confirmation
--   :ResetNvim!       -> force without confirmation

local M = {}

local function expand(path)
  return vim.fn.expand(path)
end

local RESET_PATHS = {
  '~/.local/share/nvim',
  '~/.cache/nvim',
}

local function delete_dir(path)
  if vim.fn.isdirectory(path) == 1 then
    vim.fn.delete(path, 'rf')
    return true
  end
  return false
end

local function reset(confirm)
  local deleted = {}

  for _, p in ipairs(RESET_PATHS) do
    local path = expand(p)
    local ok = delete_dir(path)
    if ok then
      table.insert(deleted, path)
    end
  end

  if #deleted == 0 then
    vim.notify('Nothing to delete — directories already clean.', vim.log.levels.INFO)
    return
  end

  vim.notify('Deleted:\n' .. table.concat(deleted, '\n'), vim.log.levels.WARN, { title = 'ResetNvim' })

  vim.notify('Restart Neovim to reinstall plugins.', vim.log.levels.INFO)
end

function M.setup()
  vim.api.nvim_create_user_command('ResetNvim', function(opts)
    local force = opts.bang

    if not force then
      local choice = vim.fn.confirm('This will permanently delete Neovim cache and plugins.\nContinue?', '&Yes\n&No', 2)

      if choice ~= 1 then
        vim.notify('Reset canceled.', vim.log.levels.INFO)
        return
      end
    end

    reset()
  end, {
    bang = true,
    desc = 'Delete ~/.local/share/nvim and ~/.cache/nvim (forces plugin reinstall)',
  })
end

return M
