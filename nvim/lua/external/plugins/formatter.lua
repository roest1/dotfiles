return {
  'stevearc/conform.nvim',
  event = { 'BufReadPre', 'BufNewFile' },
  config = function()
    local conform = require 'conform'
    conform.setup {
      formatters_by_ft = {
        -- To see what your <key> = { '...' } should be for a language, open a
        -- file and run `:set filetype?`.
        --
        -- No `cs` entry on purpose. C# formatting comes from roslyn through
        -- `lsp_format = 'fallback'` in the keymap below — the LSP already does
        -- it, so a separate formatter would be a second opinion to keep in sync.
        -- csharpier and dotnet-format were defined here and mapped to nothing,
        -- and each spawns a fresh `dotnet` process per format; .NET cold start
        -- is what made that feel slow, not the language server.
        lua = { 'stylua' },

        -- prettierd is gone with node — it was an npm global. prettier itself is
        -- declared in nvim/lsp-servers/package.json and run through bun, the
        -- same way the language servers are. See the `prettier` entry below.
        --
        -- `bash` and `toml` are deliberately absent: prettier has no parser for
        -- either, so those mappings only ever produced "No parser could be
        -- inferred". They were dead when they were written, not broken by the
        -- node removal. Every filetype listed here was checked against the
        -- pinned prettier build.
        typescript = { 'prettier' },
        typescriptreact = { 'prettier' },
        javascript = { 'prettier' },
        javascriptreact = { 'prettier' },
        json = { 'prettier' },
        markdown = { 'prettier' },
        html = { 'prettier' },
        yaml = { 'prettier' },
        css = { 'prettier' },
        -- python = { 'isort', 'black' },
        -- black and ruff are similar
        -- but ruff is significantly faster and handles both linting and formatting in one go
        python = { 'ruff' },
      },
      -- Define the unknown formatter here
      formatters = {
        -- prettier under bun, matching how the JS language servers are invoked.
        -- js_bin_dir() lives in external/lsp_servers.lua and is the one place
        -- that knows where `bun install --cwd nvim/lsp-servers` puts binaries —
        -- duplicating that path here is how the two drift apart.
        ['prettier'] = {
          command = 'bun',
          args = {
            vim.fs.joinpath(require('external.lsp_servers').js_bin_dir(), 'prettier'),
            '--write',
            '$FILENAME',
          },
          -- NOT stdin, and this is load-bearing. prettier's --stdin-filepath
          -- exits 0 and writes NOTHING under bun, while working correctly under
          -- node — a genuine bun/prettier incompatibility. This is exactly why
          -- the repo refuses to alias node to bun: behind a shim it would have
          -- surfaced as "formatting silently does nothing" with no hint where to
          -- look. --write on conform's temp file works for every filetype above.
          stdin = false,
        },
      },
    }

    -- FORMAT-ON-SAVE IS NOT HERE. It's a BufWritePre autocmd in lua/options.lua,
    -- not conform's own `format_on_save` option — it saves and restores the
    -- cursor around the format, which that option doesn't do. Look there before
    -- concluding this config doesn't auto-format; grepping this file for
    -- `format_on_save` finds nothing and is genuinely misleading.
    --
    -- This keymap is the MANUAL trigger, and the only way to format a visual
    -- selection rather than the whole buffer. It was deleted in 1b17ef2
    -- ("remove unused keybindings", Jun 2026) and restored after the docs were
    -- found still promising it.
    --
    -- `lsp_format = 'fallback'` matches what the autocmd passes: a filetype with
    -- no entry above still gets formatted by its language server. That is where
    -- C# formatting comes from (roslyn) — keep the two in step.
    vim.keymap.set({ 'n', 'v' }, '<leader>l', function()
      conform.format {
        lsp_format = 'fallback',
        async = false,
        timeout_ms = 3000,
      }
    end, { desc = 'Format file or range (Visual mode)' })
  end,
}
