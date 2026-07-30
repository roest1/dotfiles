-- ~/.config/nvim/lua/external/copy.lua
--
-- :Copy — copy file contents to clipboard for pasting into AI chats, docs, etc.
--
-- Modes:
--   :Copy [options]           Copy files from current directory
--   :'<,'>Copy [options]      Copy selected files from Oil buffer
--                              (or selected lines from a normal buffer)
--
-- Smart defaults:
--   • In a git repo? Uses `git ls-files` (respects .gitignore automatically)
--   • Not in git? Uses `fd` (respects .gitignore by default too)
--   • Falls back to `find` with manual .gitignore parsing
--   • Always skips binary files
--
-- Usage:
--   :Copy                          Copy files in current dir (non-recursive)
--   :Copy -r                       Copy recursively
--   :Copy --match=controller       Only files whose path contains "controller"
--   :Copy --match={test,api}       Multiple match patterns (AND logic)
--   :Copy --dir_match=services     Only files inside directories matching "services"
--   :Copy --dir_match={src,lib}    Files inside dirs matching "src" OR "lib" (OR logic)
--   :Copy --exclude=migrations     Exclude paths containing pattern
--   :Copy --ext=lua                Only files with .lua extension
--   :Copy --ext={lua,py}           Multiple extensions
--   :Copy --max=50                 Limit number of files (default: 100)
--   :Copy --no-gitignore           Don't respect .gitignore
--
-- Visual selection in Oil:
--   1. Open Oil with `-`
--   2. Select files with V (visual line mode)
--   3. :'<,'>Copy
--   → Only the selected files are copied to clipboard
--
-- Visual selection in normal buffer:
--   1. Select lines with V
--   2. :'<,'>Copy
--   → Selected lines are copied in the --- Start/End --- format
--
-- All flags combine:
--   :Copy -r --dir_match=services --ext=py --exclude=test

local M = {}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

--- Get current directory (Oil-aware)
local function get_current_dir()
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname:match '^oil://' then
    local real = bufname:gsub('^oil://', '')
    return vim.fn.fnamemodify(real, ':p')
  end
  return vim.fn.expand '%:p:h'
end

--- Check if we're in an Oil buffer
local function is_oil_buffer()
  return vim.api.nvim_buf_get_name(0):match '^oil://' ~= nil
end

--- Get selected filenames from Oil buffer (visual range)
local function get_oil_selected_files(line1, line2)
  local oil_ok, oil = pcall(require, 'oil')
  if not oil_ok then
    return nil
  end

  local dir = get_current_dir()
  local files = {}

  for lnum = line1, line2 do
    local entry = oil.get_entry_on_line(0, lnum)
    if entry and entry.type == 'file' then
      table.insert(files, dir .. entry.name)
    end
  end

  return #files > 0 and files or nil
end

--- Find the git root for a given directory, or nil
local function get_git_root(dir)
  local result = vim.fn.systemlist { 'git', '-C', dir, 'rev-parse', '--show-toplevel' }
  if vim.v.shell_error == 0 and result[1] and result[1] ~= '' then
    return vim.fn.fnamemodify(result[1], ':p')
  end
  return nil
end

--- Check if a file is likely binary (quick heuristic)
local function is_binary(filepath)
  local handle = io.open(filepath, 'rb')
  if not handle then
    return true
  end
  local chunk = handle:read(512)
  handle:close()
  if not chunk then
    return true
  end
  return chunk:find '\0' ~= nil
end

--- Parse .gitignore patterns from a file into a list
local function parse_gitignore(gitignore_path)
  local patterns = {}
  local ok, lines = pcall(vim.fn.readfile, gitignore_path)
  if not ok or not lines then
    return patterns
  end
  for _, line in ipairs(lines) do
    line = vim.trim(line)
    if line ~= '' and not line:match '^#' then
      line = line:gsub('/$', '')
      table.insert(patterns, line)
    end
  end
  return patterns
end

--- Check if a path matches any gitignore-style pattern
local function matches_gitignore(filepath, patterns)
  for _, pattern in ipairs(patterns) do
    if filepath:find(pattern, 1, true) then
      return true
    end
    local lua_pattern = pattern:gsub('%.', '%%.'):gsub('%*', '.*'):gsub('%?', '.')
    if filepath:match(lua_pattern) then
      return true
    end
  end
  return false
end

-- ─── Argument Parser ──────────────────────────────────────────────────────────

