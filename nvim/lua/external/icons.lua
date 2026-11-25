-- Which set draws a file's icon in nvim: the `icons` key of theme.conf.
--
--   icons = material      Material Icon Theme, in color
--   (no key, or any other value: the Nerd Font glyphs nvim-web-devicons has)
--
-- Read by external/theme.lua with the rest of that file and handed to `apply`
-- here, at start and again whenever `theme` rewrites it: a pick reaches every
-- running nvim, the same as a colorscheme does.
--
-- ─── Nothing about the set is written down here ───────────────────────────
--
-- Which code point is which icon, and which file gets which, is read out of
-- material-icons.tsv, the table roest1/fonts builds beside the font and
-- wezterm links at ~/.config/wezterm/fonts. A code point only holds for one
-- upstream release, so a copy in this file would be wrong after the next one.
--
-- ─── Why get_icon is wrapped, and not overridden the documented way ───────
--
-- nvim-web-devicons has `override_by_filename` and `set_icon` for exactly
-- this. They only go one way. An override is merged into a table the plugin
-- keeps to itself and re-applies on every refresh, and nothing takes one back
-- out. Picking Material and then the default again would leave Material on
-- every name the default has no icon for, until nvim restarts.
--
-- So the one function oil and telescope both call is wrapped, once, and the
-- wrapper asks the table only while the pick says so. Switching back is that
-- flag going false: the plugin's own tables were never touched.
--
-- ─── The same guard as the font carrier (altfont.lua) ─────────────────────
--
-- These are private-use characters. Without the font they are empty boxes, and
-- the font is the TERMINAL's: over ssh from another terminal, in GNOME
-- Terminal, on a machine whose wezterm config is not this repo's, the pick is
-- left alone and the Nerd Font glyphs stay.
local M = {}

local FONTS = (vim.env.XDG_CONFIG_HOME or (vim.env.HOME .. '/.config')) .. '/wezterm/fonts'

-- wezterm.lua draws the icon font at 1.2 times the text's size, where an icon
-- covers its own cell and most of the next. Every caller already puts one
-- space after an icon; this is the second.
local GAP = ' '

-- A group with nothing in it. Callers highlight the icon with whatever
-- get_icon returns, and a color glyph takes no color: any real group here
-- would only paint its background over a selected line.
local HL = 'MaterialIcon'

-- The table, once read. false: looked for and not usable.
local material = nil
-- Why the pick is not in force, for :checkhealth and for the curious.
M.why = nil
-- What is drawing icons right now: 'material' or 'nerd'.
M.set = 'nerd'

-- material-icons.tsv as lookup tables. Three tab-separated columns: the kind
-- of row, a key, a value. See the header of mkicons.py in roest1/fonts.
function M.parse(lines)
  local t = { icon = {}, ext = {}, file = {}, folder = {}, default = {} }
  for _, line in ipairs(lines) do
    local kind, key, value = line:match '^(%l+)\t([^\t]+)\t([^\t]+)$'
    if kind == 'icon' then
      local cp = tonumber(value, 16)
      if cp then
        t.icon[key] = vim.fn.nr2char(cp, true)
      end
    elseif kind == 'file' or kind == 'folder' then
      -- The editor this comes from ignores case in a name.
      t[kind][key:lower()] = value
    elseif t[kind] then
      t[kind][key] = value
    end
  end
  return next(t.icon) and t or nil
end

-- The icon `name` gets: its whole name, then its extension, longest first
-- (`d.ts` before `ts`), then what anything gets. A folder is looked up by its
-- name alone.
function M.icon_for(t, name, is_dir)
  local lower = name:lower()
  local icon
  if is_dir then
    icon = t.folder[lower] or t.default.folder
  else
    icon = t.file[lower]
    local rest = lower
    while not icon do
      rest = rest:match '^[^.]*%.(.+)$'
      if not rest then
        break
      end
      icon = t.ext[rest]
    end
    icon = icon or t.default.file
  end
  return icon and t.icon[icon]
end

-- The table, if this terminal can draw what it names. Second value: why not.
local function available()
  if vim.env.TERM_PROGRAM ~= 'WezTerm' then
    return nil, 'TERM_PROGRAM is ' .. (vim.env.TERM_PROGRAM or '<unset>') .. ', not WezTerm'
  end
  if vim.fn.filereadable(FONTS .. '/MaterialIconTheme.ttf') ~= 1 then
    return nil, FONTS .. '/MaterialIconTheme.ttf is not there — update the fonts submodule, then `make link`'
  end
  if material == nil then
    local ok, lines = pcall(vim.fn.readfile, FONTS .. '/material-icons.tsv')
    material = ok and M.parse(lines) or false
  end
  if not material then
    return nil, FONTS .. '/material-icons.tsv lists no icons'
  end
  return material
end

local wrapped = false
local function wrap()
  if wrapped then
    return true
  end
  local ok, devicons = pcall(require, 'nvim-web-devicons')
  if not ok then
    return false
  end
  local get_icon = devicons.get_icon
  devicons.get_icon = function(name, ext, opts)
    if M.set == 'material' and material and type(name) == 'string' then
      local glyph = M.icon_for(material, name, false)
      if glyph then
        return glyph .. GAP, HL
      end
    end
    return get_icon(name, ext, opts)
  end
  wrapped = true
  return true
end

-- oil's icon column. It asks nvim-web-devicons about files and takes a
-- folder's icon from the column's own options, so that half is set here.
-- One icon for every folder: oil has no hook for a folder's name.
--
-- add_padding off, because oil's own space and the one between two columns
-- already make two after a Nerd Font glyph. With GAP on top that would be
-- three; GAP and the column's space are the two an icon this size wants.
function M.oil_columns()
  if M.set == 'material' and material then
    local folder = M.icon_for(material, '', true)
    if folder then
      return { { 'icon', directory = folder .. GAP, add_padding = false } }
    end
  end
  return { 'icon' }
end

-- Put `asked` in force: 'material', or anything else for the default. Called
-- again on every reload, so it does nothing when nothing changed.
function M.apply(asked)
  local want, why = 'nerd', nil
  if asked == 'material' then
    local t
    t, why = available()
    if t and wrap() then
      want = 'material'
    elseif t then
      why = 'nvim-web-devicons is not installed'
    end
  end
  M.why = why
  if want == M.set then
    return
  end
  M.set = want
  vim.api.nvim_set_hl(0, HL, {})
  -- oil draws its buffers once. Only when it is already loaded: requiring it
  -- here would start it before its own setup has run.
  local oil = package.loaded['oil']
  if oil and oil.set_columns then
    pcall(oil.set_columns, M.oil_columns())
  end
end

return M
