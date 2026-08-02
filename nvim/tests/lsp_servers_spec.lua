-- Unit test for lua/external/lsp_servers.lua
--
--   nvim --clean --headless --cmd "set runtimepath+=$PWD/nvim" \
--        -c "luafile nvim/tests/lsp_servers_spec.lua" -c "qa!"
--
-- Prints "ALL PASS"; CI greps for it. No plugins, no network, no dependencies —
-- the module is split out from the plugin spec precisely so this is possible.
--
-- What this guards: the `cmd` lines are the whole reason node isn't required.
-- If one silently loses its `bun` prefix, the server falls back to a shim with a
-- `#!/usr/bin/env node` shebang and breaks only on machines without node —
-- which is exactly the machine this design exists for, and the last place you'd
-- want to discover it.

local ok = true
local function check(name, cond)
  print((cond and '  pass  ' or '  FAIL  ') .. name)
  if not cond then
    ok = false
  end
end

local S = require 'external.lsp_servers'

print 'lsp_servers'

local defs = S.build '/fake/bin'

-- ── every server is defined ────────────────────────────────────────────────
for _, name in ipairs { 'clangd', 'lua_ls', 'lemminx', 'ts_ls', 'cssls', 'html', 'jsonls', 'yamlls', 'bashls' } do
  check('defines ' .. name, defs[name] ~= nil)
end

-- ── native servers must NOT get a cmd ──────────────────────────────────────
-- They're real binaries on $PATH; nvim-lspconfig's default cmd is correct, and
-- overriding it would hardcode a path that differs per platform.
for _, name in ipairs { 'clangd', 'lua_ls', 'lemminx' } do
  check(name .. ' has no cmd override (native binary)', defs[name].cmd == nil)
end

-- ── JS servers must run through bun ────────────────────────────────────────
for name, spec in pairs(S.js_servers) do
  local cmd = defs[name].cmd
  check(name .. ' has a cmd', type(cmd) == 'table')
  check(name .. ' runs via bun', cmd and cmd[1] == 'bun')
  check(name .. ' points at ' .. spec.bin, cmd and cmd[2] == '/fake/bin/' .. spec.bin)
end

-- ── the non-uniform argument, explicitly ───────────────────────────────────
-- bash-language-server rejects --stdio. This assertion exists because it is the
-- single easiest thing to "fix" into consistency and thereby break.
check('bashls uses `start`, not --stdio', defs.bashls.cmd[3] == 'start')
check('ts_ls uses --stdio', defs.ts_ls.cmd[3] == '--stdio')
check('no JS server is left on --version', (function()
  for name, _ in pairs(S.js_servers) do
    for _, a in ipairs(defs[name].cmd) do
      if a == '--version' then
        return false
      end
    end
  end
  return true
end)())

-- ── settings survive the cmd injection ─────────────────────────────────────
check('lemminx keeps its filetypes', vim.tbl_contains(defs.lemminx.filetypes, 'svg'))
check('jsonls keeps its settings', defs.jsonls.settings.json.validate.enable == true)
check('html keeps its filetypes', defs.html.filetypes[1] == 'html')
check('lua_ls keeps callSnippet', defs.lua_ls.settings.Lua.completion.callSnippet == 'Replace')

-- ── bin dir resolves under the config dir ──────────────────────────────────
check('js_bin_dir is under stdpath(config)', S.js_bin_dir():find(vim.fn.stdpath 'config', 1, true) == 1)
check('js_bin_dir ends at node_modules/.bin', S.js_bin_dir():match 'node_modules/%.bin$' ~= nil)

-- ── unknown servers don't silently produce a cmd ───────────────────────────
check('js_cmd(nil server) returns nil', S.js_cmd 'not-a-real-server' == nil)

print ''
print(ok and 'ALL PASS' or 'FAILURES')
