-- ─── Shared wezterm config ───────────────────────────────────────────────────
--
-- The half of the terminal that is the SAME on every machine: fonts, the SGR 6
-- font carrier, and the rose-pine surfaces.
--
-- This exists because wezterm.lua and wezterm-windows.lua each carried their own
-- copy, with headers that said so out loud -- "Kept in sync with wezterm.lua BY
-- HAND... If you retune the colours there, retune them here." That is a standing
-- invitation to drift, and it had already produced one: the Windows config had
-- NO tab_bar block at all, so the host's tab bar sat at wezterm's default grey
-- above a themed pane -- exactly the trap the Linux config's own comment warns
-- about.
--
-- The two ENTRY POINTS still have to be separate files, and that part was never
-- the duplication:
--
--   * wezterm.lua declares the `mux` unix domain on a socket under
--     $XDG_RUNTIME_DIR -- a guest path, meaningless on the Windows host.
--   * wezterm-windows.lua cannot be loaded out of the WSL clone at all;
--     wezterm.exe will not read a config over \\wsl.localhost, and `ln -s` from
--     inside WSL onto /mnt/c writes an LX symlink Windows refuses to follow.
--
-- So: two entry points, one body. Each entry point loads this file from its own
-- config_dir, which resolves correctly in both directions -- `wezterm ls-fonts`
-- on the Windows host reports font_dirs as
-- `C:\Users\<you>\.config\wezterm/fonts`, confirming config_dir is the LINKED
-- directory rather than the symlink's target. Both the repo checkout and the
-- linked location hold shared.lua next to the entry point, so either resolves.
--
-- Linked by deps.conf on Linux/macOS and by the $Links table in
-- windows/install.ps1 on Windows -- the same pair that already links wezterm's
-- fonts directory.

local wezterm = require("wezterm")

local M = {}

