-- usage.lua -- count which mappings actually get pressed.
--
-- The June 2026 cleanup (37fa6ce) deleted ~40 mappings on judgement, and the
-- help files kept describing them for four months because nothing measured
-- either side. This is the measurement. It answers one question -- "which of
-- the mappings I defined do I never press" -- so the next cleanup can be a
-- deletion of zeros rather than a guess.
--
-- How it counts:
--   vim.on_key sees every key as typed, BEFORE nvim resolves it. A rolling
--   buffer of the last few typed keys is compared, as a suffix, against the
--   termcode form of every mapping's lhs in the current mode. The longest
--   match counts once and clears the buffer. Only normal and visual modes are
--   watched: insert-mode keys are text, and operator-pending (`dL`) is a
--   motion, not a use of the `L` mapping.
--
-- Where it writes:
--   stdpath('state')/keymap-usage.json -- ~/.local/state/nvim on Linux. That
--   is OUTSIDE the work tree on purpose, the same property that keeps
--   ~/.bash_local out of git: nothing here can be committed by accident,
--   because git cannot see it. Do not move it under ~/.config/nvim, which is
--   a symlink into the repo.
--
-- What it costs: one string compare per mapping per keypress in normal mode,
-- against a list refreshed on BufEnter. Nothing on the insert path.
--
--   :KeymapUsage         every current mapping with its count and last use,
--                        zeros first -- those are the deletion candidates
--   :KeymapUsage reset   delete the file and start over
--
-- User commands are counted too, from CmdlineLeave: the first word of a
-- `:` line that names a command this config or a plugin defined. Trouble and
-- undotree have no mapping at all, so without this the two plugins most
-- likely to be pruned would read as unmeasured rather than as zeros.
--
-- The shell half is tools/usage.sh, which reads ~/.bash_history the same way.

local M = {}

local STATE = vim.fs.joinpath(vim.fn.stdpath 'state', 'keymap-usage.json')
local MODES = { n = true, v = true, V = true, ['\22'] = true }
local FLUSH_EVERY = 25

local pending = {} -- key -> delta since last flush
local pending_n = 0
local recent = '' -- rolling buffer of typed keys, termcode form
local maps = {} -- { { mode=, lhs=, raw= } ... } for the current buffer

local function read_file()
  local fh = io.open(STATE, 'r')
  if not fh then
    return {}
  end
  local text = fh:read '*a'
  fh:close()
  local ok, data = pcall(vim.json.decode, text)
  return (ok and type(data) == 'table') and data or {}
end

local function write_file(data)
  vim.fn.mkdir(vim.fn.fnamemodify(STATE, ':h'), 'p')
  local fh = io.open(STATE, 'w')
  if not fh then
    return
  end
  fh:write(vim.json.encode(data))
  fh:close()
end

-- Merge pending deltas into the file rather than overwriting it, so two nvim
-- instances do not take turns erasing each other's counts.
local function flush()
  if pending_n == 0 then
    return
  end
  local data = read_file()
  local today = os.date '%Y-%m-%d'
  for key, delta in pairs(pending) do
    local row = data[key] or { count = 0 }
    row.count = row.count + delta
    row.last = today
    data[key] = row
  end
  write_file(data)
  pending = {}
  pending_n = 0
end

local function key_of(mode, lhs)
  return mode .. ' ' .. lhs
end

-- Mode letters as nvim_get_keymap wants them. Visual-block reports as \22 but
-- maps live under 'v' or 'x'; 'v' covers both for lookup.
local function map_mode(mode)
  if mode == 'n' then
    return 'n'
  end
  return 'v'
end

local function refresh_maps()
  maps = {}
  local seen = {}
  for _, mode in ipairs { 'n', 'v', 'x' } do
    local lists = { vim.api.nvim_buf_get_keymap(0, mode), vim.api.nvim_get_keymap(mode) }
    for _, list in ipairs(lists) do
      for _, m in ipairs(list) do
        -- 'v' and 'x' are one lane here: a mapping set for both would
        -- otherwise appear twice and split its own count.
        local lane = mode == 'x' and 'v' or mode
        local k = key_of(lane, m.lhs)
        if not seen[k] and m.lhs ~= '' then
          seen[k] = true
          local ok, raw = pcall(vim.api.nvim_replace_termcodes, m.lhs, true, true, true)
          if ok and raw ~= '' then
            table.insert(maps, { mode = lane, lhs = m.lhs, raw = raw })
          end
        end
      end
    end
  end
end

