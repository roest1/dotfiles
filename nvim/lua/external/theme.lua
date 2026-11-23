-- Colorscheme lanes, the same two nvim lanes `font` has:
--
--   nvim.ui      everything that is not a file: oil, telescope, floats, the
--                gutter and statusline -- the global highlight namespace
--   nvim.editor  windows showing a file you write (external/filebuf.lua),
--                through a per-window highlight namespace
--
-- The repo default is rose-pine-moon, transparent, in both lanes. A machine
-- overrides it in ~/.config/dotfiles/theme.conf -- NOT under ~/.config/nvim,
-- which is a symlink into the work tree, so a pick saved there would become a
-- diff. Outside the tree, git cannot see it and a pull cannot touch it: same
-- footing as ~/.config/dotfiles/sections, ~/.config/wezterm/fonts.conf and
-- ~/.bash_local.
--
--   nvim.ui                  = rose-pine-moon
--   nvim.ui.transparent      = true
--   nvim.editor              = onedark
--   nvim.editor.transparent  = false
--
-- An editor key left out follows the ui lane, so one line moves both.
-- Same reader discipline as fonts.conf in wezterm/wezterm.lua: a mangled line
-- or unknown key is skipped rather than failing startup, because a theme TUI
-- will be writing this file and the two sides can be out of step.
--
-- ─── Why a namespace, and why the gutter is not the editor's ──────────────
--
-- Neovim has one colorscheme, but nvim_win_set_hl_ns gives a window its own
-- highlight namespace that falls back to the global one for any group it does
-- not define. So the editor scheme is loaded, every group it set is copied
-- into EDITOR_NS, and the ui scheme is loaded last as the global one.
--
-- A namespace is per WINDOW, not per cell, and the gutter, line numbers and
-- statusline are drawn inside the editor window. Left alone they would take
-- the editor's colors, while altfont.lua leaves them in the ui font -- the two
-- lanes would draw the boundary in different places. CHROME is the groups NOT
-- copied, so they fall through to the ui scheme. That is a list of names,
-- which altfont.lua prides itself on not needing; it is affordable here
-- because these are Neovim's own built-in groups, a small set that does not
-- grow with LSP or treesitter the way content groups do.
local M = {}

local THEME_STATE = (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. '/.config')) .. '/dotfiles/theme.conf'

local DEFAULT = 'rose-pine-moon'
local KEYS = {
  ['nvim.ui'] = true,
  ['nvim.ui.transparent'] = true,
  ['nvim.editor'] = true,
  ['nvim.editor.transparent'] = true,
}

local EDITOR_NS = vim.api.nvim_create_namespace 'theme.editor'

local CHROME = {}
for _, g in ipairs {
  'LineNr',
  'LineNrAbove',
  'LineNrBelow',
  'CursorLineNr',
  'CursorLineSign',
  'CursorLineFold',
  'SignColumn',
  'FoldColumn',
  'StatusLine',
  'StatusLineNC',
  'StatusLineTerm',
  'StatusLineTermNC',
  'WinBar',
  'WinBarNC',
  'WinSeparator',
  'VertSplit',
} do
  CHROME[g] = true
end

local function is_chrome(name)
  if CHROME[name] or name:match '^DiagnosticSign' then
    return true
  end
  -- gitsigns' column glyphs are gutter; its Ln/Inline/Preview/Blame groups
  -- paint the text area and belong to the editor.
  if name:match '^GitSigns' then
    return not (name:match 'Ln' or name:match 'Inline' or name:match 'Preview' or name:match 'Blame')
  end
  return false
end

local function read()
  local set = {}
  local fh = io.open(THEME_STATE, 'r')
  if fh then
    for line in fh:lines() do
      local k, v = line:match '^%s*([%a_][%w_.]*)%s*=%s*(.-)%s*$'
      if k and v and v ~= '' and KEYS[k] then
        set[k] = v
      end
    end
    fh:close()
  end
  local ui = set['nvim.ui'] or DEFAULT
  local ui_t = (set['nvim.ui.transparent'] or 'true') ~= 'false'
  local ed = set['nvim.editor'] or ui
  local ed_t = set['nvim.editor.transparent']
  if ed_t == nil then
    ed_t = ui_t
  else
    ed_t = ed_t ~= 'false'
  end
  return { ui = ui, ui_t = ui_t, editor = ed, editor_t = ed_t }
