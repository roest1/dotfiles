-- Unit test for the theme.conf reader in wezterm/wezterm.lua.
--
--   nvim --clean --headless -c "luafile wezterm/tests/theme_spec.lua" -c "qa!"
--
-- Prints "ALL PASS"; `make test` and CI grep for it. nvim is only the Lua
-- interpreter here: wezterm cannot be asked what a config evaluated to, so the
-- config is run against a stand-in for the `wezterm` module that records what
-- it was handed.
--
-- What this guards: the file is written by one program and read by two, and a
-- reader that trips on what the writer left behind takes the terminal's whole
-- config down with it. Every case below is a file some machine can really
-- have: none at all, the one from before the fonts moved in, a pick naming a
-- theme a later pull removed, a line cut short by a write in progress.

local ok = true
local function check(name, cond)
  print((cond and '  pass  ' or '  FAIL  ') .. name)
  if not cond then
    ok = false
  end
end

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local config_lua = here .. '/wezterm.lua'

-- Anything the config touches that this test has no opinion about.
local function blank()
  return setmetatable({}, {
    __index = function()
      return blank()
    end,
    __call = function()
      return blank()
    end,
  })
end

-- Evaluate the config with `files` in a scratch XDG_CONFIG_HOME. `config_dir`
-- is where the themes directory is looked for; the repo's own by default.
-- `global` stands in for wezterm.GLOBAL, which outlives a reload: hand two
-- loads the same table and the second is a reload of the first. The fourth
-- thing returned is the event handlers the config registered, by name.
local function load(files, config_dir, global)
  local home = vim.fn.tempname()
  vim.fn.mkdir(home .. '/dotfiles', 'p')
  vim.fn.mkdir(home .. '/wezterm', 'p')
  for path, lines in pairs(files or {}) do
    vim.fn.writefile(lines, home .. '/' .. path)
  end
  vim.env.XDG_CONFIG_HOME = home

  local watched, events = {}, {}
  package.loaded.wezterm = nil
  package.preload.wezterm = function()
    return {
      config_builder = function()
        return {}
      end,
      config_dir = config_dir or here,
      font_with_fallback = function(chain)
        return chain
      end,
      add_to_config_reload_watch_list = function(path)
        watched[#watched + 1] = path
      end,
      on = function(name, handler)
        events[name] = handler
      end,
      action = blank(),
      action_callback = function()
        return blank()
      end,
      GLOBAL = global or {},
      color = blank(),
      truncate_right = function(s)
        return s
      end,
    }
  end
  local config = dofile(config_lua)
  return config, watched, home, events
end

-- A face is the chain handed to font_with_fallback; its head is the family,
-- as a string or as { family = ... }.
local function family(face)
  local head = face[1]
  return type(head) == 'table' and head.family or head
end

local function editor_family(config)
  for _, rule in ipairs(config.font_rules) do
    if rule.blink == 'Slow' then
      return family(rule.font)
    end
  end
end

local function read_theme(path)
  local set, n = {}, 0
  for _, line in ipairs(vim.fn.readfile(path)) do
    local k, v = line:match '^%s*([%a_][%w_.]*)%s*=%s*(.-)%s*$'
    if k then
      set[k] = v
      n = n + 1
    end
  end
  return set, n
end

print 'no file'
local plain, watched, home = load()
check('the terminal is the default palette', plain.colors.background == '#191724')
check('the shell lane is the default font', family(plain.font) == '0xProto Nerd Font')
check('the editor lane is the default font', editor_family(plain) == 'JetBrainsMono Nerd Font')
check('no opacity is set at all', plain.window_background_opacity == nil)
check('theme.conf is watched, so the first pick repaints', vim.tbl_contains(watched, home .. '/dotfiles/theme.conf'))

print 'a file the picker wrote'
local picked = load {
  ['dotfiles/theme.conf'] = {
    '# Written by `theme`.',
    'shell.font = Fira Code',
    'shell.colors = dracula',
    'shell.opacity = 0.9',
    'nvim.editor.font = Iosevka',
    'nvim.ui.colors = rose-pine-moon',
    'nvim.ui.transparent = true',
  },
}
check('shell.font is the base font', family(picked.font) == 'Fira Code')
check('nvim.editor.font is the SGR 5 font', editor_family(picked) == 'Iosevka')
check('shell.colors is the background', picked.colors.background == '#282a36')
check('shell.colors is the tab bar too', picked.colors.tab_bar.background == '#21222c')
check('and the frame the fancy tab bar draws', picked.window_frame.active_titlebar_bg == '#21222c')
check('shell.opacity is the background opacity', picked.window_background_opacity == 0.9)

print 'the file from before the fonts moved in'
local old = load { ['wezterm/fonts.conf'] = { 'shell = Fira Code', 'nvim.editor = Iosevka' } }
check('fonts.conf still sets the shell lane', family(old.font) == 'Fira Code')
check('fonts.conf still sets the editor lane', editor_family(old) == 'Iosevka')
local both = load {
  ['wezterm/fonts.conf'] = { 'shell = Fira Code' },
  ['dotfiles/theme.conf'] = { 'shell.font = Hack' },
}
check('theme.conf wins where both name a lane', family(both.font) == 'Hack')
-- theme.conf used to be nvim's alone, with the bare lane as the colorscheme.
local bare = load { ['dotfiles/theme.conf'] = { 'nvim.editor = onedark' } }
check('a bare lane in theme.conf is a colorscheme, not a font', editor_family(bare) == 'JetBrainsMono Nerd Font')

print 'a file that is wrong'
for name, lines in pairs {
  ['a theme no file is named for'] = { 'shell.colors = solarized' },
  ['a theme name that is a path'] = { 'shell.colors = ../themes/dracula' },
  ['an empty value'] = { 'shell.colors =' },
  ['a line cut short'] = { 'shell.col' },
} do
  local c = load { ['dotfiles/theme.conf'] = lines }
  check(name .. ' leaves the default palette', c.colors.background == '#191724')
end
for _, value in ipairs { '1', '1.5', '0', '0.1', '-0.5', 'ninety', '' } do
  local c = load { ['dotfiles/theme.conf'] = { 'shell.opacity = ' .. value } }
  check(('opacity %q sets nothing'):format(value), c.window_background_opacity == nil)
end
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch .. '/themes', 'p')
vim.fn.writefile({ 'base = #000000', 'text = #ffffff' }, scratch .. '/themes/half.conf')
vim.fn.writefile({
  'base = black',
  'tab_active = #000000',
  'accent = #000000',
  'surface = #000000',
  'overlay = #000000',
  'highlight_med = #000000',
  'text = #ffffff',
  'muted = #000000',
  'subtle = #000000',
}, scratch .. '/themes/named.conf')
local half = load({ ['dotfiles/theme.conf'] = { 'shell.colors = half' } }, scratch)
check('a theme missing colors is not half applied', half.colors.background == '#191724' and half.colors.foreground == '#e0def4')
local named = load({ ['dotfiles/theme.conf'] = { 'shell.colors = named' } }, scratch)
check('a color that is not #rrggbb refuses the whole theme', named.colors.foreground == '#e0def4')

