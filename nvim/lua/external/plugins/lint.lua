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

    -- Only run linters whose executable is installed. eslint_d/ruff are
    -- optional (not in reqs.lua), so when missing we skip them instead of
    -- erroring on every buffer read. Install eslint_d for JS/TS linting:
    -- `npm i -g eslint_d` (or :MasonInstall eslint_d).
    local function available_linters(ft)
      local found = {}
      for _, name in ipairs(lint.linters_by_ft[ft] or {}) do
        local linter = lint.linters[name]
        local cmd = type(linter) == 'table' and linter.cmd or name
        if type(cmd) == 'function' then
          cmd = cmd()
        end
        if vim.fn.executable(cmd) == 1 then
          table.insert(found, name)
        end
      end
      return found
    end

    vim.api.nvim_create_autocmd({ 'BufWritePost', 'InsertLeave', 'BufReadPost' }, {
      group = vim.api.nvim_create_augroup('roest-lint', { clear = true }),
      callback = function()
        local names = available_linters(vim.bo.filetype)
        if #names > 0 then
          lint.try_lint(names)
        end
      end,
    })
  end,
}
