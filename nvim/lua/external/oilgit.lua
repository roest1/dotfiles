-- Oil git diffstat
-- Floats each file's git diff (+added / -deleted lines) at the window's right
-- edge while browsing a repo in oil, mirroring the git section of the bash PS1.
--
-- Counts are the total change vs the last commit (`git diff HEAD`, i.e. staged
-- + unstaged combined). Untracked files show `+N` for their line count.
-- Palette matches PS1 (Ayu xterm-256: +green 150, -red 203).
--
-- Toggle with `:OilGit`. See `:help roest-plugins` (oil section).

local M = {}

local ns = vim.api.nvim_create_namespace 'oil_git_diffstat'
local enabled = true

-- Highlight groups matching the PS1 Ayu palette (xterm-256 150/203 -> hex).
-- default = true so a colorscheme/user can override; re-applied on ColorScheme.
local function set_highlights()
  vim.api.nvim_set_hl(0, 'OilGitAdded', { fg = '#afd787', ctermfg = 150, default = true })
  vim.api.nvim_set_hl(0, 'OilGitDeleted', { fg = '#ff5f5f', ctermfg = 203, default = true })
end

-- Count lines in an untracked file (for its `+N`). Synchronous libuv reads,
-- safe in a vim.system callback. Skips empty/oversized files.
local function count_lines(path)
  local fd = vim.uv.fs_open(path, 'r', 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  if not stat or stat.size == 0 or stat.size > 1024 * 1024 then
    vim.uv.fs_close(fd)
    return nil
  end
  local data = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not data then
    return nil
  end
  local n = 0
  for _ in data:gmatch '\n' do
    n = n + 1
  end
  if #data > 0 and data:sub(-1) ~= '\n' then
    n = n + 1
  end
  return n
end

-- Overlay `map` (entry name -> {added, deleted}) onto the oil buffer.
-- Setting extmarks does not re-render the buffer, so this can't loop OilEnter.
local function apply(bufnr, map)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not enabled then
    return
  end
  local ok, oil = pcall(require, 'oil')
  if not ok then
    return
  end
  for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
    local entry = oil.get_entry_on_line(bufnr, lnum)
    if entry and entry.name and entry.type ~= 'directory' then
      local info = map[entry.name]
      if info then
        local chunks = {}
        if info.added and info.added > 0 then
          chunks[#chunks + 1] = { '+' .. info.added, 'OilGitAdded' }
        end
        if info.deleted and info.deleted > 0 then
          if #chunks > 0 then
            chunks[#chunks + 1] = { ' ', 'OilGitDeleted' }
          end
          chunks[#chunks + 1] = { '-' .. info.deleted, 'OilGitDeleted' }
        end
        if #chunks > 0 then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, {
            virt_text = chunks,
            virt_text_pos = 'right_align',
            hl_mode = 'combine',
            priority = 20,
          })
        end
      end
    end
  end
end

-- Fetch tracked changes (vs HEAD) and untracked files concurrently, then apply.
-- `--relative` scopes output to `dir` and makes direct children path-free of '/'.
local function fetch_and_apply(bufnr, dir)
  local map = {}
  local pending = 2
  local function done()
    pending = pending - 1
    if pending == 0 then
      vim.schedule(function()
        apply(bufnr, map)
      end)
    end
  end

  -- Tracked changes vs HEAD (staged + unstaged combined).
  vim.system({ 'git', '-C', dir, 'diff', 'HEAD', '--numstat', '--no-renames', '--relative', '-z' }, { text = true }, function(res)
    if res.code == 0 and res.stdout then
      for _, rec in ipairs(vim.split(res.stdout, '\0', { plain = true, trimempty = true })) do
        local a, d, p = rec:match '^([%-%d]+)\t([%-%d]+)\t(.+)$'
        -- direct children only; skip binary files (numstat reports '-')
        if p and a ~= '-' and not p:find '/' then
          map[p] = { added = tonumber(a) or 0, deleted = tonumber(d) or 0 }
        end
      end
    end
    done()
  end)

  -- Untracked direct children -> +N line count.
  vim.system({ 'git', '-C', dir, 'ls-files', '--others', '--exclude-standard', '-z' }, { text = true }, function(res)
    if res.code == 0 and res.stdout then
      for _, p in ipairs(vim.split(res.stdout, '\0', { plain = true, trimempty = true })) do
        if not p:find '/' then
          local n = count_lines(dir .. p)
          if n and n > 0 then
            map[p] = { added = n }
          end
        end
      end
    end
    done()
  end)
end

-- Refresh a single oil buffer: resolve its directory, confirm it's a git repo,
-- then fetch + overlay. No-ops cleanly for non-repos and non-file adapters.
local function refresh(bufnr)
  if not enabled or not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= 'oil' then
    return
  end
  local ok, oil = pcall(require, 'oil')
  if not ok then
    return
  end
  local dir = oil.get_current_dir(bufnr)
  if not dir then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    return
  end
  dir = dir:gsub('/+$', '') .. '/'

  vim.system({ 'git', '-C', dir, 'rev-parse', '--is-inside-work-tree' }, { text = true }, function(res)
    if res.code ~= 0 or vim.trim(res.stdout or '') ~= 'true' then
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        end
      end)
      return
    end
    fetch_and_apply(bufnr, dir)
  end)
end

local function each_oil_buf(fn)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'oil' then
      fn(bufnr)
    end
  end
end

function M.setup()
  set_highlights()
  local group = vim.api.nvim_create_augroup('OilGitDiffstat', { clear = true })

  vim.api.nvim_create_autocmd('ColorScheme', { group = group, callback = set_highlights })

  -- Fires after each directory finishes rendering (covers floats too).
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'OilEnter',
    callback = function(ev)
      local bufnr = ev.data and ev.data.buf
      if bufnr then
        refresh(bufnr)
      end
    end,
  })

  -- Fires after file create/delete/move, which can change counts.
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'OilActionsPost',
    callback = function()
      vim.schedule(function()
        each_oil_buf(refresh)
      end)
    end,
  })

  vim.api.nvim_create_user_command('OilGit', function()
    enabled = not enabled
    if enabled then
      each_oil_buf(refresh)
    else
      each_oil_buf(function(bufnr)
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end)
    end
    vim.notify('oil git diffstat ' .. (enabled and 'enabled' or 'disabled'), vim.log.levels.INFO, { title = 'oil' })
  end, { desc = 'Toggle oil git diffstat overlay' })
end

return M
