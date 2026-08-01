-- Unit test for lua/external/node_gate.lua
--
-- Run with no plugins, no network, no compiler:
--
--   nvim --clean --headless --cmd "set runtimepath+=$PWD/nvim" \
--        -c "luafile nvim/tests/node_gate_spec.lua" -c "qa!"
--
-- Prints "ALL PASS" on success; CI greps for it. Deliberately dependency-free
-- (no plenary/busted) so it runs anywhere nvim does.

local ok = true
local function check(name, cond)
  if cond then
    print('  pass  ' .. name)
  else
    print('  FAIL  ' .. name)
    ok = false
  end
end

local gate = require 'external.node_gate'

-- A stand-in for the servers table in lsp.lua: the six JS-based servers plus
-- the three native ones that must survive.
local function fixture()
  return {
    ts_ls = {},
    cssls = {},
    html = {},
    jsonls = {},
    yamlls = {},
    bashls = {},
    clangd = {},
    lua_ls = {},
    lemminx = {},
  }
end

local function count(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

print('node_gate')

-- ── with node: nothing is touched ───────────────────────────────────────────
local servers, removed = gate.apply(fixture(), true)
check('with node, keeps all 9 servers', count(servers) == 9)
check('with node, removes nothing', #removed == 0)
check('with node, ts_ls survives', servers.ts_ls ~= nil)

-- ── without node: exactly the JS servers go ─────────────────────────────────
servers, removed = gate.apply(fixture(), false)
check('without node, 3 servers remain', count(servers) == 3)
check('without node, removes 6', #removed == 6)

for _, name in ipairs { 'clangd', 'lua_ls', 'lemminx' } do
  check('without node, ' .. name .. ' survives (native binary)', servers[name] ~= nil)
end
for _, name in ipairs(gate.needs_node) do
  check('without node, ' .. name .. ' dropped', servers[name] == nil)
end

-- ── idempotent, and safe on a partial table ─────────────────────────────────
local partial = { clangd = {}, ts_ls = {} }
local _, r2 = gate.apply(partial, false)
check('only reports servers that were actually present', #r2 == 1 and r2[1] == 'ts_ls')

local _, r3 = gate.apply(partial, false)
check('second application removes nothing more', #r3 == 0)

-- ── the warning names what was lost ─────────────────────────────────────────
local msg = gate.message { 'ts_ls', 'bashls' }
check('message names the dropped servers', msg:find('ts_ls', 1, true) ~= nil)
check('message reassures about the survivors', msg:find('clangd', 1, true) ~= nil)

if ok then
  print('ALL PASS')
else
  print('FAILURES')
end
