-- Unit test: the plugin list and nvim-pack-lock.json name the same plugins.
--
--   nvim --clean --headless --cmd "set runtimepath+=$PWD/nvim" \
--        -c "luafile nvim/tests/plugins_spec.lua" -c "qa!"
--
-- Prints "ALL PASS"; CI greps for it. Nothing is installed and nothing is
-- fetched: it reads the list and the lockfile, and never calls vim.pack.
--
-- What this guards: the lockfile is the only thing that makes two machines run
-- the same plugin code. A plugin added to the list without its lockfile entry
-- is installed at whatever its newest commit is that day, on each machine
-- separately. One left in the lockfile after leaving the list keeps being
-- installed, because vim.pack installs what the lockfile names.

local ok = true
local function check(name, cond)
  print((cond and '  pass  ' or '  FAIL  ') .. name)
  if not cond then
    ok = false
  end
end

print 'plugins'

local listed = {}
for _, spec in ipairs(require('external.plugins').specs()) do
  local src = type(spec) == 'table' and spec.src or spec
  local name = type(spec) == 'table' and spec.name or src:match '([^/]+)$'
  listed[name] = src
end

local path = vim.api.nvim_get_runtime_file('nvim-pack-lock.json', false)[1]
check('nvim-pack-lock.json exists', path ~= nil)
local locked = path and vim.json.decode(table.concat(vim.fn.readfile(path), '\n')).plugins or {}

check('the list is not empty', next(listed) ~= nil)
for name, src in pairs(listed) do
  local entry = locked[name]
  check(name .. ' is pinned', entry ~= nil and entry.src == src and (entry.rev or ''):match '^%x+$' ~= nil and #entry.rev == 40)
end
for name in pairs(locked) do
  check(name .. ' is still in the list', listed[name] ~= nil)
end

print ''
print(ok and 'ALL PASS' or 'FAILURES')
