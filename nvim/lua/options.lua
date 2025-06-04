-- [[ Setting options ]]
-- See `:help vim.o`
--  For more options, you can see `:help option-list`

-- Make line numbers default
vim.o.number = true
-- add relative line numbers to help with jumping
vim.o.relativenumber = true

-- Enable mouse mode, can be useful for resizing splits for example!
vim.o.mouse = 'a'

-- Show mode (Visual, Command, Insert, ..)
vim.o.showmode = true

-- Sync clipboard between OS and Neovim.
--  Schedule the setting after `UiEnter` because it can increase startup-time.
--  Remove this option if you want your OS clipboard to remain independent.
--  See `:help 'clipboard'`
vim.schedule(function()
    vim.o.clipboard = 'unnamedplus'
end)

-- Enable break indent
vim.o.breakindent = true

-- Save undo history
vim.o.undofile = true

-- Case-insensitive searching UNLESS \C or one or more capital letters in the search term
vim.o.ignorecase = true
vim.o.smartcase = true

-- Keep signcolumn on by default
vim.o.signcolumn = 'yes'

-- Decrease update time
vim.o.updatetime = 250

-- Decrease mapped sequence wait time
vim.o.timeoutlen = 300

-- Configure how new splits should be opened
vim.o.splitright = true
vim.o.splitbelow = true

-- Sets how neovim will display certain whitespace characters in the editor.
--  See `:help 'list'`
--  and `:help 'listchars'`
--
--  Notice listchars is set using `vim.opt` instead of `vim.o`.
--  It is very similar to `vim.o` but offers an interface for conveniently interacting with tables.
--   See `:help lua-options`
--   and `:help lua-options-guide`
-- vim.o.list = true
-- vim.opt.listchars = { tab = '» ', trail = '·', nbsp = '␣' }

-- Preview substitutions live, as you type!
vim.o.inccommand = 'split'

-- Show which line your cursor is on
vim.o.cursorline = true

-- Minimal number of screen lines to keep above and below the cursor.
vim.o.scrolloff = 10

-- if performing an operation that would fail due to unsaved changes in the buffer (like `:q`),
-- instead raise a dialog asking if you wish to save the current file(s)
-- See `:help 'confirm'`
vim.o.confirm = true

--[[ TODO : Maybe future project is to build my own formatter
-- Maybe some other alignment/spacing tricks can be implemented like ensuring `x=1` gets to `x = 1` unless in specific situations like method parameters like in Python.
-- LSP formatters already do a lot, but we can apply a couple settings after the lsp to get the look I want
--
--
-- Align comments in current visual selection
----------------------------------------------
-- Good for sections with consecutive lines of code and comments on each line:
--
-- Before:
--
--    local x = 0 -- x variable
--    local longer_var_name = 2 -- y variable
--
-- Select in Visual and run `:lua AlignComments()`
-- After:
--
--    local x = 0                  -- x variable
--    local longer_var_name = 2    -- y variable
--
----------------------------------------------------
--- Notes:
---   Only works on the selected text from visual mode.
---   Omits lines without comments
---   Default comment token is "--" (Lua)
---
--]]



-- override tab spacing globally
vim.opt.expandtab = true   -- Use spaces instead of tabs
vim.opt.smartindent = true -- Smart indent new lines
local tab = 4
vim.opt.tabstop = tab      -- Number of spaces = <Tab>
vim.opt.shiftwidth = tab   -- Number of spaces to use for auto-indent

-- Auto-formatting
-- runs on save `:w`
vim.api.nvim_create_autocmd('BufWritePre', {
    callback = function(args)
        -- save cursor position
        local pos = vim.api.nvim_win_get_cursor(0)

        -- format using conform plugin
        require('conform').format({
            bufnr = args.buf,
            lsp_fallback = true,
            async = false,
            timeout_ms = 500,
        })

        -- restore cursor position
        pcall(vim.api.nvim_win_set_cursor, 0, pos)
    end
})