print 'the icon font'
-- Its entry in a chain, if it has one.
local function icon_font(face)
  for _, entry in ipairs(face) do
    if type(entry) == 'table' and entry.family == 'Material Icon Theme' then
      return entry
    end
  end
end
local function editor_face(config)
  for _, rule in ipairs(config.font_rules) do
    if rule.blink == 'Slow' then
      return rule.font
    end
  end
end
local has_font = vim.fn.tempname()
vim.fn.mkdir(has_font .. '/fonts', 'p')
vim.fn.writefile({}, has_font .. '/fonts/MaterialIconTheme.ttf')
local with_font = load({}, has_font)
check('it is in the base chain when its file is there', icon_font(with_font.font) ~= nil)
check('and in the editor lane, which replaces the base chain', icon_font(editor_face(with_font)) ~= nil)
-- Left to its default, wezterm keeps a color font for emoji and never draws a
-- private-use character from it.
check('it is told it is not an emoji font', (icon_font(with_font.font) or {}).assume_emoji_presentation == false)
-- Two cells is as far as wezterm lets a glyph run, and two cells of a 0.6em
-- face are 1.2em: past that it is shrunk to fit, and drawn smaller.
local scale = (icon_font(with_font.font) or {}).scale
check('it is scaled up, and by no more than two cells hold', scale ~= nil and scale > 1 and scale <= 1.2)
check('the base font is still the head of the chain', family(with_font.font) == '0xProto Nerd Font')
local no_font = vim.fn.tempname()
vim.fn.mkdir(no_font, 'p')
check('with no file it is not named: a missing family is a warning on every reload', icon_font(load({}, no_font).font) == nil)
local asked = load({ ['dotfiles/theme.conf'] = { 'icons = material' } }, no_font)
check('and the pick does not name it either', icon_font(asked.font) == nil)
local _, icon_watch = load({}, no_font)
check('where the file will be is watched, so its arrival is a reload', vim.tbl_contains(icon_watch, no_font .. '/fonts/MaterialIconTheme.ttf'))

