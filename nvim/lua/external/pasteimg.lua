-- ~/.config/nvim/lua/external/pasteimg.lua
--
-- :PasteImage — drop an image from the OS clipboard into a directory as a PNG.
--
-- The "screenshot → snip → paste into Oil" workflow: take a screenshot
-- (GNOME's Print Screen, …) so it lands on the OS
-- clipboard, open Oil at the target directory, then `:PasteImage`. The new file
-- is written to disk and Oil refreshes to show it.
--
-- Target directory:
--   • In an Oil buffer → the directory Oil is currently showing
--   • Otherwise        → the current file's directory, else the cwd
--
-- Filename:
--   :PasteImage                       Screenshot-YYYYMMDD-HHMMSS.png
--   :PasteImage --rename diagram.png  diagram.png  (.png appended if no ext)
--   :PasteImage --rename diagram      diagram.png
--
-- Backend is detected at runtime from the session:
--   • Linux / Wayland → wl-paste   (package: wl-clipboard)
--   • Linux / X11     → xclip      (package: xclip)
--
-- See lua/external/reqs.lua, deps.sh, and `:checkhealth external` for the
-- per-platform tool. Documented in `:help :PasteImage`.

local M = {}

local TITLE = 'PasteImage'

local function err(msg)
  vim.notify(TITLE .. ': ' .. msg, vim.log.levels.ERROR, { title = TITLE })
end

local function format_size(bytes)
  if bytes < 1024 then
    return bytes .. 'B'
  elseif bytes < 1024 * 1024 then
    return string.format('%.1fKB', bytes / 1024)
  end
  return string.format('%.1fMB', bytes / (1024 * 1024))
end

-- ─── Backend detection ─────────────────────────────────────────────────────

local function detect_backend()
  if vim.env.WAYLAND_DISPLAY then
    return 'wayland'
  end
  if vim.env.DISPLAY then
    return 'x11'
  end
  return nil
end

-- ─── Backends ──────────────────────────────────────────────────────────────
-- Each saver writes a PNG to `out_path` and returns
-- (true) on success or (false, message) on failure. "No image on the
-- clipboard" is a failure, not a crash.

local function save_wayland(out_path)
  if vim.fn.executable 'wl-paste' ~= 1 then
    return false, 'wl-paste not found — install wl-clipboard'
  end
  if not vim.fn.system({ 'wl-paste', '--list-types' }):find 'image/' then
    return false, 'no image on the clipboard'
  end
  vim.fn.system('wl-paste --type image/png > ' .. vim.fn.shellescape(out_path))
  if vim.v.shell_error ~= 0 then
    return false, 'wl-paste failed'
  end
  return true
end

local function save_x11(out_path)
  if vim.fn.executable 'xclip' ~= 1 then
    return false, 'xclip not found — install xclip'
  end
  if not vim.fn.system({ 'xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o' }):find 'image/png' then
    return false, 'no image on the clipboard'
  end
  vim.fn.system('xclip -selection clipboard -t image/png -o > ' .. vim.fn.shellescape(out_path))
  if vim.v.shell_error ~= 0 then
    return false, 'xclip failed'
  end
  return true
end

local SAVERS = {
  wayland = save_wayland,
  x11 = save_x11,
}

-- ─── Target directory & filename ─────────────────────────────────────────────

local function target_dir()
  local bufname = vim.api.nvim_buf_get_name(0)
  if vim.bo.filetype == 'oil' or bufname:match '^oil://' then
    local ok, oil = pcall(require, 'oil')
    if ok then
      local dir = oil.get_current_dir(0)
      if dir then
        return dir:gsub('/+$', '') .. '/'
      end
    end
  end
  local file = vim.fn.expand '%:p'
  if file ~= '' and vim.fn.filereadable(file) == 1 then
    return vim.fn.fnamemodify(file, ':p:h'):gsub('/+$', '') .. '/'
  end
  return vim.fn.getcwd():gsub('/+$', '') .. '/'
end

--- Pull a name out of `--rename <name>` or `--rename=<name>` (also --name).
local function parse_name(fargs)
  for i, a in ipairs(fargs) do
    local v = a:match '^%-%-rename=(.+)$' or a:match '^%-%-name=(.+)$'
    if v then
      return v
    end
    if (a == '--rename' or a == '--name') and fargs[i + 1] then
      return fargs[i + 1]
    end
  end
  return nil
end

-- ─── Oil refresh ─────────────────────────────────────────────────────────────

-- The file is written to disk outside Oil's buffer, so Oil won't show it until
-- it re-reads. Only auto-refresh when the buffer has no pending edits — a forced
-- refresh would silently discard them.
local function refresh_oil()
  if vim.bo.filetype ~= 'oil' then
    return
  end
  if vim.bo.modified then
    vim.notify(TITLE .. ': Oil has unsaved edits — refresh manually (C-l) to see the file', vim.log.levels.WARN, { title = TITLE })
    return
  end
  pcall(function()
    require('oil.actions').refresh.callback { force = true }
  end)
end

-- ─── Command ─────────────────────────────────────────────────────────────────

local function paste(fargs)
  local backend = detect_backend()
  if not backend then
    err 'no clipboard-image backend for this environment (need Wayland or X11)'
    return
  end

  local dir = target_dir()
  if vim.fn.isdirectory(dir) == 0 then
    err('not a valid directory: ' .. dir)
    return
  end

  local name = parse_name(fargs) or os.date 'Screenshot-%Y%m%d-%H%M%S.png'
  if not name:match '%.%w+$' then
    name = name .. '.png'
  end

  local out_path = dir .. name
  if vim.fn.filereadable(out_path) == 1 then
    err('file already exists: ' .. name)
    return
  end

  local ok, message = SAVERS[backend](out_path)

  -- A failed redirect can leave a zero-byte file behind; clean it up.
  if (not ok) or vim.fn.getfsize(out_path) <= 0 then
    if vim.fn.getfsize(out_path) <= 0 then
      pcall(os.remove, out_path)
    end
    err(message or 'no image on the clipboard')
    return
  end

  vim.notify(('Pasted %s (%s)'):format(name, format_size(vim.fn.getfsize(out_path))), vim.log.levels.INFO, { title = TITLE })
  refresh_oil()
end

function M.setup()
  vim.api.nvim_create_user_command('PasteImage', function(o)
    paste(o.fargs)
  end, {
    nargs = '*',
    complete = function(lead)
      return vim.tbl_filter(function(s)
        return s:find(lead, 1, true) == 1
      end, { '--rename' })
    end,
    desc = 'Paste an image from the OS clipboard into the current dir as PNG (Oil-aware)',
  })
end

return M
