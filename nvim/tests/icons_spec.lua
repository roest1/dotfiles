-- Unit test for lua/external/icons.lua, the icon set nvim draws files with.
--
--   nvim --clean --headless --cmd "set runtimepath+=$PWD/nvim" \
--        -c "luafile nvim/tests/icons_spec.lua" -c "qa!"
--
-- Prints "ALL PASS"; `make test` and CI grep for it. No plugins and no font:
-- nvim-web-devicons and oil are stand-ins that record what they were asked,
-- and the table is a dozen rows written into a scratch directory.
--
-- What this guards: the set is private-use characters, which are empty boxes
-- wherever the font is not. So the cases are less about the icons than about
-- every way the pick must NOT take: another terminal, no font, no table. And
-- the one promise the wrapper exists for: picking the default again gives the
-- plugin's own answers back, all of them.

local ok = true
local function check(name, cond)
  print((cond and '  pass  ' or '  FAIL  ') .. name)
  if not cond then
    ok = false
  end
end

local scratch = vim.fn.tempname()
local fonts = scratch .. '/config/wezterm/fonts'
local conf = scratch .. '/config/dotfiles/theme.conf'
vim.fn.mkdir(fonts, 'p')
vim.fn.mkdir(scratch .. '/config/dotfiles', 'p')
vim.fn.mkdir(scratch .. '/rtp/colors', 'p')
-- Both modules read these when they are first required.
vim.env.XDG_CONFIG_HOME = scratch .. '/config'
vim.env.TERM_PROGRAM = 'WezTerm'

local TABLE = {
  '# Material Icon Theme 5.40.0: which code point is which icon, and which',
  'default\tfile\tfile',
  'default\tfolder\tfolder',
  'ext\td.ts\ttypescript-def',
  'ext\trs\trust',
  'ext\tts\ttypescript',
  'file\treadme.md\treadme',
  'folder\tsrc\tfolder-src',
  'icon\tfile\t100000',
  'icon\tfolder\t100001',
  'icon\tfolder-src\t100002',
  'icon\treadme\t100003',
  'icon\trust\t100004',
  'icon\ttypescript\t100005',
  'icon\ttypescript-def\t100006',
  'icon\tnot-hex\tzz',
  'a line that is not a row',
}
local function at(n)
  return vim.fn.nr2char(0x100000 + n, true)
end