-- First word of a command line, past any range or count: `:'<,'>Trouble`,
-- `:3Render`, `:silent! Copy -r` all resolve to the bare name.
local function command_name(line)
  line = line:gsub("^[%s%d,%.%$%%'<>%-%+;/?]+", '')
  for _ = 1, 3 do
    local mod, rest = line:match '^(%a+)!?%s+(.*)$'
    if mod and (mod == 'silent' or mod == 'noautocmd' or mod == 'vertical' or mod == 'keepjumps') then
      line = rest
    else
      break
    end
  end
  return line:match '^(%u[%w]*)'
end

local function on_cmdline()
  if vim.v.event.abort or vim.fn.getcmdtype() ~= ':' then
    return
  end
  local name = command_name(vim.fn.getcmdline())
  if not name then
    return
  end
  if vim.api.nvim_get_commands({})[name] or vim.api.nvim_buf_get_commands(0, {})[name] then
    local k = 'cmd :' .. name
    pending[k] = (pending[k] or 0) + 1
    pending_n = pending_n + 1
  end
end

local function on_key(_, typed)
  if typed == nil or typed == '' then
    return
  end
  local mode = vim.api.nvim_get_mode().mode
  if not MODES[mode:sub(1, 1)] or mode:sub(2, 2) == 'o' then
    recent = ''
    return
  end
  recent = (recent .. typed):sub(-32)
  local want = map_mode(mode:sub(1, 1))
  local best
  for _, m in ipairs(maps) do
    if m.mode == want and #m.raw <= #recent and recent:sub(-#m.raw) == m.raw then
      if not best or #m.raw > #best.raw then
        best = m
      end
    end
  end
  if best then
    local k = key_of(best.mode, best.lhs)
    pending[k] = (pending[k] or 0) + 1
    pending_n = pending_n + 1
    recent = ''
    if pending_n >= FLUSH_EVERY then
      flush()
    end
  end
end

local function report(args)
  if args.fargs[1] == 'reset' then
    pending, pending_n = {}, 0
    os.remove(STATE)
    vim.notify('keymap usage reset: ' .. STATE, vim.log.levels.INFO, { title = 'usage' })
    return
  end
  flush()
  local data = read_file()
  refresh_maps()
  local rows = {}
  for _, m in ipairs(maps) do
    local row = data[key_of(m.mode, m.lhs)] or { count = 0, last = '-' }
    table.insert(rows, { mode = m.mode, lhs = vim.fn.keytrans(m.raw), count = row.count, last = row.last or '-' })
  end
  for name, _ in pairs(vim.api.nvim_get_commands {}) do
    local row = data['cmd :' .. name] or { count = 0, last = '-' }
    table.insert(rows, { mode = 'cmd', lhs = ':' .. name, count = row.count, last = row.last or '-' })
  end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then
      return a.count < b.count
    end
    return a.lhs < b.lhs
  end)
  local out = { string.format('%-5s %-24s %6s  %s', 'mode', 'lhs / :command', 'count', 'last'), string.rep('-', 50) }
  for _, r in ipairs(rows) do
    table.insert(out, string.format('%-5s %-24s %6d  %s', r.mode, r.lhs, r.count, r.last))
  end
  table.insert(out, '')
  table.insert(out, 'zeros first: those are the mappings and commands nothing has used since ' .. STATE .. ' was created')
  vim.cmd 'new'
  vim.bo.buftype = 'nofile'
  vim.bo.bufhidden = 'wipe'
  vim.bo.swapfile = false
  vim.api.nvim_buf_set_lines(0, 0, -1, false, out)
  vim.bo.modifiable = false
  vim.api.nvim_buf_set_name(0, 'KeymapUsage')
end

-- Exposed so a scripted session (CI, a smoke test) can populate the mapping
-- list without waiting for the scheduled BufEnter refresh.
M.refresh = refresh_maps

function M.setup()
  local group = vim.api.nvim_create_augroup('dotfiles-usage', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'LspAttach' }, {
    group = group,
    callback = function()
      vim.schedule(refresh_maps)
    end,
  })
  vim.api.nvim_create_autocmd('CmdlineLeave', { group = group, callback = on_cmdline })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = flush })
  vim.schedule(refresh_maps)
  vim.on_key(on_key, vim.api.nvim_create_namespace 'dotfiles-usage')
  vim.api.nvim_create_user_command('KeymapUsage', report, {
    nargs = '?',
    complete = function()
      return { 'reset' }
    end,
    desc = 'Show how often each mapping has been pressed (zeros first)',
  })
end

return M
