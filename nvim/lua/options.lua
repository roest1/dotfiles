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

-- Smart clipboard provider:
--   • WSL/SSH  → manual OSC52 write to stderr (copy-only; no terminal query)
--               paste reads local register to avoid the terminal-response timeout
--   • Local    → leave unset; nvim auto-picks wl-copy / pbcopy / xclip
-- Note: tmux swallows OSC52 unless `set -g set-clipboard on` is set.
if vim.fn.has 'wsl' == 1 or vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
  local function osc52_copy(lines, _)
    vim.fn.chansend(vim.v.stderr, '\x1b]52;c;' .. vim.fn.system('base64', table.concat(lines, '\n')) .. '\x07')
  end
  local function local_paste()
    return { vim.fn.split(vim.fn.getreg '', '\n'), vim.fn.getregtype '' }
  end
  vim.g.clipboard = {
    name = 'OSC52',
    copy = { ['+'] = osc52_copy, ['*'] = osc52_copy },
    paste = { ['+'] = local_paste, ['*'] = local_paste },
  }
end

-- Yank notification — fires for any yank, any provider, any buffer.
vim.api.nvim_create_autocmd('TextYankPost', {
  callback = function()
    local ev = vim.v.event
    if ev.operator ~= 'y' then
      return
    end
    local lines, regtype = ev.regcontents, ev.regtype
    local msg
    if regtype == 'V' then
      local n = #lines
      msg = (n == 1 and '1 line' or n .. ' lines') .. ' copied to system clipboard'
    elseif regtype:sub(1, 1) == '\22' then
      local c = 0
      for _, l in ipairs(lines) do
        c = c + #l
      end
      msg = c .. ' characters (blockwise) copied to clipboard'
    else
      local c = 0
      for _, l in ipairs(lines) do
        c = c + #l
      end
      msg = c .. ' characters copied to system clipboard'
    end
    vim.notify(msg, vim.log.levels.INFO, { title = 'clipboard' })
  end,
})

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

-- Custom statusline: git branch + file path (strips oil:// prefix)
vim.o.statusline = '%{%v:lua.Statusline()%}'
function Statusline()
  local parts = {}

  -- git branch (gitsigns for file buffers, git command for oil/other buffers)
  local head = vim.b.gitsigns_head
  if not head or head == '' then
    head = vim.fn.system('git -C ' .. vim.fn.shellescape(vim.fn.expand '%:p:h') .. ' rev-parse --abbrev-ref HEAD 2>/dev/null'):gsub('\n', '')
    if vim.v.shell_error ~= 0 then head = '' end
  end
  if head ~= '' then
    table.insert(parts, '[' .. head .. ']')
  end

  -- file path, strip oil:// prefix
  local name = vim.fn.expand '%f'
  name = name:gsub('^oil://', '')
  table.insert(parts, name)

  -- flags
  local flags = vim.bo.modified and ' [+]' or ''
  if vim.bo.readonly then flags = flags .. ' [RO]' end

  return table.concat(parts, ' ') .. flags .. '%=%l,%c %P'
end

-- Minimal number of screen lines to keep above and below the cursor.
vim.o.scrolloff = 10

-- if performing an operation that would fail due to unsaved changes in the buffer (like `:q`),
-- instead raise a dialog asking if you wish to save the current file(s)
-- See `:help 'confirm'`
vim.o.confirm = true

-- override tab spacing globally
vim.opt.expandtab = true -- Use spaces instead of tabs
vim.opt.smartindent = true -- Smart indent new lines
local tab = 4
vim.opt.tabstop = tab -- Number of spaces = <Tab>
vim.opt.shiftwidth = tab -- Number of spaces to use for auto-indent

-- Auto-formatting on save `:w`.
--
-- Deliberately an autocmd rather than conform's own `format_on_save` option:
-- this saves and restores the cursor around the format, which that option
-- doesn't do, and losing your place on every write is worse than the formatting
-- is worth.
--
-- The cost is discoverability — it lives here, not in plugins/formatter.lua
-- where anyone looking for it would look first. That file now points here.
-- `lsp_format = 'fallback'` is what makes filetypes with no formatter entry
-- (C#, via roslyn) format anyway; the <leader>l keymap passes the same thing.
vim.api.nvim_create_autocmd('BufWritePre', {
  callback = function(args)
    -- save cursor position
    local pos = vim.api.nvim_win_get_cursor(0)

    -- format using conform plugin
    require('conform').format {
      bufnr = args.buf,
      lsp_format = 'fallback',
      async = false,
      timeout_ms = 3000,
    }

    -- restore cursor position
    pcall(vim.api.nvim_win_set_cursor, 0, pos)
  end,
})

-- Tree-sitter highlighting
vim.api.nvim_create_autocmd('FileType', {
  callback = function()
    pcall(vim.treesitter.start)
  end,
})

-- PDFs open in the OS's default handler rather than loading as raw bytes.
--
-- BufReadCmd *replaces* nvim's read rather than running alongside it, so the
-- buffer is never populated — you get the external viewer only, not a viewer
-- plus a buffer of binary. It also sits below every route to opening a file, so
-- one autocmd covers oil's <CR> (which goes through bufadd + :buffer, not
-- :edit), `nvim x.pdf`, :e, and telescope alike.
--
-- vim.ui.open is what keeps this portable: it dispatches to xdg-open, open, or
-- wslview itself, so this needs no platform conditional.
--
-- Escape hatch: `:noautocmd e file.pdf` skips this and loads the raw bytes.
vim.api.nvim_create_autocmd('BufReadCmd', {
  pattern = '*.pdf',
  callback = function(args)
    local path = vim.fn.fnamemodify(args.file, ':p')
    local ok, err = vim.ui.open(path)
    -- vim.ui.open returns nil,err rather than throwing when the machine has no
    -- handler at all — a headless RHEL box or a minimal container. Deleting the
    -- buffer there would make <CR> a silent no-op, which is worse than the
    -- binary it replaces, so fall back to the pre-autocmd behaviour instead.
    if not ok then
      vim.notify(err, vim.log.levels.WARN, { title = 'pdf' })
      -- Re-edit with autocmds off so nvim performs its own read. Doing it by
      -- hand instead (readfile + set_lines) does not work: binary mode turns
      -- NULs into newlines and nvim_buf_set_lines rejects those outright.
      vim.schedule(function()
        vim.cmd('noautocmd edit! ' .. vim.fn.fnameescape(path))
      end)
      return
    end
    -- Return to the buffer we came from (oil) before wiping the stub, or the
    -- window is left sitting on a blank buffer.
    local alt = vim.fn.bufnr '#'
    vim.schedule(function()
      if alt ~= -1 and alt ~= args.buf and vim.api.nvim_buf_is_valid(alt) then
        pcall(vim.api.nvim_set_current_buf, alt)
      end
      if vim.api.nvim_buf_is_valid(args.buf) then
        vim.api.nvim_buf_delete(args.buf, { force = true })
      end
    end)
  end,
})

-- Tree-sitter folding (experiment)
-- vim.api.nvim_create_autocmd("FileType", {
--  callback = function()
--    vim.wo.foldmethod = "expr"
--    vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
--  end,
-- })