local function parse_args(fargs)
  local opts = {
    recursive = false,
    matches = {},
    dir_matches = {},
    excludes = {},
    extensions = {},
    max_files = 100,
    respect_gitignore = true,
  }

  local function expand_braces(value)
    local brace = value:match '^%{(.+)%}$'
    if brace then
      return vim.split(brace, ',', { trimempty = true })
    end
    return { value }
  end

  for _, arg in ipairs(fargs) do
    if arg == '-r' or arg == '--recursive' then
      opts.recursive = true
    elseif arg == '--no-gitignore' then
      opts.respect_gitignore = false
    else
      local key, value = arg:match '^%-%-([%w_][%w_-]*)=(.+)$'
      if key and value then
        if key == 'match' then
          for _, v in ipairs(expand_braces(value)) do
            table.insert(opts.matches, vim.trim(v))
          end
        elseif key == 'dir_match' then
          for _, v in ipairs(expand_braces(value)) do
            table.insert(opts.dir_matches, vim.trim(v))
          end
        elseif key == 'exclude' then
          for _, v in ipairs(expand_braces(value)) do
            table.insert(opts.excludes, vim.trim(v))
          end
        elseif key == 'ext' then
          for _, v in ipairs(expand_braces(value)) do
            local ext = vim.trim(v):gsub('^%.', '')
            table.insert(opts.extensions, ext)
          end
        elseif key == 'max' then
          opts.max_files = tonumber(value) or 100
        else
          vim.notify('Copy: unknown option --' .. key, vim.log.levels.WARN)
        end
      elseif arg:match '^%-' then
        vim.notify('Copy: unknown argument ' .. arg, vim.log.levels.WARN)
      end
    end
  end

  if #opts.dir_matches > 0 then
    opts.recursive = true
  end

  return opts
end

-- ─── File Discovery ───────────────────────────────────────────────────────────

