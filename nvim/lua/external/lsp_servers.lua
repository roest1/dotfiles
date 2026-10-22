-- ── Language server definitions ─────────────────────────────────────────────
--
-- Split out from the plugin spec so it can be unit-tested with `nvim --clean`,
-- no plugin bootstrap, no network, no compiler needed to check the parts that
-- actually break.
--
-- Three kinds of server here:
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
--   NPM-NATIVE  a native binary that arrives through `bun install` and runs
--           with no runtime at all. Only `tsc` (TypeScript 7, the Go port):
--           the `typescript` package is just a carrier for a per-platform
--           optional dependency holding a statically linked executable.
--           Skipping its `bin/tsc` shim (a node script that execs the binary)
--           is 3 ms / 14 MB at startup against 21 ms / 42 MB through bun.
--
-- There is no `node` shim anywhere, on purpose. Aliasing node to bun would make
-- any incompatibility surface as an error blaming the wrong tool. Invoking
-- `bun <path>` explicitly means a bun problem says bun.
--
-- The JS argument lists are NOT uniform — bash-language-server rejects --stdio
-- and wants `start`. Each was verified with a real LSP initialize handshake;
-- see nvim/lsp-servers/verify.ts, which asserts exactly these invocations.

local M = {}

--- Where `bun install --cwd nvim/lsp-servers` puts packages.
--- Resolves through the ~/.config/nvim symlink into the dotfiles repo.
---@return string
function M.modules_dir()
  return vim.fs.joinpath(vim.fn.stdpath 'config', 'lsp-servers', 'node_modules')
end

--- Where `bun install --cwd nvim/lsp-servers` puts the binaries.
---@return string
function M.js_bin_dir()
  return vim.fs.joinpath(M.modules_dir(), '.bin')
end

-- uname -> the platform/arch suffix of @typescript/typescript-<os>-<arch>.
-- A hand-rolled copy of what typescript/lib/getExePath.js does with
-- process.platform and process.arch, so it's the part most likely to break on
-- a platform nobody tried. An unknown one yields nil, not a guessed path.
local TS_OS = { Linux = 'linux', Darwin = 'darwin', Windows_NT = 'win32' }
local TS_ARCH = { x86_64 = 'x64', AMD64 = 'x64', aarch64 = 'arm64', arm64 = 'arm64', ARM64 = 'arm64' }

--- The native TypeScript 7 executable inside node_modules, or nil if this
--- platform has no package for it.
---@param modules_dir? string  override, for tests
---@param uname? { sysname: string, machine: string }  override, for tests
---@return string|nil
function M.tsc_exe(modules_dir, uname)
  uname = uname or vim.uv.os_uname()
  local os, arch = TS_OS[uname.sysname], TS_ARCH[uname.machine]
  if not (os and arch) then
    return nil
  end
  local exe = os == 'win32' and 'tsc.exe' or 'tsc'
  return vim.fs.joinpath(modules_dir or M.modules_dir(), '@typescript', ('typescript-%s-%s'):format(os, arch), 'lib', exe)
end

--- npm-published servers: lspconfig name -> { binary, args }
M.js_servers = {
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

    -- ── native binary from an npm package ────────────────────────────
    -- nvim-lspconfig's lsp/tsc.lua probes for a tsc >= 7 on $PATH or in the
    -- project's node_modules/.bin and refuses to attach without one. Ours is in
    -- neither, so its root_dir is replaced by the same root markers minus the
    -- probe. Its Deno detection goes with it; no denols is configured here.
    -- `cmd` is filled in by M.build().
    tsc = {
      root_dir = function(bufnr, on_dir)
        local locks = { 'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'bun.lockb', 'bun.lock' }
        on_dir(vim.fs.root(bufnr, { locks, '.git' }) or vim.fn.getcwd())
      end,
    },

    -- ── bun-run npm packages ──────────────────────────────────────────
    cssls = {},
    html = { filetypes = { 'html' } },
    jsonls = { settings = { json = { validate = { enable = true } } } },
    yamlls = { settings = { yaml = { validate = true } } },
    bashls = {},
  }
end

--- Final config table: definitions plus `cmd` for the JS servers and tsc.
---@param bin_dir? string  override, for tests
---@param modules_dir? string  override, for tests
---@param uname? { sysname: string, machine: string }  override, for tests
---@return table<string, table>
function M.build(bin_dir, modules_dir, uname)
  local defs = M.definitions()
  for name, _ in pairs(M.js_servers) do
    if defs[name] then
      defs[name].cmd = M.js_cmd(name, bin_dir)
    end
  end
  local tsc = M.tsc_exe(modules_dir, uname)
  if tsc then
    defs.tsc.cmd = { tsc, '--lsp', '--stdio' }
  else
    -- Better no TypeScript server than lspconfig's default `cmd`, which would
    -- go looking for a tsc this setup never put on $PATH.
    defs.tsc = nil
  end
  return defs
end

return M
