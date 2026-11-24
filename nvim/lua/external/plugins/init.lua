-- The plugin list. lazy-plugins.lua hands this to lazy.nvim.
-- Adding one: create a spec file in this directory, then name it here.
-- Turning one off: comment its line.

local plugin_modules = {
  'external/plugins/formatter',
  'external/plugins/gitsigns',
  'external/plugins/lsp',
  'external/plugins/oil',
  -- C#. Off since 2026-11 because it is rarely edited now; the spec file and
  -- the server's install step in deps.sh are both still here, so uncommenting
  -- this line is all it takes to bring it back.
  -- 'external/plugins/roslyn',
  'external/plugins/telescope',
  'external/plugins/theme',
  'external/plugins/treesitter',
}

local plugins = {}
for _, module in ipairs(plugin_modules) do
  local ok, mod = pcall(require, module)
  if ok then
    table.insert(plugins, mod)
  else
    vim.notify('Failed to load plugin module: ' .. module, vim.log.levels.ERROR)
  end
end

return plugins