-- A window holds its font as an override, set by the update-status handler
-- and cached in wezterm.GLOBAL so that it is set once and not every second.
-- One tick of that handler, for a shell pane in window 1: what it set, or nil.
local function tick(config_dir, global)
  local _, _, _, events = load({}, config_dir, global)
  local set
  local window = {
    window_id = function()
      return 1
    end,
    set_config_overrides = function(_, overrides)
      set = overrides
    end,
  }
  local pane = {
    get_title = function()
      return 'bash'
    end,
    get_foreground_process_name = function()
      return '/usr/bin/bash'
    end,
  }
  events['update-status'](window, pane)
  return set
end
local survives = {}
local first = tick(no_font, survives)
check('a window is given its font as an override', first ~= nil and family(first.font) == '0xProto Nerd Font')
check('once, and not again on the next tick', tick(no_font, survives) == nil)
-- The reload after the font arrived. The window has an override already, and
-- it is the override that draws: left alone, every icon is an empty box.
local arrived = tick(has_font, survives)
check('the font arriving rebuilds the override of a window that had one', arrived ~= nil and icon_font(arrived.font) ~= nil)

print 'the themes that ship'
local KEYS = { 'base', 'tab_active', 'accent', 'surface', 'overlay', 'highlight_med', 'text', 'muted', 'subtle' }
local names = {}
for _, path in ipairs(vim.fn.glob(here .. '/themes/*.conf', false, true)) do
  local name = vim.fn.fnamemodify(path, ':t:r')
  names[#names + 1] = name
  local theme, n = read_theme(path)
  local whole = n == #KEYS
  for _, key in ipairs(KEYS) do
    whole = whole and theme[key] ~= nil and theme[key]:match '^#%x%x%x%x%x%x$' ~= nil
  end
  check(name .. ' is the nine colors and nothing else', whole)
  local c = load { ['dotfiles/theme.conf'] = { 'shell.colors = ' .. name } }
  check(name .. ' is what the terminal gets', c.colors.background == theme.base and c.colors.foreground == theme.text)
end
check('rose-pine, dracula and onedark are there', vim.tbl_contains(names, 'rose-pine') and vim.tbl_contains(names, 'dracula') and vim.tbl_contains(names, 'onedark'))

-- The default is a table in wezterm.lua, so the terminal has its colors before
-- the themes directory is linked. themes/rose-pine.conf is the same nine, for
-- the picker to list and preview. Nothing but this holds them together.
local literal, inside = {}, false
for _, line in ipairs(vim.fn.readfile(config_lua)) do
  if line:match '^local palette = {' then
    inside = true
  elseif inside and line:match '^}' then
    break
  elseif inside then
    local k, v = line:match '^%s*([%a_]+) = "(#%x+)"'
    if k then
      literal[k] = v
    end
  end
end
local file = read_theme(here .. '/themes/rose-pine.conf')
local same = true
for _, key in ipairs(KEYS) do
  same = same and literal[key] ~= nil and literal[key] == file[key]
end
check('themes/rose-pine.conf is the default palette in wezterm.lua', same)

print ''
print(ok and 'ALL PASS' or 'FAILURES')
