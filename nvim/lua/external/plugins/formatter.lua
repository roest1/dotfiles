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

        -- Question:
        -- do I need nested braces { { "a", "b" } }
        -- to signify: "Try A, if not found, use B"
        typescript = { 'prettierd', 'prettier' },
        typescriptreact = { 'prettierd', 'prettier' },
        javascript = { 'prettierd', 'prettier' },
        javascriptreact = { 'prettierd', 'prettier' },
        json = { 'prettierd', 'prettier' },
        markdown = { 'prettierd', 'prettier' },
        html = { 'prettierd', 'prettier' },
        bash = { 'prettierd', 'prettier' },
        yaml = { 'prettierd', 'prettier' },
        toml = { 'prettierd', 'prettier' },
        css = { 'prettierd', 'prettier' },
        -- python = { 'isort', 'black' },
        -- black and ruff are similar
        -- but ruff is significantly faster and handles both linting and formatting in one go
        python = { 'ruff' },
      },
      -- Define the unknown formatter here
      formatters = {
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

    vim.keymap.set({ 'n', 'v' }, '<leader>l', function()
      conform.format {
        lsp_format = 'fallback',
        async = false,
        timeout_ms = 3000,
      }
    end, { desc = 'Format file or range (Visual mode)' })
  end,
}
