-- Language servers.
--
-- Which servers exist, and their settings, is lua/external/lsp_servers.lua.
-- Installing them is the dotfiles repo's job (deps.conf, nvim/deps.sh,
-- nvim/lsp-servers), never the editor's: there is no Mason, because Mason
-- installs npm packages by shelling out to npm, and this repo has no node.
--
-- nvim-lspconfig is here only as a library of per-server defaults (cmd,
-- filetypes, root markers). Everything else is nvim's own LSP client.

return {
  { -- Teaches lua_ls the nvim API while editing this config.
    'folke/lazydev.nvim',
    ft = 'lua',
    opts = {
      library = {
        { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
      },
    },
  },
  {
    'neovim/nvim-lspconfig',
    dependencies = {
      { 'j-hui/fidget.nvim', opts = {} }, -- the progress spinner, bottom right
    },
    config = function()
      -- The completion popup is nvim's own (`:help lsp-completion`), no plugin.
      -- It opens on the characters a server asks for, such as `.` or `::`;
      -- <C-x><C-o> opens it anywhere, <C-y> accepts, <C-e> dismisses.
      vim.o.completeopt = 'menuone,noselect,popup'

      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('dotfiles-lsp-attach', { clear = true }),
        callback = function(event)
          local client = assert(vim.lsp.get_client_by_id(event.data.client_id))
          local pick = require 'telescope.builtin'
          local function map(keys, func, desc)
            vim.keymap.set('n', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
          end

          -- grn (rename), gra (code action) and K (hover) are nvim defaults
          -- and are not redefined. These replace the defaults that fill the
          -- quickfix list with a telescope picker, and add the three nvim
          -- leaves unmapped (grd, grD, gW).
          map('grr', pick.lsp_references, 'References')
          map('gri', pick.lsp_implementations, 'Implementations')
          map('grt', pick.lsp_type_definitions, 'Type definition')
          map('grd', pick.lsp_definitions, 'Definition')
          map('grD', vim.lsp.buf.declaration, 'Declaration')
          map('gO', pick.lsp_document_symbols, 'Symbols in this file')
          map('gW', pick.lsp_dynamic_workspace_symbols, 'Symbols in the project')

          if client:supports_method('textDocument/completion', event.buf) then
            vim.lsp.completion.enable(true, client.id, event.buf, { autotrigger = true })
          end

          -- Resting the cursor on a name highlights its other uses.
          if client:supports_method('textDocument/documentHighlight', event.buf) then
            local group = vim.api.nvim_create_augroup('dotfiles-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = group,
              callback = vim.lsp.buf.document_highlight,
            })
            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = group,
              callback = vim.lsp.buf.clear_references,
            })
            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('dotfiles-lsp-detach', { clear = true }),
              callback = function(detach)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'dotfiles-lsp-highlight', buffer = detach.buf }
              end,
            })
          end
        end,
      })

      vim.diagnostic.config {
        severity_sort = true,
        float = { border = 'rounded', source = 'if_many' },
        underline = { severity = vim.diagnostic.severity.ERROR },
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = '󰅚 ',
            [vim.diagnostic.severity.WARN] = '󰀪 ',
            [vim.diagnostic.severity.INFO] = '󰋽 ',
            [vim.diagnostic.severity.HINT] = '󰌶 ',
          },
        },
        virtual_text = { source = 'if_many', spacing = 2 },
      }

      -- A server whose binary is not installed is left off rather than
      -- erroring on every file of its type. `:checkhealth external` names
      -- the ones that are missing.
      local lsp_servers = require 'external.lsp_servers'
      local enabled = {}
      for name, cfg in pairs(lsp_servers.build()) do
        vim.lsp.config(name, cfg)
        local cmd = vim.lsp.config[name].cmd
        if type(cmd) ~= 'table' or vim.fn.executable(cmd[1]) == 1 then
          table.insert(enabled, name)
        end
      end
      vim.lsp.enable(enabled)

      if vim.fn.isdirectory(lsp_servers.js_bin_dir()) == 0 then
        vim.notify('JS language servers not installed.\nRun: bun install --cwd ' .. vim.fn.stdpath 'config' .. '/lsp-servers', vim.log.levels.WARN)
      end
    end,
  },
}
