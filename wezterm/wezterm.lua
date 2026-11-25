local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

-- One file. shared.lua was split out for a Windows entry point, retired
-- 2026-11-21, and folded back in 2026-11-23.

-- ─── Palette ─────────────────────────────────────────────────────────────────
--
-- rose-pine MAIN's surface ladder. One table, because format-tab-title paints
-- its own cells and must match the tab_bar block below.
--
-- nvim deliberately stays on rose-pine-MOON (nvim/lua/external/plugins/theme.lua):
-- theme.lua sets disable_background = true, so nvim paints no background of its
-- own and `base` below IS the editor's background.
--
-- Why main and not moon: moon's base is OKLab L 26.0%, and the ANSI blue this
-- config deliberately leaves at wezterm's default (#5555cc) scores 2.65:1
-- against it -- under the 3:1 floor. Main's base is L 21.3%, almost exactly
-- where that pair crosses 3.00:1, and carries 35% less chroma.
local palette = {
	base = "#191724", -- the terminal
	-- The active tab, one step BELOW base. It used to be base itself so the tab
	-- merged into the pane, but base against the bar's surface is a ~1.1:1 step
	-- and the selected tab barely read as selected. Darker than the pane costs a
	-- faint seam under the tab; the accent stripe below carries the rest.
	tab_active = "#0c0b13",
	accent = "#c4a7e7", -- rose-pine iris: the active tab's stripe and index
	surface = "#1f1d2e", -- the bar itself and idle tabs
	overlay = "#26233a", -- hover
	highlight_med = "#403d52", -- selection
	text = "#e0def4",
	muted = "#6e6a86", -- readable, but clearly not the focus
	subtle = "#908caa",
}

-- ─── What this machine picked ────────────────────────────────────────────────
--
-- ~/.config/dotfiles/theme.conf, written by `theme` and keyed by lane:
--
--   shell.font          = 0xProto Nerd Font
--   shell.colors        = dracula
--   shell.opacity       = 0.9
--   nvim.editor.font    = JetBrainsMono Nerd Font
--   nvim.editor.colors  = onedark
--
-- One file for every reader. nvim/lua/external/theme.lua takes the nvim color
-- keys from it and this file takes the rest. It is NOT linked and NOT in
-- deps.conf, the same footing as ~/.bash_local: it describes this machine's
-- taste, not what every machine gets. A missing file means the defaults in this
-- file, which are what the repo shipped before any of it existed.
--
-- A hand-rolled `key = value` reader and not json_parse: a half-written or
-- hand-mangled line is skipped instead of taking the whole config down with a
-- parse error, and a key nobody here knows is ignored, so the config keeps
-- working while the writer and the readers are out of step.
local CONFIG_HOME = os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")
local THEME_STATE = CONFIG_HOME .. "/dotfiles/theme.conf"

local function read_conf(path)
	local set = {}
	local fh = io.open(path, "r")
	if not fh then
		return set
	end
	for line in fh:lines() do
		-- A dot is part of a key, so the class has to admit it.
		local k, v = line:match("^%s*([%a_][%w_.]*)%s*=%s*(.-)%s*$")
		if k and v ~= "" then
			set[k] = v
		end
	end
	fh:close()
	return set
end

local THEME = read_conf(THEME_STATE)

-- Picking anything rewrites that file; this is what turns the rewrite into a
-- repaint of every open window with no keystroke and no `wezterm cli`. pcall
-- because the file legitimately does not exist until the first pick.
pcall(wezterm.add_to_config_reload_watch_list, THEME_STATE)

-- `shell.colors` names a file in wezterm/themes, which deps.conf links beside
-- this one. Each holds the nine colors above and nothing else, so a theme is
-- the terminal's background and the tab bar; the ANSI 16 stay where they are
-- for the reason given over config.colors below.
--
-- Whole or not at all. A file missing a color, or holding something that is not
-- one, leaves the palette above in place: half of one theme over half of
-- another is worse than the default. That is also what a machine gets between a
-- pull that adds a theme and the `make link` that links the directory.
--
-- The default is the table above and not themes/rose-pine.conf, so this file
-- still colors the terminal when the directory is not linked. CI holds the two
-- to each other.
local function themed(name)
	if not name or not name:match("^[%w_-]+$") then
		return nil
	end
	local got = read_conf(wezterm.config_dir .. "/themes/" .. name .. ".conf")
	local out = {}
	for key in pairs(palette) do
		local color = got[key]
		if not (color and color:match("^#%x%x%x%x%x%x$")) then
			return nil
		end
		out[key] = color
	end
	return out
end

palette = themed(THEME["shell.colors"]) or palette

-- ─── Which font, where ───────────────────────────────────────────────────────
--
-- Three fonts can be on screen at once, and they arrive by two different
-- mechanisms, because two is all wezterm has: a font is a property of the
-- WINDOW or a property of the CELL, with nothing in between. The Pane object
-- exposes get_foreground_process_name, get_user_vars and get_title, so wezterm
-- can always tell WHICH pane it is looking at -- it just has no
-- set_config_overrides of its own. Whatever the window decides, every pane in
-- it wears. That asymmetry is the whole shape of what follows.
--
--   BASE    config.font, swapped per window by the update-status handler at the
--           bottom of this file. It follows the FOCUSED pane: a Claude pane
--           pins `claude`, an nvim pane gets `ui`, anything else gets `shell`.
--           This is the lane carrying the compromise -- see the note there.
--
--   SGR 5   "slow blink", pinned to rate 0 below so it never animates, which
--           frees the attribute to mean `editor`. nvim emits it on real file
--           buffers and nowhere else (nvim/lua/external/altfont.lua), so oil,
--           telescope, the statusline and the gutter keep the base font while
--           the file you are editing does not. Per CELL, so it holds in an
--           UNFOCUSED split too -- the half the base lane cannot do.
--
--   SGR 6   "rapid blink", already spoken for: Science Gothic Mono for `make`
--           output, written only by lib/sgr.sh. Untouched by any of this.
--
-- That is the entire attribute budget, and it is why there is no fourth lane.
-- Everything else wezterm can match a font_rule on -- intensity, italic,
-- underline, reverse, strikethrough -- MEANS something on screen, so none of it
-- can be borrowed as a carrier. Blink is available only because the rate can be
-- set to zero. nvim cannot reach SGR 6 from the other side either: its `blink`
-- highlight attribute emits terminfo's blink, which is SGR 5 and nothing else.
--
-- The four names are `<lane>.font` in theme.conf, read above. Until 2026-11 they
-- had a file of their own, ~/.config/wezterm/fonts.conf, keyed by the bare lane
-- name. It is still read, underneath theme.conf, so a machine keeps its fonts
-- between pulling this and rebuilding `theme`, which moves them on its next pick.
local FONT_STATE = CONFIG_HOME .. "/wezterm/fonts.conf"

