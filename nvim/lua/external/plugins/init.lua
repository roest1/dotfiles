-- The plugin list.
--
-- Plugins are installed by nvim's own manager, vim.pack (`:help vim.pack`), at
-- the commits recorded in nvim-pack-lock.json. That file is tracked, so every
-- machine runs the same plugin code and an update is a diff someone reads.
--
-- Each file named in `modules` returns a table:
--   add     the repositories it needs, as vim.pack.add() takes them
--   setup   a function that configures them (optional)
--   build   { [plugin name] = function(data) end }, run after that plugin is
--           installed or updated (optional); `data.path` is its directory
--
-- Adding one:   write its file, name it below, start nvim, commit the lockfile.
-- Removing one: delete or comment its line, `make -C nvim sync`, commit the
--               lockfile. Until sync runs it stays on disk and in the lockfile.
-- Updating:     `:lua vim.pack.update()`, read what changed, :write to accept
--               (:quit to refuse), commit the lockfile.
-- tests/plugins_spec.lua fails when this list and the lockfile disagree.

local M = {}

-- In the order their `setup` runs. theme is first so that everything after it
-- is drawn in the colorscheme.
M.modules = {
  'theme',
  'treesitter',
  'lsp',
  'formatter',
  'gitsigns',
  'oil',
  -- C#. Off since 2026-11 because it is rarely edited now. The file and the
  -- server's install step in deps.sh are both still here: uncomment this
  -- line, start nvim, and commit the lockfile entry it adds.
  -- 'roslyn',
  'telescope',
}

local function load_modules()
  local mods = {}
  for _, name in ipairs(M.modules) do
    local ok, mod = pcall(require, 'external.plugins.' .. name)
    if ok then
      table.insert(mods, { name = name, mod = mod })
    else
      vim.notify(('plugins: %s failed to load: %s'):format(name, mod), vim.log.levels.ERROR)
    end
  end
  return mods
end

-- Every repository the list asks for, as given to vim.pack.add().
function M.specs()
  local specs = {}
  for _, m in ipairs(load_modules()) do
    vim.list_extend(specs, m.mod.add)
  end
  return specs
end

function M.setup()
  local mods = load_modules()
  local specs, builds = {}, {}
  for _, m in ipairs(mods) do
    vim.list_extend(specs, m.mod.add)
    for plugin, build in pairs(m.mod.build or {}) do
      builds[plugin] = build
    end
  end

  -- Before add(): add() is what installs a plugin that is not on disk yet.
  vim.api.nvim_create_autocmd('PackChanged', {
    group = vim.api.nvim_create_augroup('dotfiles-pack-build', { clear = true }),
    callback = function(ev)
      local build = builds[ev.data.spec.name]
      if build and ev.data.kind ~= 'delete' then
        build(ev.data)
      end
    end,
  })

  -- confirm = false: vim.pack asks before a first install by default. Here the
  -- lockfile already says exactly which commit of what will be fetched, and
  -- `make install` (which runs this headless) has no one to ask.
  local ok, err = pcall(vim.pack.add, specs, { confirm = false })
  if not ok then
    vim.notify('plugins: ' .. tostring(err), vim.log.levels.ERROR)
  end

  for _, m in ipairs(mods) do
    if m.mod.setup then
      local set, why = pcall(m.mod.setup)
      if not set then
        vim.notify(('plugins: %s setup failed: %s'):format(m.name, why), vim.log.levels.ERROR)
      end
    end
  end
end

-- What `make -C nvim sync` runs, headless: put every plugin on the commit the
-- lockfile names, and delete the ones no longer in the list. It never moves a
-- plugin to something newer; that is vim.pack.update(), by hand.
function M.sync()
  vim.pack.update(nil, { target = 'lockfile', force = true })
  local stale = vim
    .iter(vim.pack.get(nil, { info = false }))
    :filter(function(p)
      return not p.active
    end)
    :map(function(p)
      return p.spec.name
    end)
    :totable()
  if #stale > 0 then
    vim.pack.del(stale)
  end
end

return M