-- The plugin's own answer for anything: a glyph that says who gave it.
local asked = {}
package.preload['nvim-web-devicons'] = function()
  return {
    get_icon = function(name, ext, opts)
      asked[#asked + 1] = { name, ext, opts }
      return 'N', 'DevIconNerd'
    end,
  }
end
-- oil's own choice of where icons come from: a file's name is handed on (to
-- the stand-in above, as the real one hands it to nvim-web-devicons), and
-- every folder gets one glyph out of the column's options.
package.preload['oil.util'] = function()
  return {
    get_icon_provider = function()
      return function(kind, name, conf)
        if kind == 'directory' then
          return conf and conf.directory or 'D', 'OilDirIcon'
        end
        return require('nvim-web-devicons').get_icon(name)
      end
    end,
  }
end
local columns
package.loaded['oil'] = {
  set_columns = function(cols)
    columns = cols
  end,
}

local I = require 'external.icons'
local devicons = require 'nvim-web-devicons'

print 'the table'
local t = I.parse(TABLE)
check('a row that is not a code point is no icon', t ~= nil and t.icon['not-hex'] == nil)
check('an extension', I.icon_for(t, 'main.rs', false) == at(4))
check('a whole name, in any case', I.icon_for(t, 'README.md', false) == at(3))
check('the longest extension first', I.icon_for(t, 'index.d.ts', false) == at(6))
check('and the shorter one when that is all there is', I.icon_for(t, 'index.ts', false) == at(5))
check('a file with nothing of its own', I.icon_for(t, 'notes', false) == at(0) and I.icon_for(t, 'a.unknown', false) == at(0))
check('a folder by its name', I.icon_for(t, 'Src', true) == at(2))
check('a folder with nothing of its own', I.icon_for(t, 'elsewhere', true) == at(1))
check('a file named like a folder is still a file', I.icon_for(t, 'src', false) == at(0))
check('a file with no icons in it is no table', I.parse { 'ext\trs\trust' } == nil)

print 'where the pick must not take'
I.apply 'material'
check('no font: the default stays', I.set == 'nerd' and I.why:find('MaterialIconTheme.ttf', 1, true) ~= nil)
vim.fn.writefile({}, fonts .. '/MaterialIconTheme.ttf')
I.apply 'material'
check('a font with no table beside it: the default stays', I.set == 'nerd' and I.why:find('material-icons.tsv', 1, true) ~= nil)
check('and the plugin still answers for itself', devicons.get_icon 'main.rs' == 'N')

-- The table is read once, so a second module is the only way to a second
-- terminal. Everything the font needs is there now; only the terminal differs.
vim.fn.writefile(TABLE, fonts .. '/material-icons.tsv')
vim.env.TERM_PROGRAM = 'gnome-terminal'
package.loaded['external.icons'] = nil
local elsewhere = require 'external.icons'
elsewhere.apply 'material'
check('another terminal: the default stays', elsewhere.set == 'nerd' and elsewhere.why:find('not WezTerm', 1, true) ~= nil)
vim.env.TERM_PROGRAM = 'WezTerm'
package.loaded['external.icons'] = nil
I = require 'external.icons'

print 'the pick'
check('before it, oil is given its plain column', vim.deep_equal(I.oil_columns(), { 'icon' }))
I.apply 'material'
check('material is in force', I.set == 'material' and I.why == nil)
local glyph, hl = devicons.get_icon('main.rs', 'rs', { default = false })
-- wezterm draws the font at 1.2 times the text: the icon covers the space a
-- caller puts after it, so it brings a second one.
check('a file gets its icon and a space', glyph == at(4) .. ' ')
check('in a highlight group that sets nothing', hl == 'MaterialIcon' and next(vim.api.nvim_get_hl(0, { name = hl })) == nil)
check('a file the plugin has no icon for gets one too', devicons.get_icon 'notes' == at(0) .. ' ')
check('oil is told the folder icon', columns ~= nil and columns[1].directory == at(1) .. ' ')
-- oil pads an icon and then spaces its columns: with the icon's own space
-- that would be three.
check('and not to pad it again', columns ~= nil and columns[1].add_padding == false)
asked = {}
check('a name that is not a string goes to the plugin', devicons.get_icon(nil) == 'N' and #asked == 1)

print 'a folder in oil'
check('oil is wrapped before it loads', I.wrap_oil() == true)
local provider = require('oil.util').get_icon_provider()
local dir, dir_hl = provider('directory', 'src', { directory = 'X' })
check('a folder gets the icon its name has', dir == at(2) .. ' ' and dir_hl == 'MaterialIcon')
check('in any case', provider('directory', 'SRC', {}) == at(2) .. ' ')
check('a folder with no icon of its own gets the plain one', provider('directory', 'elsewhere', {}) == at(1) .. ' ')
check('a file still goes the way oil sends it', provider('file', 'main.rs', {}) == at(4) .. ' ')
package.loaded['oil.columns'] = {}
check('after oil has loaded it is too late, and says so', I.wrap_oil() == false)
package.loaded['oil.columns'] = nil

print 'the default again'
I.apply(nil)
asked = {}
local back, back_hl = devicons.get_icon('main.rs', 'rs', { default = false })
check('the plugin answers, with everything it was asked', back == 'N' and back_hl == 'DevIconNerd' and asked[1][2] == 'rs' and asked[1][3].default == false)
check('for a name it had no icon for as well', devicons.get_icon 'notes' == 'N')
check('oil has its plain column back', vim.deep_equal(columns, { 'icon' }))
local plain, plain_hl = provider('directory', 'src', { directory = 'X' })
check('and a folder is oil\'s own again', plain == 'X' and plain_hl == 'OilDirIcon')
I.apply 'nerd'
I.apply 'something-later'
check('a value this does not know is the default', I.set == 'nerd')
columns = nil
I.apply 'material'
I.apply 'material'
local wrapped_once = devicons.get_icon 'main.rs' == at(4) .. ' '
columns = nil
I.apply 'material'
check('applying the same pick again does nothing', wrapped_once and columns == nil)
I.apply(nil)

print 'through theme.conf'
vim.fn.writefile({
  "vim.cmd 'hi clear'",
  "vim.g.colors_name = 'rose-pine-moon'",
  "vim.api.nvim_set_hl(0, 'Normal', { fg = '#e0def4', bg = '#232136' })",
}, scratch .. '/rtp/colors/rose-pine-moon.lua')
vim.opt.runtimepath:append(scratch .. '/rtp')
package.preload['rose-pine'] = function()
  return { setup = function() end }
end
vim.fn.writefile({ 'icons = material' }, conf)
local T = require 'external.theme'
T.setup()
check('the key is read at start', I.set == 'material')
local loads = 0
vim.api.nvim_create_autocmd('ColorScheme', {
  callback = function()
    loads = loads + 1
  end,
})
vim.fn.writefile({ 'shell.font = Hack' }, conf)
T.reload()
check('taking the key out is the default', I.set == 'nerd')
check('and an icon pick reloads no colorscheme', loads == 0)
vim.fn.writefile({}, conf)
vim.fn.writefile({ 'icons = material' }, conf)
check(
  'a pick reaches a running nvim, with no command',
  vim.wait(3000, function()
    return I.set == 'material'
  end, 20)
)

print ''
print(ok and 'ALL PASS' or 'FAILURES')
