-- nvim-lint — async linting alongside LSP diagnostics
--
-- Runs linters on save, insert-leave and buffer read.
-- Complements conform.nvim (formatting) and LSP (type errors).
--
-- Linters:
--   Python     → ruff, declared in ../../../../deps.conf and installed by uv
--
-- JS/TS is deliberately absent. eslint_d sat in this table for months after
-- node left: `available_linters` skipped it because nothing installed it, so
-- the entry linted nothing and documented a linter that did not exist. A
-- mapping is only as real as the binary behind it. To lint JS/TS, add eslint
-- to nvim/lsp-servers/package.json and run it through bun, the way prettier
-- and the language servers are -- and add the table entry in the same commit.

return {
  'mfussenegger/nvim-lint',
  event = { 'BufReadPre', 'BufNewFile' },
  config = function()
    local lint = require 'lint'

    lint.linters_by_ft = {
      python = { 'ruff' },
    }

    -- Only run linters whose executable is installed. ruff comes from the
    -- [nvim] section but a machine that skipped it should get silence, not an
    -- error on every buffer read.
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
