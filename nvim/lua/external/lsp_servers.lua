-- ── Language server definitions ─────────────────────────────────────────────
--
-- Split out from the plugin spec so it can be unit-tested with `nvim --clean`,
-- no plugin bootstrap, no network, no compiler needed to check the parts that
-- actually break.
--
-- Two kinds of server here:
--
--   NATIVE  a real binary on $PATH. clangd (dnf), lua_ls (mise), lemminx
--           (fetched by nvim/deps.sh). No `cmd` — nvim-lspconfig's default is
--           already correct.
--
--   JS      an npm package in nvim/lsp-servers, installed AND run by bun.
--           Needs an explicit `cmd`, because the bin shims npm publishes carry
--           `#!/usr/bin/env node` and would otherwise demand a node that this
--           setup deliberately doesn't install.
--
-- There is no `node` shim anywhere, on purpose. Aliasing node to bun would make
-- any incompatibility surface as an error blaming the wrong tool. Invoking
-- `bun <path>` explicitly means a bun problem says bun.
--
-- The JS argument lists are NOT uniform — bash-language-server rejects --stdio
-- and wants `start`. Each was verified with a real LSP initialize handshake;
-- see nvim/lsp-servers/verify.ts, which asserts exactly these invocations.

local M = {}

--- Where `bun install --cwd nvim/lsp-servers` puts the binaries.
--- Resolves through the ~/.config/nvim symlink into the dotfiles repo.
---@return string
function M.js_bin_dir()
  return vim.fs.joinpath(vim.fn.stdpath 'config', 'lsp-servers', 'node_modules', '.bin')
end

--- npm-published servers: lspconfig name -> { binary, args }
M.js_servers = {
  ts_ls = { bin = 'typescript-language-server', args = { '--stdio' } },
  cssls = { bin = 'vscode-css-language-server', args = { '--stdio' } },
  html = { bin = 'vscode-html-language-server', args = { '--stdio' } },
  jsonls = { bin = 'vscode-json-language-server', args = { '--stdio' } },
  yamlls = { bin = 'yaml-language-server', args = { '--stdio' } },
  -- Not a typo: this one takes a subcommand, not a flag.
  bashls = { bin = 'bash-language-server', args = { 'start' } },
}

--- Build the `cmd` for a JS server: bun runs the package entry point directly.
---@param name string  lspconfig server name
---@param bin_dir? string  override, for tests
---@return string[]|nil
function M.js_cmd(name, bin_dir)
  local spec = M.js_servers[name]
  if not spec then
    return nil
  end
  local cmd = { 'bun', vim.fs.joinpath(bin_dir or M.js_bin_dir(), spec.bin) }
  vim.list_extend(cmd, spec.args)
  return cmd
end

--- Every server this config enables, with its settings.
--- JS entries get their `cmd` filled in by M.build().
---@return table<string, table>
function M.definitions()
  return {
    -- ── native binaries ───────────────────────────────────────────────
    clangd = {},

    lua_ls = {
      settings = {
        Lua = {
          completion = { callSnippet = 'Replace' },
          -- Toggle to silence lua_ls's noisy `missing-fields` warnings:
          -- diagnostics = { disable = { 'missing-fields' } },
        },
      },
    },

    lemminx = {
      filetypes = { 'xml', 'xsd', 'xsl', 'xslt', 'svg' },
      settings = {
        xml = {
          server = { workDir = '~/.cache/lemminx' },
          format = { enabled = true, splitAttributes = false },
          validation = { enabled = true },
          completion = { autoCloseTags = true },
        },
      },
    },

    -- ── bun-run npm packages ──────────────────────────────────────────
    ts_ls = {},
    cssls = {},
    html = { filetypes = { 'html' } },
    jsonls = { settings = { json = { validate = { enable = true } } } },
    yamlls = { settings = { yaml = { validate = true } } },
    bashls = {},
  }
end

--- Final config table: definitions plus `cmd` for the JS servers.
---@param bin_dir? string  override, for tests
---@return table<string, table>
function M.build(bin_dir)
  local defs = M.definitions()
  for name, _ in pairs(M.js_servers) do
    if defs[name] then
      defs[name].cmd = M.js_cmd(name, bin_dir)
    end
  end
  return defs
end

return M