-- Bracket syntax because the nvim lanes carry a dot. The prefix is doing real
-- work: it says the two of them are the same editor seen from two sides, and
-- that neither has anything to do with `shell` or `claude`.
--
-- `nvim.ui` is NOT "oil". Oil is the most visible thing it draws, but the lane
-- is the window's base font while nvim holds focus, so it is also telescope,
-- the statusline, the gutter and every float. Naming it after oil would have
-- read as a promise that changing it leaves the statusline alone.
local DEFAULT_FONTS = {
	shell = "0xProto Nerd Font",
	["nvim.ui"] = "0xProto Nerd Font",
	["nvim.editor"] = "JetBrainsMono Nerd Font",
	claude = "0xProto Nerd Font",
}

local function read_fontset()
	local old = read_conf(FONT_STATE)
	local set = {}
	for lane, default in pairs(DEFAULT_FONTS) do
		set[lane] = THEME[lane .. ".font"] or old[lane] or default
	end
	return set
end

local FONTS = read_fontset()

-- Watched as well, for the `theme` that still writes it.
pcall(wezterm.add_to_config_reload_watch_list, FONT_STATE)

-- Changes whenever any of the four picks change, which is how the override
-- cache at the bottom knows a reload actually meant something. See apply_font.
local FONTS_SIG = table.concat({ FONTS.shell, FONTS["nvim.ui"], FONTS["nvim.editor"], FONTS.claude }, "|")

-- Material Icon Theme (roest1/fonts, mkicons.py): file icons in color, at
-- U+100000 and up, where no other font has anything. Named in every chain
-- whenever its file is there, and NOT only when theme.conf says
-- `icons = material`. That key decides who prints those characters; the picker
-- has to be able to show the set before it is picked, and a font that answers
-- for nothing else costs a chain nothing.
--
-- assume_emoji_presentation = false is the whole trick. wezterm takes any font
-- with color tables for an emoji font, and draws from one only for a character
-- with emoji presentation, which a private-use code point never has. Without
-- it the font is found, loaded and never used: "No fonts contain glyphs", with
-- the font right there in the chain.
--
-- Only when the file exists, because a family wezterm cannot find is a warning
-- window on every reload.
--
-- ICON_SCALE is wezterm's own knob for a fallback font that reads small beside
-- the text, and an icon does: its square is one em, 16px beside a 25px line.
-- The icons already fill their square (the median one spans 89% of it), so
-- there is nothing to gain by redrawing the font; the square has to grow.
--
-- 1.2 is also where it stops. wezterm lets a square glyph run over the cell
-- beside it when that cell is a space, and no further: two cells. A monospace
-- face advances 0.6em (JetBrains Mono) to 0.62em (0xProto), so two cells are
-- 1.2em. Past that wezterm shrinks the glyph back to fit, and a bigger number
-- here draws a smaller icon.
--
-- Scaled, an icon covers the one space eza puts after it, so whoever prints
-- these characters puts TWO spaces before the name.
local ICON_SCALE = 1.2
local ICON_FONT_FILE = wezterm.config_dir .. "/fonts/MaterialIconTheme.ttf"
local ICON_FONT = (function()
	local f = io.open(ICON_FONT_FILE, "rb")
	if not f then
		return nil
	end
	f:close()
	return { family = "Material Icon Theme", scale = ICON_SCALE, assume_emoji_presentation = false }
end)()

-- The file arriving has to reach a window that is already open, and that takes
-- two things, both of which were missing the first time the font was tried.
--
-- A reload: the font comes with a pull of the fonts submodule, which touches
-- nothing wezterm was watching.
--
-- And the signature: every window holds its font as an OVERRIDE (apply_overrides,
-- at the bottom), built from with_fallback and cached against FONTS_SIG. With the
-- font not in the signature, a reload that added it matched the cache and left
-- the window on the chain it had: every icon an empty box, until focus happened
-- to cross into another lane and rebuild it. The scale is in it for the same
-- reason: it is part of the chain a window is holding.
pcall(wezterm.add_to_config_reload_watch_list, ICON_FONT_FILE)
FONTS_SIG = FONTS_SIG .. "|" .. (ICON_FONT and ("icons@" .. ICON_SCALE) or "")

