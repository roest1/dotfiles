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

return M
