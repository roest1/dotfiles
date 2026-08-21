-- ~/.config/nvim/lua/external/altfont.lua
--
-- Renders the FILE YOU ARE EDITING in a different font from everything else on
-- the screen -- oil, telescope, the statusline, the gutter, the shell in the
-- next pane, a Claude Code session in the next tab.
--
-- HOW, because it is not obvious that a terminal can do this at all:
--
-- wezterm can key a font off an SGR attribute (`font_rules`), and it can pin
-- the blink rate to zero so a blink attribute never animates. That turns blink
-- into a spare bit: a per-CELL channel that means "draw this in the other
-- font" and costs nothing on screen. wezterm/wezterm.lua already spends SGR 6
-- (rapid blink) on Science Gothic Mono for `make` output -- lib/sgr.sh is that
-- one's writer. This file is the writer for SGR 5 (slow blink), which the same
-- config maps to the `editor` font.
--
-- Neovim can emit it: `blink` is a real highlight attribute (0.12's
-- nvim_set_hl takes it and the TUI writes SGR 5 for it). The delivery is a
-- decoration provider adding one ephemeral extmark per visible line with
-- hl_mode = 'combine', so the attribute is ADDED to whatever treesitter, LSP
-- semantic tokens and the colorscheme already decided. Colours, bold and
-- italic all survive; only the font changes. Combining also means this needs
-- no knowledge of which highlight groups exist, which matters because LSP
-- semantic-token groups are created long after startup.
--
-- Per-cell is the whole reason to do it this way rather than by asking wezterm
-- to swap the window's font when nvim is focused. Cells do not care about
-- focus, so file text stays in `editor` in an unfocused split, and oil in a
-- split next to it stays in the base font at the same time.
--
-- THE GUARD IS THE WHOLE SAFETY STORY, and it is lib/sgr.sh's guard, for the
-- same reasons -- read the long version there. Outside wezterm, SGR 5 means
-- what it actually says: BLINKING TEXT. Get this wrong and every line of every
-- file flashes. The two conditions that can be checked from inside nvim:
--
--   TERM_PROGRAM=WezTerm    Over ssh, in GNOME Terminal, in Terminal.app, in
--                           tmux, this is absent and nothing is emitted.
--
--   the fonts are linked    Being in wezterm is not the same as wezterm having
--                           the font_rules. On a machine that has not run
--                           `make link`, or one pointed at a stock config, the
--                           rule is absent and SGR 5 blinks. The linked font
--                           directory is the cheapest true proxy for "this
--                           repo's wezterm.lua is the live config", since
--                           deps.conf links config and fonts together.
--
-- lib/sgr.sh's third condition, `-t 1`, has no analogue here: nvim's TUI does
-- not run down a pipe.
--
-- Usage:
--   :AltFont          -> report what it decided and why
--   :AltFont toggle   -> off/on for this session

local M = {}

local CARRIER = 'AltFontCarrier'

local enabled = false
local ns = nil

-- Both halves of the guard. Deliberately evaluated ONCE at setup: TERM_PROGRAM
-- cannot change under a running nvim, and a `make link` mid-session is not
-- worth a stat() per redraw.
local function terminal_supports_carrier()
  if vim.env.TERM_PROGRAM ~= 'WezTerm' then
    return false, 'TERM_PROGRAM is ' .. (vim.env.TERM_PROGRAM or '<unset>') .. ', not WezTerm'
  end
  local cfg = vim.env.XDG_CONFIG_HOME
  if not cfg or cfg == '' then
    cfg = vim.fn.expand '~/.config'
  end
  if vim.fn.isdirectory(cfg .. '/wezterm/fonts') ~= 1 then
    return false, cfg .. '/wezterm/fonts is not linked — run `make link`'
  end
  return true, 'wezterm with linked fonts'
end

-- "A file you write", which is the whole spec. buftype is what does the work:
-- oil is 'acwrite', terminals are 'terminal', telescope/trouble/undotree and
-- every other scratch UI are 'nofile', help is 'help', quickfix is 'quickfix'.
-- Only a real file-backed buffer is ''.
--
-- The scheme test is the belt to that braces. A plugin that presents a virtual
-- filesystem through a normal buftype -- oil-ssh, fugitive's blobs -- still
-- names its buffers with a URL scheme, and those are not files you write
-- either.
local function is_file_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= '' then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return false
  end
  if name:match '^%a[%w+.-]*://' then
    return false
  end
  return true
end

local function define_carrier()
  -- blink and NOTHING else. Any colour here would be combined into every cell
  -- of the buffer and would flatten the colorscheme.
  vim.api.nvim_set_hl(0, CARRIER, { blink = true })
end

function M.setup()
  local ok, why = terminal_supports_carrier()

  vim.api.nvim_create_user_command('AltFont', function(opts)
    local arg = opts.args
    if arg == 'toggle' then
      if not ok then
        vim.notify('altfont: refusing — ' .. why, vim.log.levels.WARN)
        return
      end
      enabled = not enabled
      vim.cmd 'redraw!'
    end
    vim.notify(('altfont: %s (%s)'):format(enabled and 'on' or 'off', why), vim.log.levels.INFO)
  end, {
    nargs = '?',
    complete = function()
      return { 'toggle' }
    end,
    desc = 'Report or toggle the SGR 5 alternate-font carrier',
  })

  if not ok then
    return
  end
  enabled = true

  define_carrier()
  -- A colorscheme change clears user highlight groups, so re-assert. Cheap,
  -- and the alternative is the carrier silently evaporating on :colorscheme.
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('external.altfont', { clear = true }),
    callback = define_carrier,
    desc = 'Re-declare the alternate-font carrier highlight',
  })

  ns = vim.api.nvim_create_namespace 'external.altfont'
  vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, _, bufnr)
      return enabled and is_file_buf(bufnr)
    end,
    on_line = function(_, _, bufnr, row)
      -- Spans to column 0 of the next row so the cell past end-of-line is
      -- covered too; on the last line that position is the end of the buffer,
      -- which is a valid extmark end. Priority is high so nothing later
      -- replaces it, and 'combine' is what keeps that from costing colours.
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
        end_row = row + 1,
        end_col = 0,
        hl_group = CARRIER,
        hl_mode = 'combine',
        hl_eol = true,
        ephemeral = true,
        priority = 10000,
      })
    end,
  })
end

return M
