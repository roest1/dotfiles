-- ~/.config/nvim/lua/external/plugins/findreplace.lua

local M = {}

-- Extracted helper function to get files matching a string
local function get_files_matching(find)
  local handle = io.popen('rg -l ' .. find)
  if not handle then
    print 'Failed to run ripgrep'
    return nil
  end

  local result = handle:read '*a'
  handle:close()

  local files = vim.split(result, '\n', { trimempty = true })
  if #files == 0 then
    print('No files found containing: ' .. find)
    return nil
  end

  return files
end

function M.setup()
  -- :Find <keyword>
  vim.api.nvim_create_user_command('Find', function(opts)
    local args = vim.split(opts.args, ' ')
    if #args ~= 1 then
      print 'Usage: :Find <keyword>'
      return
    end

    local find = args[1]
    local files = get_files_matching(find)
    if not files then
      return
    end

    vim.cmd('args ' .. table.concat(files, ' '))
    print 'Files added to args list.'
  end, {
    nargs = 1,
    desc = 'Set args list to files containing keyword via ripgrep',
  })

  -- :FindReplace <find> <replace>
  vim.api.nvim_create_user_command('FindReplace', function(opts)
    local args = vim.split(opts.args, ' ')
    if #args ~= 2 then
      print 'Usage: :FindReplace <find> <replace>'
      return
    end

    local find, replace = unpack(args)
    local files = get_files_matching(find)
    if not files then
      return
    end

    vim.cmd('args ' .. table.concat(files, ' '))
    vim.cmd(string.format('argdo %%s/%s/%s/gc | update', find, replace))
  end, {
    nargs = '*',
    desc = 'Find and replace across project using ripgrep',
  })
end

return M
