local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

-- ─── Shared body ─────────────────────────────────────────────────────
--
-- Fonts, the SGR 6 carrier and the rose-pine surfaces live in shared.lua, which
-- wezterm-windows.lua loads too. Only what is genuinely per-platform stays here:
-- the `mux` unix domain (a guest socket path), the Claude tab-title handler, the
-- GNOME-specific window_decorations, and this file's keys.
--
-- dofile with an explicit path rather than require: wezterm's package.path is
-- not something to depend on, and config_dir resolves to the LINKED directory on
-- both platforms, where deps.conf and windows/install.ps1 put shared.lua next to
-- this file. It also resolves when running straight from the repo checkout,
-- since the two files are siblings there as well.
--
-- pcall, because a hard failure here would take the WHOLE config down and leave
-- you at wezterm's defaults with no tab bar and no clue why. Degrading to an
-- unstyled but working terminal, with the reason in the debug overlay
-- (CTRL+SHIFT+L), is the better failure.
local ok, shared = pcall(dofile, wezterm.config_dir .. "/shared.lua")
if ok and shared then
	shared.apply(config)
else
	wezterm.log_error("wezterm: shared.lua did not load (" .. tostring(shared) .. ") — run `make link wezterm`")

	-- A REAL palette, not `{}`. format-tab-title paints its own cells with
	-- shared.palette.base/surface/overlay/muted, so an empty table hands wezterm
	-- `{ Background = { Color = nil } }` on every repaint -- which is not a
	-- degraded tab bar, it is a broken one, and the only trace is a log line in
	-- an overlay nobody opens.
	--
	-- These are rose-pine main's surfaces, the same values shared.lua carries.
	-- Duplicated deliberately and ONLY here: the whole point is to be correct
	-- when the file holding them could not be read.
	shared = {
		palette = {
			base = "#191724",
			surface = "#1f1d2e",
			overlay = "#26233a",
			highlight_med = "#403d52",
			text = "#e0def4",
			muted = "#6e6a86",
			subtle = "#908caa",
		},
	}
end

-- Bound once here rather than reached for as shared.X at each use: the
-- update-status handler runs on every repaint, and this is also the only place
-- that has to cope with shared.lua having failed to load. `or` defaults rather
-- than bare reads, because a nil base_face inside an event handler is a runtime
-- error on every keystroke -- far worse than the unstyled-but-working terminal
-- the pcall above is buying.
local FONTS = shared.FONTS or {}
local FONTS_SIG = shared.FONTS_SIG or ""
local base_face = shared.base_face
	or function(family)
		return wezterm.font_with_fallback({ family or "JetBrains Mono" })
	end

-- apply_font asks the same question format-tab-title does -- is this pane
-- Claude? -- and they must agree, or a pane wears the status glyph in one font
-- and the base lane in another. One definition, in shared.lua, bound here.
-- Falsy fallback rather than nil: with shared.lua unreadable there is no font
-- state to act on anyway, and returning false keeps the handler running instead
-- of erroring on every repaint.
local is_claude_pane = shared.is_claude_pane or function()
	return false
end

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

-- Tab titles moved to shared.lua so the Windows host gets them too; see the
-- note there. Registered explicitly rather than folded into apply(), because
-- this one installs event handlers rather than setting config keys.
if shared.claude_tab_titles then
	shared.claude_tab_titles()
end

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
	-- same font, which `font` lets you do and which costs nothing until now.
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
