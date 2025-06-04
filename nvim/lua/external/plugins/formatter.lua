return {
	'stevearc/conform.nvim',
	event = { 'BufReadPre', 'BufNewFile' },
	config = function()
		local conform = require('conform')
		conform.setup({
			formatters_by_ft = {
				-- conform will run the first available formatter
				-- prettierd is a wrapper of prettier that keeps a daemon running and all requests go to that daemon
				-- prettier is the default formatter and each request spawns a new process (slower)
				lua = { 'stylua' },
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
				py = { 'black' },
				csharp = { 'omnisharp', 'dotnet-format' },
			},
		})

		vim.keymap.set({ 'n', 'v' }, '<leader>l', function()
			conform.format({
				lsp_fallback = true,
				async = false,
				timeout = 500,
			})
		end, { desc = "Format file or range (Visual mode)" })
	end,
}
