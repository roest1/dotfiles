-- :checkhealth integration
--
-- Checks:
--   1. Neovim version (0.10+)
--   2. Core tools (git, make, rg, fd, stylua, prettierd, prettier)
--   3. Formatters (ruff, etc.)
--   4. Linters (eslint_d, etc.)
--   5. Productivity tools (zoxide, fzf, bat, eza)

local check_version = function()
  local verstr = tostring(vim.version())
  if not vim.version.ge then
    vim.health.error(string.format("Neovim out of date: '%s'. Upgrade to latest stable or nightly", verstr))
    return
  end

  if vim.version.ge(vim.version(), '0.10-dev') then
    vim.health.ok(string.format("Neovim version is: '%s'", verstr))
  else
    vim.health.error(string.format("Neovim out of date: '%s'. Upgrade to latest stable or nightly", verstr))
  end
end

local external_reqs = require 'external.reqs'

local check_external_reqs = function()
  for _, exe in ipairs(external_reqs) do
    local is_executable = vim.fn.executable(exe) == 1
    if is_executable then
      vim.health.ok(string.format("Found: '%s'", exe))
    else
      vim.health.warn(string.format("Missing: '%s' — run ./bootstrap.sh or install manually", exe))
    end
  end
end

local function check_tools(title, tools)
  vim.health.start(title)
  for _, tool in ipairs(tools) do
    local found = vim.fn.executable(tool.name) == 1
    if found then
      vim.health.ok(string.format("Found: '%s' (%s)", tool.name, tool.desc))
    elseif tool.required then
      vim.health.warn(string.format("Missing: '%s' (%s)", tool.name, tool.desc))
    else
      vim.health.info(string.format("Optional: '%s' not found (%s)", tool.name, tool.desc))
    end
  end
end

return {
  check = function()
    vim.health.start 'roest-nvim'

    vim.health.info [[Fix only warnings for tools you actually use.
  Run ./bootstrap.sh to install everything at once.]]

    local uv = vim.uv or vim.loop
    vim.health.info('System: ' .. vim.inspect(uv.os_uname()))

    check_version()
    check_external_reqs()

    check_tools('Formatters (conform.nvim)', {
      { name = 'stylua', desc = 'Lua formatter', required = true },
      { name = 'prettierd', desc = 'JS/TS/JSON/HTML/CSS formatter', required = true },
      { name = 'ruff', desc = 'Python formatter + linter', required = true },
      { name = 'prettier', desc = 'Prettier fallback', required = false },
    })

    check_tools('Linters (nvim-lint)', {
      { name = 'ruff', desc = 'Python linter', required = true },
      { name = 'eslint_d', desc = 'JS/TS linter', required = false },
    })

    check_tools('Productivity (bash_roest_productivity)', {
      { name = 'zoxide', desc = 'Smart cd', required = false },
      { name = 'fzf', desc = 'Fuzzy finder', required = false },
      { name = 'bat', desc = 'Better cat', required = false },
      { name = 'eza', desc = 'Better ls', required = false },
    })
  end,
}