local function discover_git(dir, recursive)
  local git_root = get_git_root(dir)
  if not git_root then
    return nil
  end

  local cmd = { 'git', '-C', git_root, 'ls-files', '--full-name', '--cached', '--others', '--exclude-standard' }
  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end

  local dir_normalized = dir:gsub('/$', '') .. '/'
  local git_root_normalized = git_root:gsub('/$', '') .. '/'
  local files = {}

  for _, rel_path in ipairs(output) do
    if rel_path ~= '' then
      local abs_path = git_root_normalized .. rel_path
      if abs_path:sub(1, #dir_normalized) == dir_normalized then
        local remainder = abs_path:sub(#dir_normalized + 1)
        if recursive or not remainder:find '/' then
          table.insert(files, abs_path)
        end
      end
    end
  end

  return files
end

local function discover_fd(dir, recursive, respect_gitignore)
  if vim.fn.executable 'fd' ~= 1 then
    return nil
  end

  local cmd = { 'fd', '--type', 'f', '--absolute-path' }
  if not recursive then
    table.insert(cmd, '--max-depth')
    table.insert(cmd, '1')
  end
  if not respect_gitignore then
    table.insert(cmd, '--no-ignore')
  end
  table.insert(cmd, '.')
  table.insert(cmd, dir)

  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return nil
  end

  return vim.tbl_filter(function(line)
    return line ~= ''
  end, output)
end

local function discover_find(dir, recursive, respect_gitignore)
  local cmd = { 'find', dir }
  if not recursive then
    table.insert(cmd, '-maxdepth')
    table.insert(cmd, '1')
  end
  table.insert(cmd, '-type')
  table.insert(cmd, 'f')

  local output = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end

  local files = vim.tbl_filter(function(line)
    return line ~= ''
  end, output)

  if respect_gitignore then
    local gitignore_path
    local git_root = get_git_root(dir)
    if git_root then
      gitignore_path = git_root .. '/.gitignore'
    else
      gitignore_path = dir .. '/.gitignore'
    end

    local patterns = parse_gitignore(gitignore_path)
    if #patterns > 0 then
      files = vim.tbl_filter(function(filepath)
        return not matches_gitignore(filepath, patterns)
      end, files)
    end
  end

  return files
end

local function discover_files(dir, opts)
  local files

  if opts.respect_gitignore then
    files = discover_git(dir, opts.recursive)
    if files then
      return files
    end
  end

  files = discover_fd(dir, opts.recursive, opts.respect_gitignore)
  if files then
    return files
  end

  return discover_find(dir, opts.recursive, opts.respect_gitignore)
end

-- ─── Filtering ────────────────────────────────────────────────────────────────

local function get_path_dirs(filepath)
  local dir_part = filepath:match '^(.+)/[^/]+$'
  if not dir_part then
    return {}
  end
  return vim.split(dir_part, '/', { trimempty = true })
end

local function apply_filters(files, opts)
  return vim.tbl_filter(function(filepath)
    local lower_path = filepath:lower()

    for _, pattern in ipairs(opts.excludes) do
      if lower_path:find(pattern:lower(), 1, true) then
        return false
      end
    end

    for _, pattern in ipairs(opts.matches) do
      if not lower_path:find(pattern:lower(), 1, true) then
        return false
      end
    end

    if #opts.dir_matches > 0 then
      local dirs = get_path_dirs(lower_path)
      local any_dir_matched = false
      for _, pattern in ipairs(opts.dir_matches) do
        local p = pattern:lower()
        for _, dir_name in ipairs(dirs) do
          if dir_name:find(p, 1, true) then
            any_dir_matched = true
            break
          end
        end
        if any_dir_matched then
          break
        end
      end
      if not any_dir_matched then
        return false
      end
    end

    if #opts.extensions > 0 then
      local ext = filepath:match '%.([^%.]+)$'
      if not ext then
        return false
      end
      ext = ext:lower()
      local found = false
      for _, allowed in ipairs(opts.extensions) do
        if ext == allowed:lower() then
          found = true
          break
        end
      end
      if not found then
        return false
      end
    end

    return true
  end, files)
end

-- ─── Output Builder ───────────────────────────────────────────────────────────

local function build_output(files)
  local parts = {}
  local total_size = 0

  for _, file in ipairs(files) do
    local ok, lines = pcall(vim.fn.readfile, file)
    if ok and lines then
      local content = table.concat(lines, '\n')
      total_size = total_size + #content
      table.insert(parts, ('--- Start of %s ---'):format(file))
      table.insert(parts, content)
      table.insert(parts, ('--- End of %s ---\n'):format(file))
    end
  end

  return table.concat(parts, '\n'), total_size
end

local function format_size(bytes)
  if bytes < 1024 then
    return bytes .. 'B'
  elseif bytes < 1024 * 1024 then
    return string.format('%.1fKB', bytes / 1024)
  else
    return string.format('%.1fMB', bytes / (1024 * 1024))
  end
end

-- ─── Core: Normal Buffer Range ────────────────────────────────────────────────

local function copy_buffer_range(line1, line2)
  local filepath = vim.fn.expand '%:p'
  local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)
  local content = table.concat(lines, '\n')

  local output = string.format('--- Start of %s (lines %d-%d) ---\n%s\n--- End of %s ---\n', filepath, line1, line2, content, filepath)

  vim.fn.setreg('+', output)
  vim.notify(string.format('Copied %d lines from %s', line2 - line1 + 1, vim.fn.fnamemodify(filepath, ':t')), vim.log.levels.INFO)
end

-- ─── Core: Directory Copy ─────────────────────────────────────────────────────

local function copy_directory_contents(opts)
  local dir = get_current_dir()
  if dir == '' or vim.fn.isdirectory(dir) == 0 then
    vim.notify('Not in a valid directory', vim.log.levels.ERROR)
    return
  end

  local files = discover_files(dir, opts)
  files = apply_filters(files, opts)

  files = vim.tbl_filter(function(filepath)
    return not is_binary(filepath)
  end, files)

  table.sort(files)

  if #files > opts.max_files then
    vim.notify(string.format('Found %d files, limiting to %d. Use --max=%d to increase.', #files, opts.max_files, #files), vim.log.levels.WARN)
    local limited = {}
    for i = 1, opts.max_files do
      limited[i] = files[i]
    end
    files = limited
  end

  if #files == 0 then
    vim.notify('No files found', vim.log.levels.INFO)
    return
  end

  local output, total_size = build_output(files)
  vim.fn.setreg('+', output)
  vim.notify(string.format('Copied %d files (%s) %s', #files, format_size(total_size), opts.recursive and '(recursive)' or ''), vim.log.levels.INFO)
end

-- ─── Core: Oil Selection Copy ─────────────────────────────────────────────────

local function copy_oil_selection(files, opts)
  files = apply_filters(files, opts)

  files = vim.tbl_filter(function(filepath)
    return not is_binary(filepath)
  end, files)

  if #files == 0 then
    vim.notify('No matching files in selection', vim.log.levels.INFO)
    return
  end

  table.sort(files)

  local output, total_size = build_output(files)
  vim.fn.setreg('+', output)
  vim.notify(string.format('Copied %d selected files (%s)', #files, format_size(total_size)), vim.log.levels.INFO)
end

-- ─── Command Registration ─────────────────────────────────────────────────────

function M.setup()
  vim.api.nvim_create_user_command('Copy', function(cmd_opts)
    local opts = parse_args(cmd_opts.fargs)
    local has_range = cmd_opts.range == 2

    if has_range then
      if is_oil_buffer() then
        -- Visual selection in Oil → copy selected files' contents
        local selected = get_oil_selected_files(cmd_opts.line1, cmd_opts.line2)
        if selected then
          copy_oil_selection(selected, opts)
        else
          vim.notify('No files selected in Oil buffer', vim.log.levels.WARN)
        end
      else
        -- Visual selection in normal buffer → copy selected lines
        copy_buffer_range(cmd_opts.line1, cmd_opts.line2)
      end
    else
      -- No range → directory copy (original behavior)
      copy_directory_contents(opts)
    end
  end, {
    nargs = '*',
    range = true,
    complete = function(_, line)
      local suggestions = {
        '-r',
        '--recursive',
        '--match=',
        '--dir_match=',
        '--exclude=',
        '--ext=',
        '--max=',
        '--no-gitignore',
      }
      local lead = line:match '%S+$' or ''
      return vim.tbl_filter(function(s)
        return s:find(lead, 1, true) == 1
      end, suggestions)
    end,
    desc = 'Copy file contents to clipboard (supports visual selection in Oil)',
  })
end

return M