end

-- Load one scheme into the global namespace. rose-pine paints its own
-- background unless told not to, so its option has to be set per load: with
-- two lanes it can be transparent in one and opaque in the other.
--
-- A pick naming a scheme a later pull removed must not leave the editor
-- unthemed: fall back to the repo default and say so. Returns what loaded.
local function load(color, transparent)
  local function apply(name)
    if name:match '^rose%-pine' then
      require('rose-pine').setup { disable_background = transparent }
    end
    return pcall(vim.cmd.colorscheme, name)
  end
  if not apply(color) then
    vim.notify(('theme.conf: colorscheme %q not found, using %s'):format(color, DEFAULT), vim.log.levels.WARN)
    color = DEFAULT
    apply(color)
  end
  if transparent then
    -- Clearing Normal alone is not transparency: a scheme paints its base
    -- color into other groups too -- EndOfBuffer past the last line, LineNr
    -- and SignColumn in the gutter -- and those stay as opaque bands. rose-pine
    -- hid this because its disable_background clears them itself; dracula
    -- and onedark do not, unless told through options of their own. So clear
    -- every group whose background IS the base, which needs no per-scheme
    -- knowledge. Only bg is touched: a group using the base as a foreground
    -- (dark text on a bright search match) keeps its contrast. Linked groups
    -- follow their target and are left alone.
    local base = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }).bg
    if base then
      for name, val in pairs(vim.api.nvim_get_hl(0, {})) do
        if not val.link and val.bg == base then
          val.bg, val.ctermbg = nil, nil
          vim.api.nvim_set_hl(0, name, val)
        end
      end
    end
    vim.api.nvim_set_hl(0, 'Normal', { bg = 'none' })
    vim.api.nvim_set_hl(0, 'NormalFloat', { bg = 'none' })
  end
  return color
end

local is_file_buf = require 'external.filebuf'
local split = false

local function assign(win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  -- Floats stay in the ui lane even over a file: hover, diagnostics and
  -- telescope's preview are UI, whatever buffer they happen to show.
  local float = vim.api.nvim_win_get_config(win).relative ~= ''
  local want = (split and not float and is_file_buf(vim.api.nvim_win_get_buf(win))) and EDITOR_NS or 0
  if vim.api.nvim_get_hl_ns { winid = win } ~= want then
    vim.api.nvim_win_set_hl_ns(win, want)
  end
end

local function assign_buf(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    assign(win)
  end
end

function M.setup()
  local t = read()

  if t.editor ~= t.ui or t.editor_t ~= t.ui_t then
    t.editor = load(t.editor, t.editor_t)
    for name in pairs(vim.api.nvim_get_hl(0, {})) do
      if not is_chrome(name) then
        -- Resolved, not copied as a link: a link inside EDITOR_NS would be
        -- looked up again at draw time, and the target may be a group the
        -- ui scheme redefines in between.
        local val = vim.api.nvim_get_hl(0, { name = name, link = false })
        if next(val) then
          vim.api.nvim_set_hl(EDITOR_NS, name, val)
        end
      end
    end
    split = true
  end
  t.ui = load(t.ui, t.ui_t)
  M.state = t

  if not split then
    return
  end
  local group = vim.api.nvim_create_augroup('theme.lanes', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinNew', 'BufFilePost' }, {
    group = group,
    callback = function(ev)
      assign_buf(ev.buf)
      assign(vim.api.nvim_get_current_win())
    end,
  })
  -- A plugin may set buftype after the buffer is already in a window.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    callback = function(ev)
      assign_buf(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('OptionSet', {
    group = group,
    pattern = 'buftype',
    callback = function()
      assign_buf(vim.api.nvim_get_current_buf())
    end,
  })
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    assign(win)
  end
end

-- A one-off try for the current session, ui lane only:
--   :lua ColorMyPencils('dracula')   transparent
-- Editor windows keep their lane when the lanes differ.
function ColorMyPencils(color, transparent)
  if transparent == nil then
    transparent = true
  end
  load(color or DEFAULT, transparent)
end

return M
