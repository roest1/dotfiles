local M = {}

-- Get current directory when inside Oil
local function get_oil_dir()
  -- If Oil is open, buffer name is like: oil://~/path/here/
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname:match '^oil://' then
    local real = bufname:gsub('^oil://', '')
    return vim.fn.fnamemodify(real, ':p')
  end
  -- fallback: normal file buffer
  return vim.fn.expand '%:p:h'
end

-- Core behavior: match the Bash script style
local function copy_directory_contents(recursive)
  local dir = get_oil_dir()
  if dir == '' or vim.fn.isdirectory(dir) == 0 then
    print '❌ Not in a valid directory'
    return
  end

  -- choose command based on flag
  local find_cmd
  if recursive then
    find_cmd = string.format("find '%s' -type f", dir) -- recursive
  else
    find_cmd = string.format("find '%s' -maxdepth 1 -type f", dir) -- non-recursive
  end

  local handle = io.popen(find_cmd)
  local output = handle:read '*a'
  handle:close()

  local files = vim.split(output, '\n', { trimempty = true })
  if #files == 0 then
    print '📁 No files found'
    return
  end

  local parts = {}
  for _, file in ipairs(files) do
    table.insert(parts, ('--- Start of %s ---'):format(file))
    table.insert(parts, io.open(file, 'r'):read '*a')
    table.insert(parts, ('--- End of %s ---\n'):format(file))
  end

  vim.fn.setreg('+', table.concat(parts, '\n'))
  print('📋 Copied ' .. #files .. ' files ' .. (recursive and '(recursive)' or '(non-recursive)'))
end

function M.setup()
  vim.api.nvim_create_user_command('Copy', function(opts)
    local arg = opts.args

    if arg == '-r' or arg == '--r' or arg == '--recursive' then
      copy_directory_contents(true) -- recursive mode
    else
      copy_directory_contents(false) -- default non-recursive
    end
  end, {
    nargs = '?',
    complete = function(_, _, _)
      return { '-r', '--recursive' } -- tab completion
    end,
    desc = 'Copy file contents from current Oil dir (use -r for recursive)',
  })
end

return M
