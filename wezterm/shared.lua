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

-- ─── apply ───────────────────────────────────────────────────────────────────
--
-- Mutates the caller's config table rather than returning one to merge: a merge
-- helper would have to know which keys are tables to descend into, and getting
-- that wrong silently drops half a block.
function M.apply(config)
	local p = M.palette

	-- Noto Color Emoji is named explicitly so this doesn't depend on wezterm's
	-- bundled fallback shipping a copy. window_frame.font below draws from the
	-- SAME two fonts for the SAME glyph and needs the opposite ORDER -- see the
	-- note there.
	config.font = wezterm.font_with_fallback({ "0xProto Nerd Font", "JetBrains Mono", "Noto Color Emoji" })

	-- ─── Science Gothic Mono, for `make` output ────────────────────────────────
	--
	-- Read straight out of the linked config directory rather than installed into
	-- the system font path. deps.conf links wezterm/fonts -> ~/.config/wezterm/fonts
	-- and config_dir follows the config file's own path, so this resolves on Linux,
	-- macOS and the Windows host identically -- with no fc-cache (which macOS does
	-- not have), no ~/Library/Fonts vs ~/.local/share/fonts split, and no chance of
	-- a stale copy elsewhere shadowing these. That last one is not hypothetical:
	-- two files claiming family "Science Gothic Mono" style "Regular" resolve by
	-- first match, and the loser is silently the wrong glyphs.
	config.font_dirs = { wezterm.config_dir .. "/fonts" }

	-- SGR 6 is "rapid blink". Setting the rate to 0 stops it animating, which
	-- frees the attribute to mean "draw this in the other font" -- see lib/sgr.sh,
	-- which is the only thing that emits it. Italic would have been the obvious
	-- carrier and is wrong: rose-pine italicises nvim's comments.
	--
	-- The 0 is load-bearing and verified against wezterm's renderer: screen_line.rs
	-- guards the whole blink animation behind `if blink_rate != 0`, so 0 is not
	-- "blink infinitely fast", it is "do not animate". Without it every line of
	-- `make` output flashes.
	--
	-- text_blink_rate (SGR 5, slow) is deliberately LEFT ALONE at its default.
	-- The two speeds are separate attributes with separate rate knobs, so
	-- silencing the rapid one keeps the slow one available as a real
	-- attention marker. Do not set it to 0 "for symmetry" -- that spends a
	-- channel this repo wants.
	--
	-- Science Gothic Mono is generated by wezterm/mkmono.py to 0xProto's exact
	-- 0.62em advance, so the two interleave on one grid with no drift; that is the
	-- entire reason a proportional display face can appear in a cell grid at all.
	-- 0xProto stays in the fallback for check/cross/box-drawing, which Science
	-- Gothic does not cover.
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
