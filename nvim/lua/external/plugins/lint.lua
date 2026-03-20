-- nvim-lint — async linting alongside LSP diagnostics
--
-- Runs linters on save and insert-leave.
-- Complements conform.nvim (formatting) and LSP (type errors).
-- Catches style issues, unused variables, complexity warnings.
--
-- Linters:
--   Python     → ruff (already installed for formatting)
--   JS/TS      → eslint_d (install: npm i -g eslint_d)
--
-- Install via Mason: :MasonInstall ruff eslint_d

return {
  'mfussenegger/nvim-lint',
  event = { 'BufReadPre', 'BufNewFile' },
  config = function()
    local lint = require 'lint'

    lint.linters_by_ft = {
      python = { 'ruff' },
      javascript = { 'eslint_d' },
      typescript = { 'eslint_d' },
      javascriptreact = { 'eslint_d' },
      typescriptreact = { 'eslint_d' },
    }

    vim.api.nvim_create_autocmd({ 'BufWritePost', 'InsertLeave', 'BufReadPost' }, {
      group = vim.api.nvim_create_augroup('roest-lint', { clear = true }),
      callback = function()
        local ft = vim.bo.filetype
        if lint.linters_by_ft[ft] then
          lint.try_lint()
        end
      end,
    })
  end,
}
