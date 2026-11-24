-- Unit test for lua/external/theme.lua, the colorscheme lanes.
--
--   nvim --clean --headless --cmd "set runtimepath+=$PWD/nvim" \
--        -c "luafile nvim/tests/theme_spec.lua" -c "qa!"
--
-- Prints "ALL PASS"; `make test` and CI grep for it. No plugins: the three
-- schemes are stand-ins written into a scratch runtime directory, each just
-- distinct enough to tell which one a lane ended up with.
--
-- What this guards: theme.conf is written by `theme` and by hand, and read at
-- every start. A reader that trips on it leaves the editor unthemed or, worse,
-- stops startup. The cases are the files a machine can really have: none, a
-- valid one, one naming a scheme that is gone, and the spelling from before
-- the fonts moved into the same file.

local ok = true
local function check(name, cond)
  print((cond and '  pass  ' or '  FAIL  ') .. name)
  if not cond then
    ok = false
  end
end

local scratch = vim.fn.tempname()
local conf = scratch .. '/config/dotfiles/theme.conf'
vim.fn.mkdir(scratch .. '/config/dotfiles', 'p')
vim.fn.mkdir(scratch .. '/rtp/colors', 'p')
vim.fn.mkdir(scratch .. '/rtp/lua', 'p')
-- Read when the module is first required, so set before that.
vim.env.XDG_CONFIG_HOME = scratch .. '/config'

for name, c in pairs {
  ['rose-pine-moon'] = { fg = '#e0def4', bg = '#232136' },
  dracula = { fg = '#f8f8f2', bg = '#282a36' },
  onedark = { fg = '#abb2bf', bg = '#282c34' },
} do
  vim.fn.writefile({
    "vim.cmd 'hi clear'",
    ('vim.g.colors_name = %q'):format(name),
    ("vim.api.nvim_set_hl(0, 'Normal', { fg = %q, bg = %q })"):format(c.fg, c.bg),
    ("vim.api.nvim_set_hl(0, 'LineNr', { fg = %q, bg = %q })"):format(c.fg, c.bg),
    ("vim.api.nvim_set_hl(0, 'Comment', { fg = %q })"):format(c.fg),
  }, scratch .. '/rtp/colors/' .. name .. '.lua')
end
-- The reader sets rose-pine's background option on every load.
vim.fn.writefile({ 'return { setup = function(opts) vim.g.rose_pine_opts = opts end }' }, scratch .. '/rtp/lua/rose-pine.lua')
vim.opt.runtimepath:append(scratch .. '/rtp')

local warned = {}
vim.notify = function(msg, level)
  if level == vim.log.levels.WARN then
    warned[#warned + 1] = msg
  end
end

local loads = {}
vim.api.nvim_create_autocmd('ColorScheme', {
  callback = function(ev)
    loads[#loads + 1] = ev.match
  end,
})

local T = require 'external.theme'
local function write(lines)
  vim.fn.writefile(lines, conf)
end
local function hex(n)
  return n and ('#%06x'):format(n) or nil
end
local function normal(ns)
  return vim.api.nvim_get_hl(ns or 0, { name = 'Normal', link = false })
end

-- A window on a file you write, which is what the editor lane is.
vim.cmd('edit ' .. vim.fn.fnameescape(scratch .. '/a-file.lua'))
local file_win = vim.api.nvim_get_current_win()
local function editor_ns()
  return vim.api.nvim_get_hl_ns { winid = file_win }
end

print 'no file'
T.setup()
check('both lanes are the repo default', T.state.ui == 'rose-pine-moon' and T.state.editor == 'rose-pine-moon')
check('and transparent', T.state.ui_t == true and normal().bg == nil)
check('rose-pine is told not to paint its background', vim.g.rose_pine_opts.disable_background == true)
check('one scheme, so no window gets a namespace of its own', editor_ns() == 0)
check('nothing was warned about', #warned == 0)

print 'valid lanes'
write {
  '# Written by `theme`.',
  'shell.font = 0xProto Nerd Font',
  'shell.colors = dracula',
  'nvim.ui.colors = dracula',
  'nvim.ui.transparent = true',
  'nvim.editor.colors = onedark',
  'nvim.editor.transparent = false',
}
T.reload()
check('the ui lane is what the file names', T.state.ui == 'dracula' and vim.g.colors_name == 'dracula')
check('the ui lane is transparent', normal().bg == nil and hex(normal().fg) == '#f8f8f2')
check('the editor lane is what the file names', T.state.editor == 'onedark')
check('a file window has the editor lane\'s namespace', editor_ns() ~= 0)
check('where the text is the editor scheme, with its own background', hex(normal(editor_ns()).fg) == '#abb2bf' and hex(normal(editor_ns()).bg) == '#282c34')
check('and the gutter is left to the ui lane', next(vim.api.nvim_get_hl(editor_ns(), { name = 'LineNr' })) == nil)
check('keys for other readers are ignored, not warned about', #warned == 0)

print 'an editor key left out follows the ui lane'
write { 'nvim.ui.colors = onedark', 'nvim.ui.transparent = false' }
T.reload()
check('both lanes moved on one line', T.state.ui == 'onedark' and T.state.editor == 'onedark' and T.state.editor_t == false)
check('the file window is back in the global namespace', editor_ns() == 0)
check('opaque means the scheme keeps its background', hex(normal().bg) == '#282c34')

print 'rose-pine, opaque after transparent'
write { 'nvim.ui.colors = rose-pine-moon', 'nvim.ui.transparent = false' }
T.reload()
check('it is told to paint again', vim.g.rose_pine_opts.disable_background == false)
check('and asked for its base back by name, since the option alone is sticky', vim.g.rose_pine_opts.highlight_groups.Normal.bg == 'base')

print 'a bad name'
write { 'nvim.ui.colors = solarized-nope' }
T.reload()
check('falls back to the repo default', T.state.ui == 'rose-pine-moon' and vim.g.colors_name == 'rose-pine-moon')
check('and says which name it could not find', #warned == 1 and warned[1]:find('solarized-nope', 1, true) ~= nil)
write { 'nvim.ui.colors', '= dracula', 'nvim.ui.transparent = maybe', 'not a line at all', '' }
warned = {}
T.reload()
check('mangled lines are skipped without stopping', T.state.ui == 'rose-pine-moon' and #warned == 0)

print 'the spelling from before the fonts moved in'
write { 'nvim.ui = dracula', 'nvim.editor = onedark', 'nvim.editor.transparent = false' }
T.reload()
check('a bare lane is still that lane\'s colorscheme', T.state.ui == 'dracula' and T.state.editor == 'onedark')
write { 'nvim.ui = dracula', 'nvim.ui.colors = onedark' }
T.reload()
check('the new key wins where a file has both', T.state.ui == 'onedark')

print 'a pick reaches a running nvim'
write { 'nvim.ui.colors = onedark', 'shell.font = Hack' }
T.reload()
loads = {}
write { 'nvim.ui.colors = onedark', 'shell.font = Fira Code' }
T.reload()
check('a rewrite that changes nothing here loads nothing', #loads == 0)
-- No T.reload() from here: the watcher has to do it. Written the way `theme`
-- writes, truncated first and filled in after.
loads = {}
write {}
write { 'nvim.ui.colors = dracula' }
local arrived = vim.wait(3000, function()
  return T.state.ui == 'dracula'
end, 20)
check('the file changing is enough, with no command', arrived)
check('the moment it was empty did not flash the default', not vim.tbl_contains(loads, 'rose-pine-moon'))

print ''
print(ok and 'ALL PASS' or 'FAILURES')