-- ─── Palette ─────────────────────────────────────────────────────────────────
--
-- rose-pine MAIN's surface ladder. Exported rather than kept private because
-- wezterm.lua's format-tab-title paints its own cells and needs the same three
-- shades; naming them here is what stops that handler drifting from the
-- tab_bar block it is supposed to match.
--
-- nvim deliberately stays on rose-pine-MOON (nvim/lua/external/plugins/theme.lua):
-- theme.lua sets disable_background = true, so nvim paints no background of its
-- own and `base` below IS the editor's background.
--
-- Why main and not moon: moon's base is OKLab L 26.0%, and the ANSI blue this
-- config deliberately leaves at wezterm's default (#5555cc) scores 2.65:1
-- against it -- under the 3:1 floor. Main's base is L 21.3%, almost exactly
-- where that pair crosses 3.00:1, and carries 35% less chroma.
M.palette = {
	base = "#191724", -- the terminal, and the active tab so it merges with the pane
	surface = "#1f1d2e", -- the bar itself and idle tabs
	overlay = "#26233a", -- hover
	highlight_med = "#403d52", -- selection
	text = "#e0def4",
	muted = "#6e6a86", -- readable, but clearly not the focus
	subtle = "#908caa",
}

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
-- The four names live in a machine-local file written by `font`
-- (bash/bash_productivity). It is NOT linked and NOT in deps.conf -- same
-- footing as ~/.bash_local, because it describes this machine's taste rather
-- than what every machine gets. Missing file means the defaults below, which
-- are what this repo shipped before any of this existed.
local FONT_STATE = (os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")) .. "/wezterm/fonts.conf"

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

-- Deliberately a hand-rolled `key = value` reader rather than json_parse: the
-- file is written by a shell function, and this way a half-written or
-- hand-mangled line is skipped instead of taking the whole config down with a
-- parse error. An unknown key is ignored for the same reason -- the config
-- keeps working while the two sides are out of step.
local function read_fontset()
	local set = {}
	for k, v in pairs(DEFAULT_FONTS) do
		set[k] = v
	end
	local fh = io.open(FONT_STATE, "r")
	if not fh then
		return set
	end
	for line in fh:lines() do
		-- A dot is part of a key now, so the class has to admit it.
		local k, v = line:match("^%s*([%a_][%w_.]*)%s*=%s*(.-)%s*$")
		if k and v and v ~= "" and DEFAULT_FONTS[k] then
			set[k] = v
		end
	end
	fh:close()
	return set
end

local FONTS = read_fontset()

-- Picking a font rewrites that file; this is what turns the rewrite into a
-- repaint of every open window with no keystroke and no `wezterm cli`. pcall
-- because the file legitimately does not exist until the first pick.
pcall(wezterm.add_to_config_reload_watch_list, FONT_STATE)

-- Changes whenever any of the four picks change, which is how the override
-- cache at the bottom knows a reload actually meant something. See apply_font.
local FONTS_SIG = table.concat({ FONTS.shell, FONTS["nvim.ui"], FONTS["nvim.editor"], FONTS.claude }, "|")

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

-- Exported so the entry points' own handlers can reach them. wezterm.lua's
-- update-status handler swaps the BASE lane per focused pane, which needs both
-- the chosen families and the same face builders this file uses -- rebuilding
-- them there would be the hand-sync this module exists to end.
M.FONTS = FONTS
M.FONTS_SIG = FONTS_SIG
M.with_fallback = with_fallback
M.base_face = base_face
M.styled_face = styled_face
M.DEFAULT_FONTS = DEFAULT_FONTS
M.FONT_STATE = FONT_STATE

-- ─── apply ───────────────────────────────────────────────────────────────────
--
-- Mutates the caller's config table rather than returning one to merge: a merge
-- helper would have to know which keys are tables to descend into, and getting
-- that wrong silently drops half a block.
function M.apply(config)
	local p = M.palette

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
	-- and config_dir follows the config file's own path, so this resolves on Linux,
	-- macOS and the Windows host identically -- with no fc-cache (which macOS does
	-- not have), no ~/Library/Fonts vs ~/.local/share/fonts split, and no chance of
	-- a stale copy elsewhere on the system shadowing these. That last one is not
	-- hypothetical: two files claiming family "Science Gothic Mono" style
	-- "Regular" resolve by first match, and the loser is silently the wrong glyphs.
	config.font_dirs = { wezterm.config_dir .. "/fonts" }

	-- SGR 6 is "rapid blink". Setting the rate to 0 stops it animating, which
	-- frees the attribute to mean "draw this in the other font" -- see lib/sgr.sh,
	-- which is the only thing that emits it. Italic would have been the obvious
	-- carrier and is wrong: rose-pine italicises nvim's comments.
	--
	-- Science Gothic Mono is generated by wezterm/mkmono.py to 0xProto's exact
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
	-- colors its own output -- gh, git, grep, and so the whole bash_github_tui --
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
		-- sitting directly above the window. Both have to be stated -- and the
		-- Windows config stated neither until this file existed.
		tab_bar = {
			background = p.surface,

			active_tab = { bg_color = p.base, fg_color = p.text },
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
		-- wezterm/deps.sh on Linux/macOS. It is NOT installed on the Windows host,
		-- where the fallback chain simply carries the bar; that degrades the tab
		-- bar's face, nothing else.
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

	config.tab_max_width = 32
	config.use_fancy_tab_bar = true
	config.hide_tab_bar_if_only_one_tab = false
end

-- ─── Claude Code session state in the tab bar ────────────────────────────────
--
-- Lives here, not in wezterm.lua, because it works on BOTH sides and only ever
-- ran on one. The guest emits an OSC 1337 user var from claude/settings.json's
-- hooks and the host's wezterm reads it, so nothing about this is Linux-only --
-- it simply sat in the Linux entry point, which is the same reason the tab_bar
-- block and JetBrainsMono were missing from Windows.
--
-- Its own function rather than part of apply(), because it REGISTERS EVENT
-- HANDLERS while apply() only sets config keys. Keeping the side effect
-- separately callable means an entry point can take the config without the
-- handlers if it ever needs to.
--
-- Caveat, stated rather than discovered later: the process-name signal
-- (CLAUDE_PROC) is weaker across the WSL boundary, where the host asks WSL what
-- a pane is running. The two title signals do not care -- they read the pane
-- title, which the guest sets -- so a Claude pane is still recognized there.
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
	-- prompt or a follow-up question.
	waiting = { glyph = "💬", cols = 2, color = "#eb6f92" },

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
	-- (bash/bash_github_tui's `_gh_tab_var`). The var is still named `gh_tui`
	-- after the command's old name: it is read HERE, on the Windows host, out of
	-- a different clone than the bash that writes it, so renaming it goes dark
	-- until `make windows` has run. Not worth it for a name nobody types.
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

-- Registers both title handlers. Called by each entry point rather than folded
-- into apply(), because this installs EVENT HANDLERS where apply() only sets
-- config keys -- two different kinds of side effect, and an entry point should
-- be able to take the config without the handlers.
function M.claude_tab_titles()
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
		-- The writer is claude/settings.json, linked by deps.conf's [claude]
		-- section: its Notification hook claims "waiting", its Stop hook claims
		-- "complete", each emitting OSC 1337 SetUserVar straight to /dev/tty. That
		-- is the whole channel — no polling, no file I/O per repaint, and nothing
		-- goes through `wezterm cli`. With [claude] unlinked this is simply nil and
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
					Color = hover and M.palette.overlay or (tab.is_active and M.palette.base or M.palette.surface),
				},
			},
			{ Attribute = { Intensity = "Normal" } },
			{ Foreground = { Color = M.palette.muted } },
			{ Text = " " .. index },
		}

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

M.is_claude_pane = is_claude_pane

return M
