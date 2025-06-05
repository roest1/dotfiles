-- This file gets called in ../../lazy-plugins.lua to load all of our external plugins
-- just remember to update the plugin_modules list below as you add more.

-- NOTE: Plugins can be added with a link (or for a github repo: 'owner/repo' link).
-- NOTE: Plugins can also be added by using a table,
-- with the first argument being the link and the following
-- keys can be used to configure plugin behavior/loading/etc.
--
-- NOTE: Use `opts = {}` to automatically pass options to a plugin's `setup()` function, forcing the plugin to be loaded.
--
-- NOTE: using `require 'path/name'` will include a plugin definition from file lua/path/name.lua
--
-- For additional information with loading, sourcing and examples see `:help lazy.nvim-🔌-plugin-spec`
-- Or use telescope!
-- In normal mode type `<space>sh` then write `lazy.nvim-plugin`
-- you can continue same window with `<space>sr` which resumes last telescope search

local plugin_modules = {
  'external/plugins/gitsigns',
  'external/plugins/lsp',
  'external/plugins/telescope',
  'external/plugins/formatter',
  'external/plugins/oil',
  'external/plugins/glow',
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
