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

local function resolve_prefix_dirs(base_dir, prefixes)
  if not prefixes or #prefixes == 0 then
    return { base_dir }
  end

  local results = {}

  for _, pattern in ipairs(prefixes) do
    -- globpath returns absolute paths when base_dir is absolute
    local matches = vim.fn.globpath(base_dir, pattern, false, true)

    for _, path in ipairs(matches) do
      if vim.fn.isdirectory(path) == 1 then
        table.insert(results, vim.fn.fnamemodify(path, ':p'))
      end
    end
  end

  -- de-dupe
  local uniq = {}
  local seen = {}
  for _, p in ipairs(results) do
    if not seen[p] then
      seen[p] = true
      table.insert(uniq, p)
    end
  end

  return uniq
end

-- parse Bash style args
-- --r or --recursive
-- --exclude=
-- --prefix=
local function parse_args(fargs)
  local recursive = false
  local excludes = {}
  local prefixes = {}

  local function add_exclude(value)
    if not value or value == '' then
      return
    end

    -- Handle brace syntax: {a,b,c}
    local brace = value:match '^%{(.+)%}$'
    if brace then
      for _, item in ipairs(vim.split(brace, ',', { trimempty = true })) do
        table.insert(excludes, vim.trim(item))
      end
    else
      table.insert(excludes, value)
    end
  end

  local function add_prefix(value)
    if not value or value == '' then
      return
    end

    -- If user didn't provide glob chars, assume prefix match
    if not value:find '[*?]' then
      value = value .. '*'
    end

    table.insert(prefixes, value)
  end

  for _, arg in ipairs(fargs) do
    if arg == '-r' or arg == '--r' or arg == '--recursive' then
      recursive = true
    else
      -- --exclude=pattern
      local ex = arg:match '^%-%-exclude=(.+)$'
      if ex then
        add_exclude(ex)
      end

      -- --prefix=CarbonCapture.ETL*
      local pref = arg:match '^%-%-prefix=(.+)$'
      if pref then
        add_prefix(pref)
      end
    end
  end

  return {
    recursive = recursive,
    excludes = excludes,
    prefixes = prefixes,
  }
end

-- Core behavior: match the Bash script style
local function copy_directory_contents(opts)
  local base_dir = get_oil_dir()
  if base_dir == '' or vim.fn.isdirectory(base_dir) == 0 then
    print '❌ Not in a valid directory'
    return
  end

  -- Resolve prefix directories
  local roots = resolve_prefix_dirs(base_dir, opts.prefixes)

  if #roots == 0 then
    print '❌ No directories matched --prefix'
    return
  end

  -- Build find command
  local find_cmd = { 'find' }

  -- Multiple root directories
  for _, dir in ipairs(roots) do
    table.insert(find_cmd, dir)
  end

  if not opts.recursive then
    table.insert(find_cmd, '-maxdepth')
    table.insert(find_cmd, '1')
  end

  table.insert(find_cmd, '-type')
  table.insert(find_cmd, 'f')

  -- apply excludes
  for _, pattern in ipairs(opts.excludes or {}) do
    table.insert(find_cmd, '-not')
    table.insert(find_cmd, '-path')
    table.insert(find_cmd, '*' .. pattern .. '*')
  end

  -- Run safely without shell
  local output = vim.fn.systemlist(find_cmd)

  if vim.v.shell_error ~= 0 then
    print '❌ find command failed:'
    print(vim.inspect(find_cmd))
    return
  end

  local files = vim.tbl_filter(function(line)
    return line ~= nil and line ~= ''
  end, output)

  if #files == 0 then
    print '📁 No files found'
    return
  end

  local parts = {}
  for _, file in ipairs(files) do
    table.insert(parts, ('--- Start of %s ---'):format(file))
    local ok, lines = pcall(vim.fn.readfile, file)
    if ok and lines then
      table.insert(parts, table.concat(lines, '\n'))
    else
      table.insert(parts, '❌ Failed to read file: ' .. file)
    end

    table.insert(parts, ('--- End of %s ---\n'):format(file))
  end

  vim.fn.setreg('+', table.concat(parts, '\n'))
  print('📋 Copied ' .. #files .. ' files ' .. (opts.recursive and '(recursive)' or '(non-recursive)'))
end

function M.setup()
  vim.api.nvim_create_user_command('Copy', function(opts)
    local parsed = parse_args(opts.fargs)
    if not parsed then
      return
    end

    copy_directory_contents(parsed)
  end, {
    nargs = '*',
    complete = function()
      return { '-r', '--recursive', '--exclude', '--prefix' }
    end,
    desc = 'Copy file contents from current Oil dir (supports --recursive, --exclude, --prefix)',
  })
end

return M
