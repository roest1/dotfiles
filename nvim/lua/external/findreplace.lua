-- lua/external/findreplace.lua
--
-- :Find <keyword>          Find files by content, filename, or directory name
-- :FindReplace <old> <new> Replace across project with confirmation
--
-- :Find searches three ways and combines results:
--   1. File contents  — files containing the keyword (via rg)
--   2. Filenames      — files whose name matches the keyword (via fd)
--   3. Directory names — all files inside directories matching the keyword (via fd)
--
-- All results are deduplicated and loaded into the args list.

local M = {}

--- Get files whose CONTENTS match the keyword (rg -l)
local function files_by_content(keyword)
  local output = vim.fn.systemlist { 'rg', '-l', '--hidden', '--glob', '!.git', keyword }
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return vim.tbl_filter(function(line)
    return line ~= ''
  end, output)
end

--- Get files whose NAME matches the keyword (fd --type f)
local function files_by_name(keyword)
  if vim.fn.executable 'fd' ~= 1 then
    return {}
  end
  local output = vim.fn.systemlist { 'fd', '--type', 'f', '--hidden', '--exclude', '.git', keyword }
  if vim.v.shell_error ~= 0 then
    return {}
  end
  return vim.tbl_filter(function(line)
    return line ~= ''
  end, output)
end

--- Get all files inside DIRECTORIES whose name matches the keyword
local function files_by_dir_name(keyword)
  if vim.fn.executable 'fd' ~= 1 then
    return {}
  end

  -- First find matching directories
  local dirs = vim.fn.systemlist { 'fd', '--type', 'd', '--hidden', '--exclude', '.git', keyword }
  if vim.v.shell_error ~= 0 or #dirs == 0 then
    return {}
  end

  -- Then collect all files inside those directories
  local all_files = {}
  for _, dir in ipairs(dirs) do
    if dir ~= '' then
      local files = vim.fn.systemlist { 'fd', '--type', 'f', '--hidden', '--exclude', '.git', '.', dir }
      if vim.v.shell_error == 0 then
        for _, f in ipairs(files) do
          if f ~= '' then
            table.insert(all_files, f)
          end
        end
      end
    end
  end

  return all_files
end

--- Combine, deduplicate, and sort file lists
local function merge_file_lists(...)
  local seen = {}
  local result = {}

  for _, list in ipairs { ... } do
    for _, file in ipairs(list) do
      -- Normalize to absolute path for deduplication
      local abs = vim.fn.fnamemodify(file, ':p')
      if not seen[abs] then
        seen[abs] = true
        table.insert(result, file)
      end
    end
  end

  table.sort(result)
  return result
end

function M.setup()
  -- :Find <keyword>
  -- Searches file contents, filenames, and directory names
  vim.api.nvim_create_user_command('Find', function(opts)
    local args = vim.split(opts.args, ' ')
    if #args ~= 1 then
      vim.notify('Usage: :Find <keyword>', vim.log.levels.WARN)
      return
    end

    local keyword = args[1]

    -- Search all three sources
    local by_content = files_by_content(keyword)
    local by_name = files_by_name(keyword)
    local by_dir = files_by_dir_name(keyword)

    local files = merge_file_lists(by_content, by_name, by_dir)

    if #files == 0 then
      vim.notify('No files found for: ' .. keyword, vim.log.levels.INFO)
      return
    end

    -- Report what was found
    local parts = {}
    if #by_content > 0 then
      table.insert(parts, #by_content .. ' by content')
    end
    if #by_name > 0 then
      table.insert(parts, #by_name .. ' by filename')
    end
    if #by_dir > 0 then
      table.insert(parts, #by_dir .. ' by directory')
    end

    local escaped = vim.tbl_map(function(f)
      return vim.fn.fnameescape(f)
    end, files)

    vim.cmd('args ' .. table.concat(escaped, ' '))
    vim.notify(string.format('%d files (%s)', #files, table.concat(parts, ', ')), vim.log.levels.INFO)
  end, {
    nargs = 1,
    desc = 'Find files by content, filename, or directory name',
  })

  -- :FindReplace <find> <replace>
  vim.api.nvim_create_user_command('FindReplace', function(opts)
    local args = vim.split(opts.args, ' ')
    if #args ~= 2 then
      vim.notify('Usage: :FindReplace <find> <replace>', vim.log.levels.WARN)
      return
    end

    local find, replace = unpack(args)

    -- For replacement, only search file contents (not filenames)
    local files = files_by_content(find)

    if #files == 0 then
      vim.notify('No files contain: ' .. find, vim.log.levels.INFO)
      return
    end

    local escaped = vim.tbl_map(function(f)
      return vim.fn.fnameescape(f)
    end, files)

    vim.cmd('args ' .. table.concat(escaped, ' '))

    local escaped_find = vim.fn.escape(find, '/\\')
    local escaped_replace = vim.fn.escape(replace, '/\\')
    vim.cmd(string.format('argdo %%s/%s/%s/gc | update', escaped_find, escaped_replace))
  end, {
    nargs = '*',
    desc = 'Find and replace across project using ripgrep',
  })
end

return M
