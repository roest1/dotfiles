return {
  'stevearc/conform.nvim',
  event = { 'BufReadPre', 'BufNewFile' },
  config = function()
    local conform = require 'conform'
    conform.setup {
      formatters_by_ft = {
        -- To see what your <key> = { '...' }, should be for your language
        --  go to a file in nvim and run `:set filetype?` and it will tell you

        -- conform will run the first available formatter
        -- prettierd is a wrapper of prettier that keeps a daemon running and all requests go to that daemon
        -- prettier is the default formatter and each request spawns a new process (slower)

        --[[
        -- dotnet-format

        # Install:

        dotnet tool install -g dotnet-format

        dotnet-format requires having .editorconfig in the same dir as the .sln file. 

        Example .editorconfig file:

            ```
            [*.cs]
            # Sort using directives alphabetically, with 'System' first
            dotnet_sort_system_directives_first = true
            dotnet_separate_import_directive_groups = true
            # Remove usings that aren't being used
            dotnet_style_qualification_for_field = false:suggestion
            dotnet_style_qualification_for_property = false:suggestion
            ```
        --]]
        --dotnet tool install -g csharpier
        -- cs = { 'csharpier', 'dotnet-format' }, -- maybe cshapier as a backup?
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
        ['csharpier'] = {
          command = 'dotnet-csharpier',
          args = { '--write-stdout' },
        },
        ['dotnet-format'] = {
          command = 'dotnet',
          args = { 'format', '--include', '--no-restore', '$FILENAME' },
          stdin = false, -- dotnet-format works on files, not stdin
        },
      },
    }

  end,
}
