-- nvim-lint — async linting alongside LSP diagnostics
--
-- Runs linters on save and insert-leave.
-- Complements conform.nvim (formatting) and LSP (type errors).
-- Catches style issues, unused variables, complexity warnings.
--
-- Linters:
--   Python     → ruff, declared in ../../../../deps.conf and installed by uv
--   JS/TS      → eslint_d, NOT installed (see below)
--
-- There is no Mason and no npm, so eslint_d has no installer any more. The
-- filetype mapping below is left in place because `available_linters` skips
-- anything not on PATH, so it costs nothing and documents the intent. To make
-- JS/TS linting real again, add it to nvim/lsp-servers/package.json and run it
-- through bun — the same way the language servers work.

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
    -- erroring on every buffer read. eslint_d is expected to be missing —
    -- nothing installs it now that npm is gone.
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
      group = vim.api.nvim_create_augroup('dotfiles-lint', { clear = true }),
      callback = function()
        local names = available_linters(vim.bo.filetype)
        if #names > 0 then
          lint.try_lint(names)
        end
      end,
    })
  end,
}
