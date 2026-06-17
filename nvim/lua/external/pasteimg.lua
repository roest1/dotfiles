-- ~/.config/nvim/lua/external/pasteimg.lua
--
-- :PasteImage — drop an image from the OS clipboard into a directory as a PNG.
--
-- The "screenshot → snip → paste into Oil" workflow: take a screenshot
-- (Win+Shift+S, macOS Cmd+Shift+4, a Linux snipper, …) so it lands on the OS
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
-- Backend is detected at runtime (mirrors the clipboard provider in
-- options.lua) so one config works on every machine:
--   • WSL2            → PowerShell -STA + System.Windows.Forms.Clipboard
--                       (no extra install — ships with Windows)
--   • Linux / Wayland → wl-paste   (package: wl-clipboard)
--   • Linux / X11     → xclip      (package: xclip)
--   • macOS           → pngpaste (brew), else an osascript fallback
--
-- See lua/external/reqs.lua, bootstrap.sh, and `:checkhealth external` for the
-- per-platform tool. Documented in `:help roest-plugins-oil`.

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
  if vim.fn.has 'wsl' == 1 then
    return 'wsl'
  end
  if vim.fn.has 'mac' == 1 then
    return 'macos'
  end
  if vim.env.WAYLAND_DISPLAY then
    return 'wayland'
  end
  if vim.env.DISPLAY then
    return 'x11'
  end
  return nil
end

-- ─── Backends ──────────────────────────────────────────────────────────────
-- Each saver writes a PNG to `out_path` (a Linux/macOS path) and returns
-- (true) on success or (false, message) on failure. "No image on the
-- clipboard" is a failure, not a crash.

--- Resolve powershell.exe: PATH first, then the canonical System32 location.
local function find_powershell()
  local ps = vim.fn.exepath 'powershell.exe'
  if ps ~= '' then
    return ps
  end
  local fallback = '/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
  if vim.fn.executable(fallback) == 1 then
    return fallback
  end
  return nil
end

local function save_wsl(out_path)
  local ps = find_powershell()
  if not ps then
    return false, 'powershell.exe not found on PATH or in System32'
  end

  -- .NET writes through the Windows side, so it needs a Windows path.
  local win_path = vim.trim(vim.fn.system { 'wslpath', '-w', out_path })
  if vim.v.shell_error ~= 0 or win_path == '' then
    return false, 'wslpath could not convert ' .. out_path
  end

  -- -STA is required: WinForms clipboard access needs a single-threaded
  -- apartment (the default MTA throws). Single-quote the path for PowerShell,
  -- doubling embedded quotes; backslashes are literal in single quotes.
  local quoted = "'" .. win_path:gsub("'", "''") .. "'"
  local script = table.concat({
    'Add-Type -AssemblyName System.Windows.Forms;',
    'Add-Type -AssemblyName System.Drawing;',
    '$img = [System.Windows.Forms.Clipboard]::GetImage();',
    "if ($img -eq $null) { 'NO_IMAGE'; exit 0 };",
    ('$img.Save(%s, [System.Drawing.Imaging.ImageFormat]::Png); '):format(quoted),
    "'SAVED'",
  }, ' ')

  -- List form → no shell, so no quoting surprises on the WSL side.
  local out = vim.fn.system { ps, '-NoProfile', '-STA', '-Command', script }
  if vim.v.shell_error ~= 0 then
    return false, 'powershell error: ' .. vim.trim(out)
  end
  if out:find 'NO_IMAGE' then
    return false, 'no image on the clipboard'
  end
  return true
end

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

local function save_macos(out_path)
  if vim.fn.executable 'pngpaste' == 1 then
    vim.fn.system { 'pngpaste', out_path }
    if vim.v.shell_error == 0 then
      return true
    end
    return false, 'no image on the clipboard'
  end
  -- Fallback: AppleScript dumps the clipboard PNG to the file. pngpaste is
  -- more reliable; recommend it in the failure message.
  local script = table.concat({
    ('set f to (POSIX file "%s")'):format(out_path:gsub('"', '\\"')),
    'try',
    '  set png to (the clipboard as «class PNGf»)',
    'on error',
    '  return "NO_IMAGE"',
    'end try',
    'set fh to open for access f with write permission',
    'set eof fh to 0',
    'write png to fh',
    'close access fh',
    'return "SAVED"',
  }, '\n')
  local out = vim.fn.system { 'osascript', '-e', script }
  if vim.v.shell_error ~= 0 or out:find 'NO_IMAGE' then
    return false, 'no image on the clipboard (install pngpaste for reliability)'
  end
  return true
end

local SAVERS = {
  wsl = save_wsl,
  wayland = save_wayland,
  x11 = save_x11,
  macos = save_macos,
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
    err 'no clipboard-image backend for this environment (need WSL, macOS, Wayland, or X11)'
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