-- The tail of every chain, and the reason "keeping nerd icons" survives a pick
-- of a font that has none: Symbols Nerd Font Mono is bundled with wezterm, so
-- the glyphs resolve even when the chosen family is a bare monospace face.
-- Noto Color Emoji is named explicitly rather than left to the implicit
-- fallback, for the reason spelled out over config.font below.
local function with_fallback(head)
	local chain = {}
	for _, entry in ipairs(head) do
		chain[#chain + 1] = entry
	end
	chain[#chain + 1] = "Noto Color Emoji"
	chain[#chain + 1] = "Symbols Nerd Font Mono"
	if ICON_FONT then
		chain[#chain + 1] = ICON_FONT
	end
	return wezterm.font_with_fallback(chain)
end

local function base_face(family)
	return with_fallback({ family, "JetBrains Mono" })
end

-- weight and style are spelled out rather than left to wezterm's own bold and
-- italic synthesis, because a font_rule REPLACES the face for a matching cell:
-- match a bold-italic cell with a Regular/Normal face and the bold-italic is
-- silently gone. That is not theoretical for the editor lane -- rose-pine
-- italicises comments, so a missing italic rule would flatten every comment in
-- every file. `wezterm ls-fonts` shows the same expansion in wezterm's own
-- built-in rules (When Intensity=Bold Italic=true, ...).
local function styled_face(family, weight, style)
	return with_fallback({ { family = family, weight = weight, style = style }, "JetBrains Mono" })
end


-- ─── apply ───────────────────────────────────────────────────────────────────
--
-- Mutates the caller's config table rather than returning one to merge: a merge
-- helper would have to know which keys are tables to descend into, and getting
-- that wrong silently drops half a block.
local function apply(config)
	local p = palette

	-- The BASE lane's starting value. `shell` is what a pane that is neither Claude
	-- nor nvim gets, and it is also what every window opens with before the first
	-- update-status tick resolves the focused pane. Defaults to 0xProto Nerd Font,
	-- installed by wezterm/deps.sh. On a machine without it, the fallback chain
	-- (plus wezterm's always-appended bundled fonts, including Symbols Nerd Font
	-- for glyphs) keeps the terminal working — just in JetBrains Mono instead.
	--
	-- Noto Color Emoji is listed explicitly, not relied on as an implicit
	-- fallback, because 0xProto Nerd Font also has a glyph for codepoints like
	-- U+26A1 (⚡) — checked its cmap directly, it's named `oct-zap`, an Octicons
	-- icon patched in like the rest of a Nerd Font's set: flat and single-color,
	-- meant to be tinted like any other icon rather than rendered as emoji
	-- artwork. Order among the three doesn't matter here, though: `wezterm
	-- ls-fonts --text "⚡️"` shows the main terminal's shaping is
	-- presentation-aware — it skips a font whose only match is that flat glyph
	-- when the text carries the VS16 (\u{FE0F}) presentation selector, and
	-- keeps looking until it finds one with real color tables, regardless of
	-- where in the list that font sits. Noto Color Emoji is still named
	-- explicitly so that doesn't depend on wezterm's bundled fallback shipping
	-- a copy. window_frame.font below draws from the SAME two fonts for the
	-- SAME glyph and needs the opposite treatment — its shaping isn't
	-- presentation-aware, so order there is load-bearing. See the note there.
	config.font = base_face(FONTS.shell)

	-- ─── Science Gothic Mono, for `make` output ──────────────────────────────────
	--
	-- Read straight out of the linked config directory rather than installed into
	-- the system font path. deps.conf links wezterm/fonts → ~/.config/wezterm/fonts
	-- and config_dir follows the config file's own path -- so there is no
	-- fc-cache, no system font directory, and no chance of a stale copy elsewhere on the system shadowing these. That last one is not
	-- hypothetical: two files claiming family "Science Gothic Mono" style
	-- "Regular" resolve by first match, and the loser is silently the wrong glyphs.
	config.font_dirs = { wezterm.config_dir .. "/fonts" }

	-- SGR 6 is "rapid blink". Setting the rate to 0 stops it animating, which
	-- frees the attribute to mean "draw this in the other font" -- see lib/sgr.sh,
	-- which is the only thing that emits it. Italic would have been the obvious
	-- carrier and is wrong: rose-pine italicises nvim's comments.
	--
	-- Science Gothic Mono (roest1/fonts) is generated to 0xProto's exact
	-- 0.62em advance, so the two interleave on one grid with no drift; that is the
	-- entire reason a proportional display face can appear in a cell grid at all.
	-- 0xProto stays in the fallback for ✓/✗/box-drawing, which Science Gothic
	-- does not cover.
	--
	-- SGR 5 is "slow blink", the same trick one attribute over, and it means
	-- `editor`: the file you are editing in nvim, and nothing else on the screen.
	-- Its rate is pinned to 0 for exactly the same reason -- an attribute that
	-- animates cannot be borrowed.
	--
	-- Both halves of the guard from lib/sgr.sh apply on the nvim side too, and
	-- nvim/lua/external/altfont.lua enforces them: over ssh, in GNOME Terminal, on
	-- a machine that has not run `make link`, SGR 5 is a real blink attribute and
	-- would set an entire source file flashing. nvim checks before it emits.
	config.text_blink_rate = 0
	config.text_blink_rate_rapid = 0
	config.font_rules = {
		{
			blink = "Rapid",
			intensity = "Bold",
			font = wezterm.font_with_fallback({
				{ family = "Science Gothic Mono", weight = "Bold" },
				"0xProto Nerd Font",
			}),
		},
		{
			blink = "Rapid",
			font = wezterm.font_with_fallback({
				{ family = "Science Gothic Mono", weight = "Regular" },
				"0xProto Nerd Font",
			}),
		},

		-- Four rules for one lane, and all four are load-bearing: a font_rule
		-- replaces the face outright, so the weight/style the cell asked for has to
		-- be reconstructed here or it is lost. Bold before regular and italic
		-- before upright, because wezterm takes the FIRST match and an omitted
		-- field is a wildcard -- `{ blink = "Slow" }` alone would swallow every
		-- bold and italic cell in the buffer on its way past.
		{
			blink = "Slow",
			intensity = "Bold",
			italic = true,
			font = styled_face(FONTS["nvim.editor"], "Bold", "Italic"),
		},
		{
			blink = "Slow",
			intensity = "Bold",
			font = styled_face(FONTS["nvim.editor"], "Bold", "Normal"),
		},
		{
			blink = "Slow",
			italic = true,
			font = styled_face(FONTS["nvim.editor"], "Regular", "Italic"),
		},
		{
			blink = "Slow",
			font = styled_face(FONTS["nvim.editor"], "Regular", "Normal"),
		},
	}

	-- ─── Colors ────────────────────────────────────────────────────────────────
	--
	-- Literal hex, NOT wezterm.color.get_builtin_schemes()['rose-pine'], which is
	-- where this started. That call builds the whole 1113-entry scheme table to
	-- read one row: ~24ms per config evaluation, and this file is evaluated
	-- several times per process.
	--
	-- The ANSI 16 are DELIBERATELY not set, and that is the whole point of writing
	-- it this way instead of `config.color_scheme = 'rose-pine'`. Everything that
	-- colors its own output -- gh, git, grep, and so the whole github TUI --
	-- speaks in those 16 slots, and bash_theme/EZA_COLORS speak in 256-colour
	-- codes layered on the same palette. Remapping them would re-tint all of it:
	-- semantics would survive (green is still "added") but the hues you already
	-- read fluently would not.
	config.colors = {
		foreground = p.text,
		background = p.base,
		cursor_bg = p.text,
		cursor_fg = p.base,
		cursor_border = p.text,

		-- NOT the builtin's value. The rose-pine schemes ship selection_bg
		-- identical to their own background, which renders a selection invisible.
		-- highlight_med is what the scheme means by a selection.
		selection_fg = p.text,
		selection_bg = p.highlight_med,

		-- ─── Tab bar ─────────────────────────────────────────────────────────
		--
		-- A SEPARATE setting from `background` above, which is the trap: theming
		-- the terminal area alone leaves the tab bar at wezterm's default grey
		-- sitting directly above the window. Both have to be stated.
		tab_bar = {
			background = p.surface,

			active_tab = { bg_color = p.tab_active, fg_color = p.text },
			inactive_tab = { bg_color = p.surface, fg_color = p.muted },
			inactive_tab_hover = { bg_color = p.overlay, fg_color = p.text },
			new_tab = { bg_color = p.surface, fg_color = p.subtle },
			new_tab_hover = { bg_color = p.overlay, fg_color = p.text },
		},
	}

	-- The fancy tab bar draws its own frame, which colors.tab_bar.background does
	-- NOT reach -- that is why the bar can stay grey even after the block above.
	-- active/inactive here is the WINDOW's focus, not the tab's.
	config.window_frame = {
		active_titlebar_bg = p.surface,
		inactive_titlebar_bg = p.base,

		-- Science Gothic -- a Google Fonts variable family (OFL), installed by
		-- wezterm/deps.sh. Where it is missing the fallback chain carries the
		-- bar; that degrades the tab bar's face, nothing else.
		--
		-- Noto Color Emoji has to be listed, and BEFORE 0xProto -- the opposite of
		-- config.font's order above. This is the font that actually draws the tab
		-- bar (format-tab-title runs against window_frame.font, not config.font),
		-- and this shaping path is not presentation-aware the way the terminal's
		-- is. `wezterm ls-fonts` has no probe for window_frame.font, so this was
		-- checked by sampling the rendered bar's pixels with 0xProto first: no
		-- orange/gold anywhere, meaning the zap had resolved to 0xProto's flat
		-- glyph regardless of the trailing \u{FE0F}. Listing the color font first
		-- sidesteps the missing presentation logic entirely.
		font = wezterm.font_with_fallback({
			{ family = "Science Gothic", weight = "Bold" },
			"Noto Color Emoji",
			"0xProto Nerd Font",
		}),
		font_size = 11.0,
	}

	-- `shell.opacity` lets the desktop show through the terminal's background;
	-- text stays opaque. Only a number from 0.3 up to 1 is taken: below that the
	-- text is unreadable over most wallpapers, and anything else is a typo. The
	-- key is left unset at 1 so "off" is wezterm's default, whatever that becomes.
	local opacity = tonumber(THEME["shell.opacity"])
	if opacity and opacity >= 0.3 and opacity < 1 then
		config.window_background_opacity = opacity
	end

	config.tab_max_width = 32
	config.use_fancy_tab_bar = true
	config.hide_tab_bar_if_only_one_tab = false
end

-- ─── Claude Code session state in the tab bar ────────────────────────────────
--
-- claude/settings.json's hooks emit an OSC 1337 user var and this reads it.
--
-- Claude Code already writes its state into the PANE title over OSC; nothing
-- here has to poll or shell out. This only surfaces it in the tab, from two
-- independent signals, both read live on every repaint:
--
--   WORKING  the pane title carries Claude's spinner, so this clears the
--            moment Claude stops.
--   CLAIMED  the pane's claude_state user var, set by the hooks in
--            claude/settings.json — "waiting" when Claude asked you
--            something, "complete" when it finished. See the note at the
--            user_vars read below for why this and not has_unseen_output.
--
-- The spinner outranks the claim, because a spinner on screen is the more
-- recent evidence by definition.
--
-- The icon is recomputed from live pane state every repaint and never stored.
-- That is precisely what lets a hand-renamed tab keep its status glyph: the
-- rename binding below sets the tab's TEXT, and the glyph is re-derived
-- around it. Rename and status are orthogonal, which is what you want.
--
-- ✳ is Claude Code's SESSION marker, not a busy marker. This was originally
-- read as "Claude is working", which was wrong and showed up immediately:
-- every Claude tab wore the working glyph forever, including two that had
-- long since stopped. Claude stamps ✳ into the title for the life of the
-- session and leaves it there, so it answers "is this a Claude pane" and
-- says nothing at all about what that pane is doing.
--
-- Kept as a SECOND way to recognise a Claude pane, because it survives cases
-- the process name misses — Claude shelling out to a subprocess makes the
-- foreground process something else entirely for the duration.
--
-- CTRL+SHIFT+I toasts the raw title and process name, which is how the above
-- was diagnosed and how to check it again if the glyphs look wrong.
local CLAUDE_IDLE = "✳"

-- ...and this is the one that actually answers "is it working". Claude Code
-- animates a half-shaded circle in the title while it runs, cycling through
-- these four, and settles back on ✳ the moment it stops. So the ANIMATION is
-- the busy signal and ✳ is its absence — which is the exact inverse of how
-- this was first written, and why two long-finished sessions sat there wearing
-- a hammer.
--
-- Matched as a set rather than a single character because any one of them is
-- only on screen for a frame or two; whichever is showing at repaint time is
-- the one that has to hit.
local CLAUDE_WORKING = { "◐", "◑", "◒", "◓" }

-- Third way to recognise a Claude pane, independent of the title. Matched
-- against the foreground process name; widen it here if CTRL+SHIFT+I shows
-- something else.
local CLAUDE_PROC = "claude"

local function title_has_any(title, set)
	for _, ch in ipairs(set) do
		if title:find(ch, 1, true) then
			return true
		end
	end
	return false
end

-- One row per state: the glyph, its display WIDTH IN COLUMNS, and its colour.
-- cols is stated rather than measured because `#glyph` is bytes and every
-- emoji here is 4 bytes wide but occupies 2 columns — using the byte count to
-- budget space would truncate titles by two characters too many.
--
-- Swap any glyph freely; nothing below depends on which character it is.
-- All three Claude signals in one place, because two callers now need the same
-- answer: format-tab-title, for the status glyph, and apply_font at the bottom,
-- for the base-font pin. They must agree — a pane that reads as Claude in the
-- tab bar and not in the font resolver would wear the glyph in the wrong font.
--
-- Takes strings rather than a pane, because the two callers hold different
-- things: format-tab-title gets a PaneInformation (plain `.title` and
-- `.foreground_process_name` fields) while update-status gets a real Pane
-- object (`:get_title()`, `:get_foreground_process_name()` methods).
local function is_claude_pane(title, proc)
	return title_has_any(title, CLAUDE_WORKING)
		or title:find(CLAUDE_IDLE, 1, true) ~= nil
		or proc:find(CLAUDE_PROC, 1, true) ~= nil
end

local STATES = {
	-- Claude is actively running — its spinner is on screen right now.
	working = { glyph = "🔨", cols = 2, color = "#f6c177" },

	-- Claude's Notification hook fired: it is waiting on you — a permission
	-- prompt, an MCP elicitation, or a subagent that needs input. NOT
	-- idle_prompt: that one fires ~60s after any finished turn, and with no
	-- matcher it repainted every finished tab from ⚡ to 💬 a minute later.
	waiting = { glyph = "💬", cols = 2, color = "#eb6f92" },

	-- Claude called AskUserQuestion (the PreToolUse hook matched on it): an
	-- interview, multiple choice, waiting on your pick. Its own state because
	-- that tool fires NO Notification and NO Stop -- the turn is still open,
	-- the spinner has stopped, and so before this row the tab fell through to
	-- whatever the LAST turn's Stop had claimed: a green bolt on a question.
	-- U+2754 has emoji presentation by default, so no VS16 is needed. The
	-- lavender is borrowed from the same place the green below was.
	asking = { glyph = "\u{2754}", cols = 2, color = "#b4befe" },

	-- Claude's Stop hook fired with work still in flight: the turn ended, but a
	-- background subagent, shell, monitor or workflow will wake it again. The
	-- hook reads Stop's own `background_tasks` array rather than counting
	-- SubagentStart/SubagentStop, so nothing here can drift out of step: an
	-- interrupted subagent that never reports back cannot leave a count stuck.
	-- Crons (`session_crons`) deliberately do NOT count -- a /loop would wear
	-- this glyph for its whole life, and that is a schedule, not work.
	-- U+23F3 has emoji presentation by default, so no VS16. Foam, rose-pine's
	-- own blue, so it reads as a calmer cousin of `working`'s gold.
	background = { glyph = "\u{23F3}", cols = 2, color = "#9ccfd8" },

	-- Claude's Stop hook fired: it finished responding. Distinct from `waiting`
	-- in both glyph and hue so the two halves of "stopped" stay tellable apart
	-- at a glance. Also the fallback for a Claude pane that has not reported
	-- anything yet, which is why it is the else branch below rather than an
	-- explicit `claimed == "complete"` test.
	-- The trailing \u{FE0F} (VS16) forces EMOJI presentation. Without it, ⚡
	-- (U+26A1) defaults to TEXT presentation — a plain glyph tinted by
	-- `color` below — unlike 🔨/💬, which have no text-presentation fallback
	-- and so always render full-color regardless of this attribute.
	-- complete = { glyph = "⚡\u{FE0F}", cols = 2, color = "#a6e3a1" },
	complete = { glyph = "⚡️", cols = 2, color = "#a6e3a1" }, -- typed with VS16 attached directly

	-- A `github` session, which announces itself over the same user-var channel
	-- (`TabMark` in tui/github/src/lib.rs, previously bash_github_tui's
	-- `_gh_tab_var` -- the writer moved from bash to Rust and the wire format
	-- did not). The var is still named `gh_tui` after the command's old name;
	-- renaming it means changing writer and reader together, which is not worth
	-- it for a name nobody types.
	--
	-- U+F408 is `oct-mark_github` — GitHub's own Octicons mark, patched into
	-- 0xProto Nerd Font. NOT an emoji: Unicode has no GitHub logo at any
	-- codepoint, so the logo is only ever available as a font-specific glyph.
	--
	-- Written as the ESCAPE and not as the literal character, which is the one
	-- place this row differs from every other in the table. U+F408 is in the
	-- Private Use Area, and PUA characters do not survive being passed through
	-- tools that sanitise text — pasting the literal glyph here produced an
	-- EMPTY string, which is a silent failure: the config still loads, the tab
	-- still draws, there is simply no icon and nothing says why. `\u{f408}`
	-- cannot be lost that way, and it also states which codepoint this is
	-- without needing a font to read the file.
	--
	-- Verified with `wezterm ls-fonts --text "$(printf '\uf408')"` — escaped
	-- there too, so the check is one you can paste out of this file without a
	-- Nerd Font installed to read it. It resolves to 0xProtoNerdFont-Regular
	-- and reports `cells=1`, which is where cols comes from rather than it
	-- being guessed.
	--
	-- Falls back to a blank box on a machine without the patched font, the same
	-- bargain the rest of the config makes for Nerd Font glyphs.
	--
	-- glyph_color exists for this row alone: a Nerd Font icon is flat and
	-- monochrome, so unlike 🔨/💬/⚡ it does NOT paint itself — left alone it
	-- would inherit the muted grey of the tab index and the octocat's cut-outs
	-- would close up into a smudge. White is what GitHub's own mark uses on a
	-- dark ground.
	--
	-- pad likewise. Every other glyph here is an emoji occupying two columns,
	-- and the drawn artwork sits inside them with its own margin; a Nerd Font
	-- icon is drawn to fill its single cell edge to edge, so the shared
	-- one-column gap leaves the mark touching the title. Two columns puts it
	-- back to looking like the same amount of air as the emoji rows.
	github = { glyph = "\u{f408}", cols = 1, pad = 2, color = "#c4a7e7", glyph_color = "#ffffff" },

	-- A terminal with no Claude session in it.
	--
	-- White, the highest contrast available against both the active (#191724,
	-- 17.7:1) and inactive (#1f1d2e, 16.5:1) tab backgrounds — plain shells
	-- are meant to stand out, not recede.
	--
	-- bold stays set: even at full contrast, weight is what makes the shape
	-- read as a distinct tab rather than just more text in the bar.
	plain = { glyph = "●", cols = 1, color = "#ffffff", bold = true },
}

-- rose-pine ships no green — its palette runs base/surface/overlay through
-- love/gold/rose/pine/foam/iris. #a6e3a1 is an addition, picked to sit at a
-- similar lightness to the rose-pine accents so it reads as part of the set
-- rather than pasted in from another theme.

-- Registers both title handlers (event handlers, where apply() sets config keys).
local function claude_tab_titles()
	wezterm.on("format-tab-title", function(tab, _, _, _, hover, max_width)
		local pane = tab.active_pane
		local pane_title = (pane and pane.title) or ""

		-- A tab renamed by hand (or by the Jarvis sidecar's set-tab-title) wins
		-- over the pane's own title; otherwise fall back to what the pane reports.
		local text = tab.tab_title
		if not text or #text == 0 then
			text = pane_title
		end
		if #text == 0 then
			text = "shell"
		end

		-- Strip Claude's own status glyph out of the TEXT so it is not rendered
		-- twice — this block re-adds one as a status column of its own. Both the
		-- idle marker and whichever spinner frame is currently showing have to go.
		-- Plain find/sub rather than a gsub pattern: these are multi-byte and Lua
		-- patterns are byte-oriented.
		for _, ch in ipairs({ CLAUDE_IDLE, "◐", "◑", "◒", "◓" }) do
			local s, e = text:find(ch, 1, true)
			if s then
				text = text:sub(1, s - 1) .. text:sub(e + 1)
			end
		end
		text = text:gsub("^%s+", "")
		if #text == 0 then
			text = "claude"
		end

		-- Cheap reads, no I/O, evaluated fresh on every repaint.
		local proc = (pane and pane.foreground_process_name) or ""
		local busy = title_has_any(pane_title, CLAUDE_WORKING)
		local is_claude = is_claude_pane(pane_title, proc)

		-- has_unseen_output is GONE from this decision, deliberately.
		--
		-- It answers "have I looked at this tab", not "does this tab need me",
		-- and those come apart the moment you click. A tab showing 💬 would drop
		-- to ⚡ on activation even though Claude's state had not changed at all —
		-- the glyph was reporting the viewer, not the session. A status icon that
		-- changes because you looked at it is worse than no status icon.
		--
		-- What replaces it is the pane's user var, which only Claude can set, so
		-- it moves when and only when Claude's state actually moves.
		--
		-- The writer is claude/tab-state.sh, called by the hooks in
		-- claude/settings.json (linked by deps.conf's [claude] section), emitting
		-- OSC 1337 SetUserVar to Claude's own pty. Esc fires no hook, so the
		-- script retires a stale "asking" or "waiting" itself, from the session
		-- transcript (#110). That is the whole channel: no polling here, no file
		-- I/O per repaint, and nothing goes through `wezterm cli`. With [claude] unlinked this is simply nil and
		-- every stopped session reads ⚡: degraded, but stable and honest rather
		-- than flickering and wrong.
		local uvars = (pane and pane.user_vars) or {}
		local claimed = uvars.claude_state

		local st
		if busy then
			-- The spinner is on screen: outranks any stale hook claim, because the
			-- spinner is the more recent evidence by definition.
			st = STATES.working
		elseif uvars.gh_tui == "1" then
			-- Ranked under `busy` for the same reason: live evidence beats a claim.
			-- Above the Claude branches because github is a foreground program you
			-- are sitting in — while it holds the pane, that is what the pane is,
			-- and its own var is cleared on the way out.
			st = STATES.github
		elseif not is_claude then
			st = STATES.plain
		elseif claimed == "asking" then
			st = STATES.asking
		elseif claimed == "background" then
			st = STATES.background
		elseif claimed == "waiting" then
			st = STATES.waiting
		else
			st = STATES.complete
		end

		-- Budget the index and status column out of max_width BEFORE truncating,
		-- so the glyph can never be the thing that gets cut off. st.cols, not
		-- #st.glyph — see the note on the STATES table.
		--
		-- pad is the gap between glyph and title, one column unless a state asks
		-- for more, and it is budgeted here rather than just appended: a space
		-- added at the print site alone would be taken back out of the title by
		-- the truncation below, which is the same trap st.cols exists to avoid.
		local pad = st.pad or 1
		local index = tostring(tab.tab_index + 1) .. ": "
		local room = max_width - #index - (st.cols + pad) - 1
		if room < 4 then
			room = 4
		end

		-- Intensity is reset to Normal on the index run and set from the state on
		-- the title run, rather than left to inherit: format-tab-title output is
		-- a stream of attribute changes, so an unset Intensity carries over from
		-- whatever the previous tab ended on.
		local out = {
			{
				Background = {
					Color = hover and palette.overlay or (tab.is_active and palette.tab_active or palette.surface),
				},
			},
			{ Attribute = { Intensity = "Normal" } },
		}

		-- The active tab trades its leading space for an accent stripe (U+258E,
		-- one column, so the width budget above is unchanged) and wears its
		-- index in the same accent; idle tabs keep the space and a muted index.
		if tab.is_active then
			out[#out + 1] = { Foreground = { Color = palette.accent } }
			out[#out + 1] = { Text = "\u{258E}" .. index }
		else
			out[#out + 1] = { Foreground = { Color = palette.muted } }
			out[#out + 1] = { Text = " " .. index }
		end

		-- Print the status glyph WITHOUT setting a Foreground color (lets emoji
		-- render natively). glyph_color is the single exception, and only a state
		-- whose glyph is FLAT should set it — see STATES.github.
		if st.glyph_color then
			out[#out + 1] = { Foreground = { Color = st.glyph_color } }
		end
		out[#out + 1] = { Text = st.glyph .. string.rep(" ", pad) }

		-- Apply text color and bolding ONLY to the title text
		out[#out + 1] = { Attribute = { Intensity = st.bold and "Bold" or "Normal" } }
		out[#out + 1] = { Foreground = { Color = st.color } }
		out[#out + 1] = { Text = wezterm.truncate_right(text, room) .. " " }

		return out
	end)

	wezterm.on("format-window-title", function(tab)
		local name = tab.tab_title
		local status = tab.active_pane and tab.active_pane.title or ""
		if name and #name > 0 then
			return status ~= "" and (name .. "  —  " .. status) or name
		end
		return status ~= "" and status or "wezterm"
	end)
end

apply(config)

-- Attach a GUI window to the Jarvis sidecar's mux server so you can watch the
-- worker + brain Claude Code panes live:  wezterm connect mux
-- socket_path points at the SAME default socket the sidecar's `wezterm cli`
-- and `wezterm-mux-server` use, so the GUI shares their panes.
local runtime = os.getenv("XDG_RUNTIME_DIR") or "/run/user/1000"
config.unix_domains = {
	{ name = "mux", socket_path = runtime .. "/wezterm/sock" },
}

-- Drops the OS title bar — the row carrying the app icon, the window title
-- and the minimise/maximise/close buttons — leaving the tab bar as the top
-- row. That row was pure duplication here: format-window-title below mirrors
-- the active tab's name into it, so it was spending a full row of screen to
-- restate what the tab bar already says.
--
-- 'RESIZE' keeps the invisible drag borders, so the window is still resizable
-- by edge. Closing/minimising becomes GNOME's job — Super+H to minimise, and
-- SUPER+w still closes a tab.
--
-- The other option is live again now that use_fancy_tab_bar is back on:
--
--   config.window_decorations = "INTEGRATED_BUTTONS|RESIZE"
--
-- which still drops the separate title row but redraws the minimise/maximise/
-- close buttons INSIDE the tab bar, so nothing is lost. It requires the fancy
-- tab bar and is ignored by the retro one — which is why it was ruled out
-- while that was false. Pick this one if losing the buttons is the part that
-- bothers you. 'TITLE|RESIZE' restores the original two-row layout.
--
-- NOTE: this setting is the one thing here a config reload cannot apply. A
-- window's decoration mode is fixed when the window is created, so changing
-- it needs every wezterm window closed and relaunched, not SUPER+r.
config.window_decorations = "NONE"

-- Registered separately from apply(): it installs event handlers rather than setting config keys.
claude_tab_titles()

-- Rename the active tab. WezTerm has NO way to bind a double-click on a tab:
-- mouse_bindings only cover the terminal area, and the tab bar exposes exactly
-- one mouse event (new-tab-button-click). A key is the whole available API.
--
-- Submitting an EMPTY line clears the override and hands the tab back to the
-- pane's own title, so this is reversible without restarting anything.
config.keys = {
	{
		key = "E",
		mods = "CTRL|SHIFT",
		action = act.PromptInputLine({
			description = "Rename tab (status glyph stays live)",
			action = wezterm.action_callback(function(window, _, line)
				if line ~= nil then
					window:active_tab():set_title(line)
				end
			end),
		}),
	},
	-- Discovery aid for CLAUDE_WORKING/CLAUDE_IDLE/CLAUDE_PROC: shows the strings
	-- the state machine actually reads, so a marker that stops matching can be
	-- diagnosed by looking rather than by guessing.
	{
		key = "I",
		mods = "CTRL|SHIFT",
		action = wezterm.action_callback(function(window, pane)
			local msg = ("title: %s\nproc: %s"):format(
				pane:get_title() or "<none>",
				pane:get_foreground_process_name() or "<none>"
			)
			window:toast_notification("wezterm tab state", msg, nil, 6000)
		end),
	},
}

-- The sidecar names each session's TAB ("WORKER · <repo>", "BRAIN · <date>")
-- via `set-tab-title`. Claude Code emits OSC title sequences that overwrite the
-- OS window title, so mirror the stable tab name into the window title here
-- (with the live status appended) — that's what shows in the GNOME window
-- switcher, keeping multiple Jarvis terminals tellable apart.

-- ─── The BASE lane: follow the focused pane ──────────────────────────────────
--
-- This is where the compromise lives, and it is worth stating plainly rather
-- than discovering it later. wezterm has no per-pane font. The Pane object can
-- IDENTIFY a pane perfectly well — get_foreground_process_name, get_user_vars,
-- get_title are all there and all cheap — but the only thing that can carry a
-- font is the window, via set_config_overrides. So this resolves the base font
-- from whichever pane currently has focus and applies it window-wide.
--
-- What that buys, and what it costs:
--
--   Tabs are exact.       Only one pane in a tab is focused, so switching tabs
--                         between Claude and a shell lands on the right font.
--
--   Splits are not.       Two panes side by side share one base font, and it is
--                         the focused pane's. Focus the shell in a Claude/shell
--                         split and the Claude pane picks up the shell font
--                         until you focus back.
--
--   nvim doesn't care.    Which is the point of the SGR 5 lane: file text is
--                         per-cell, so it stays in `editor` whether nvim's pane
--                         is focused, unfocused, or sharing a split. Only nvim's
--                         CHROME rides this lane.
--
-- Order matters. Claude is tested first because a Claude pane that has shelled
-- out to nvim reports nvim as its foreground process — the ✳ in its title is
-- what still gives it away, and the pin has to win.
local NVIM_PROC = "nvim"

-- ─── Reader mode: side gutters ───────────────────────────────────────────────
--
-- The complaint this answers: on a wide display a full-width terminal puts
-- Claude Code's prose on one very long line, and the eye loses the return sweep
-- back to the start of the next one. Claude Code itself cannot help — `/tui`
-- takes `default|fullscreen` and nothing else, there is no width, wrap or margin
-- key in its settings and no env var for one, and the renderer reads its width
-- straight off the pty's winsize. So the only lever is to make the pty NARROWER,
-- and window_padding is the one setting that does that without surrendering half
-- the window to an empty split.
--
-- PERCENTAGES, not a target column count. wezterm sizes the grid as
-- (pixel width − padding) ÷ cell width, so a percentage narrows proportionally
-- and never has to know the cell size — which wezterm does not expose, and which
-- would otherwise have to be back-derived from get_dimensions() and a font size
-- on every apply. If one percentage stops being right across two displays, THAT
-- derivation is the fallback, not more levels.
--
-- The gutters RIDE THE CLAUDE LANE. They are applied only while the focused
-- pane is one is_claude_pane() recognises, so a shell or an nvim tab keeps the
-- full width it wants — a wide `git log`, a side-by-side diff and oil's column
-- are all worse narrowed, and only Claude's prose is hurt by the long line.
--
-- That is a FOLLOW, not a per-pane apply, and the difference shows up in
-- splits. set_config_overrides is a window-level API and wezterm has no
-- per-pane padding, so this inherits the base font lane's compromise exactly
-- (see the block above): tabs are exact, because only one pane in a tab has
-- focus — but in a Claude/shell split the gutters belong to whichever pane you
-- focused last, and the whole window reflows when you cross between them.
-- Reader mode is therefore for a full-window Claude tab; in a split it works,
-- it just moves under you.
--
-- Padding is the more expensive of the two overrides to flip, and it is worth
-- knowing before this feels like a bug: a font swap re-renders, but a padding
-- change resizes the PTY. Every program in the window gets a SIGWINCH and
-- reflows its scrollback. Alt-tabbing between a Claude tab and a shell tab is
-- now a resize each way. That is the price of the follow, and it is why the
-- gutters go no wider than they have to.
local PAD_LEVELS = { 0, 15, 25 }

local function pad_index(window)
	return tonumber(wezterm.GLOBAL["pad_" .. tostring(window:window_id())]) or 1
end

local function apply_overrides(window, pane)
	if window == nil then
		return
	end

	local title, proc = "", ""
	if pane ~= nil then
		title = pane:get_title() or ""
		proc = pane:get_foreground_process_name() or ""
	end

	-- Resolved ONCE and reused for both overrides, rather than asked again down
	-- in the padding block. Two calls could not disagree today, but they are two
	-- places to keep in step the moment either grows a condition — and the font
	-- lane and the gutter lane being the same lane is the whole feature.
	local claude = is_claude_pane(title, proc)

	local want
	if claude then
		want = FONTS.claude
	elseif proc:find(NVIM_PROC, 1, true) ~= nil then
		want = FONTS["nvim.ui"]
	else
		want = FONTS.shell
	end

	local pad = pad_index(window)

	-- update-status fires about once a second per window, so the cache is what
	-- keeps this from rebuilding a font and reflowing the window on every tick.
	--
	-- GLOBAL rather than a file-local table, because wezterm evaluates this
	-- file per window and dispatches events from a pool of lua contexts: a
	-- local would be a different table depending on which context ran the
	-- callback, so the cache would miss at random and re-apply for no reason.
	--
	-- GLOBAL also SURVIVES a config reload, which is the thing that makes a
	-- stale entry possible — hence FONTS_SIG in the value. Pick a new font, the
	-- reload re-runs this file, the signature changes, and every window
	-- re-applies on its next tick instead of matching its own old cache entry.
	--
	-- The pad index is in the value for a second reason: it is what makes the
	-- CTRL+SHIFT+G toggle work at all. The toggle writes the new index and calls
	-- straight into here, and without the index in the signature this would match
	-- its own cache entry and return before setting a single override.
	--
	-- `claude` is in the value SEPARATELY from `want`, which looks redundant and
	-- is not. `want` is only a proxy for the lane — it is FONTS.claude on a
	-- Claude pane — and the proxy collapses the moment two lanes are assigned the
	-- same font, which `theme` lets you do and which costs nothing until now.
	-- With both lanes on one family, moving focus shell → Claude would leave
	-- `want` unchanged, match the cache, and return: the font would be right
	-- (it already was) and the gutters would silently never appear. The bug
	-- would look like "reader mode stopped working" and point at nothing.
	--
	-- Flat string keys, not a nested table: GLOBAL proxies mutation of the
	-- top-level value only.
	local key = "overrides_" .. tostring(window:window_id())
	local val = want .. "@" .. FONTS_SIG .. "@" .. tostring(pad) .. "@" .. tostring(claude)
	if wezterm.GLOBAL[key] == val then
		return
	end
	wezterm.GLOBAL[key] = val

	-- Built from scratch on every apply rather than merged into whatever is
	-- already there. set_config_overrides replaces the whole table, so the
	-- alternative is a read-modify-write of get_config_overrides() — and that
	-- carries a stale key forward forever the first time one is retired. Every
	-- override this config sets is decided here, in this function; if a third
	-- one appears it goes in this table too, not in a second call somewhere else.
	--
	-- Level 0 and a non-Claude pane both set no window_padding key AT ALL rather
	-- than restating wezterm's default, so "off" means the default whatever the
	-- default becomes.
	local overrides = { font = base_face(want) }
	local pct = PAD_LEVELS[pad]
	if claude and pct > 0 then
		overrides.window_padding = {
			left = pct .. "%",
			right = pct .. "%",
			top = "0.5cell",
			bottom = "0.5cell",
		}
	end
	window:set_config_overrides(overrides)
end

wezterm.on("update-status", apply_overrides)

-- update-status alone would already cover this, but only on its next tick.
-- Focusing a window and watching the font change a beat later reads as a bug,
-- so take the event that fires immediately as well.
wezterm.on("window-focus-changed", apply_overrides)

-- Appended rather than written into the config.keys literal above, because the
-- callback closes over apply_overrides and pad_index, both declared below that
-- point — a forward local would work but would put half this feature 100 lines
-- from the other half.
--
-- CTRL+SHIFT+G ("gutters") is free in wezterm's default key table; the obvious
-- R and M are not (ReloadConfiguration and Hide).
--
-- CYCLE rather than an on/off toggle, so the level that suits a given display
-- is found by pressing the key rather than by editing this file and reloading.
table.insert(config.keys, {
	key = "G",
	mods = "CTRL|SHIFT",
	action = wezterm.action_callback(function(window, pane)
		local next_index = pad_index(window) % #PAD_LEVELS + 1
		wezterm.GLOBAL["pad_" .. tostring(window:window_id())] = next_index
		apply_overrides(window, pane)

		-- The level is set whether or not THIS pane is Claude, and the toast says
		-- which of those just happened. Refusing on a non-Claude pane would be
		-- the tidier-looking rule and the worse one: the setting is a property of
		-- the window, so you would be unable to arm it from the shell tab you
		-- happen to be in, and the key would read as broken. Setting it silently
		-- is the same key reading as broken for a different reason — nothing
		-- moves — so the toast carries the missing half.
		local pct = PAD_LEVELS[next_index]
		local msg
		if pct == 0 then
			msg = "gutters off — full width"
		else
			msg = ("gutters %d%% a side — text gets %d%% of the window"):format(pct, 100 - 2 * pct)
			if not is_claude_pane(pane:get_title() or "", pane:get_foreground_process_name() or "") then
				msg = msg .. "\n(applies while a Claude pane has focus)"
			end
		end
		window:toast_notification("wezterm reader mode", msg, nil, 2000)
	end),
})

return config
