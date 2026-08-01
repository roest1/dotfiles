-- ── Node gate: drop JS-based language servers when node is absent ───────────
--
-- Six of the configured language servers are JavaScript programs that Mason
-- installs with npm. No packaging trick avoids that — they need a JS runtime to
-- *execute*, and Mason shells out to `npm` specifically, so bun can't stand in.
--
-- On a machine where node isn't allowed (comment out the node block in the
-- repo's deps.conf), leaving these in `ensure_installed` makes Mason fail
-- loudly on every startup. Removing them instead leaves a working editor:
-- clangd, lua_ls and lemminx are native binaries and unaffected.
--
-- This lives in its own module, separate from the lazy plugin spec, so CI can
-- unit-test it with `nvim --clean` — no plugin bootstrap, no network, no
-- compiler. Testing six lines of logic shouldn't require cloning 26 plugins.

local M = {}

--- Language servers that cannot run without a JS runtime.
M.needs_node = { 'ts_ls', 'cssls', 'html', 'jsonls', 'yamlls', 'bashls' }

--- Remove node-dependent servers from a servers table when node is unavailable.
---
--- Pure: takes the availability of node as an argument rather than probing, so
--- both branches are testable without manipulating PATH.
---
---@param servers table  map of server-name -> config (mutated in place)
---@param has_node boolean
---@return table servers  the same table, filtered
---@return string[] removed  names actually removed (empty when node is present)
function M.apply(servers, has_node)
  local removed = {}
  if has_node then
    return servers, removed
  end
  for _, name in ipairs(M.needs_node) do
    if servers[name] ~= nil then
      servers[name] = nil
      table.insert(removed, name)
    end
  end
  return servers, removed
end

--- Human-readable explanation for the warning shown at startup.
---@param removed string[]
---@return string
function M.message(removed)
  return 'node not found — skipping JS-based language servers ('
    .. table.concat(removed, ', ')
    .. ').\nclangd, lua_ls and lemminx are unaffected.'
end

return M
