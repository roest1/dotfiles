-- Unit test for lua/external/usage.lua, the keymap counter.
--
--   XDG_STATE_HOME=$(mktemp -d) nvim --clean --headless --cmd "set runtimepath+=$PWD/nvim" \
--        -c "luafile nvim/tests/usage_spec.lua" -c "qa!"
--
-- Prints "ALL PASS"; `make test` and CI grep for it. It refuses to run against
-- the real state directory, because it writes keymap-usage.json.
--
-- What this guards: a count is only evidence if a mapping behind a prefix gets
-- counted. which-key installs buffer-local "trigger" mappings on `<Space>`,
-- `g`, `[`, `]`, `z`, `<C-W>` and more; when the counter matched the trigger,
-- it counted it and cleared its buffer, so `gO`, `]c` and every leader mapping
-- read as zeros however often they were pressed.

local ok = true
local function check(name, cond)
  print((cond and '  pass  ' or '  FAIL  ') .. name)
  if not cond then
    ok = false
  end
end

local real = vim.fs.joinpath(vim.env.HOME, '.local', 'state', 'nvim')
if vim.fn.stdpath 'state' == real then
  print 'usage_spec: set XDG_STATE_HOME to a scratch directory; this test writes keymap-usage.json'
  print 'FAILURES'
  return
end

local U = require 'external.usage'
U.setup()

-- Shaped like which-key: nowait, buffer-local triggers, so the trigger fires
-- on the first key and the rest of the sequence arrives as separate keys.
vim.keymap.set('n', 'g', '<Nop>', { buffer = 0, nowait = true, desc = 'which-key-trigger' })
vim.keymap.set('n', ' ', '<Nop>', { buffer = 0, nowait = true, desc = 'which-key-trigger' })
vim.keymap.set('n', 'gJ', '<Nop>', { desc = 'test: behind the g trigger' })
vim.keymap.set('n', '<Space>J', '<Nop>', { desc = 'test: behind the leader trigger' })
vim.keymap.set('n', 'XQ', '<Nop>', { desc = 'test: no trigger in front' })
U.refresh()

-- One key per call, as a keyboard delivers them past a nowait trigger.
local function press(...)
  for _, k in ipairs { ... } do
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, true, true), 'tx', false)
  end
end

press('g', 'J')
press('<Space>', 'J')
press 'XQ' -- an unambiguous mapping resolves as one typed chunk
press 'XQ'
U.flush()

local data = vim.json.decode(table.concat(vim.fn.readfile(vim.fs.joinpath(vim.fn.stdpath 'state', 'keymap-usage.json')), '\n'))
local function count(lhs)
  local row = data['n ' .. lhs]
  return row and row.count or 0
end

print 'usage'
check('a mapping behind the g trigger is counted (gJ = 1)', count 'gJ' == 1)
check('a mapping behind the leader trigger is counted (<Space>J = 1)', count ' J' == 1)
check('the triggers themselves are never counted', count 'g' == 0 and count ' ' == 0)
check('a mapping with no trigger counts each press (XQ = 2)', count 'XQ' == 2)

print ''
print(ok and 'ALL PASS' or 'FAILURES')
