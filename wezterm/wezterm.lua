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
	shared = { palette = {} }
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

-- ─── Tab titles: Claude Code session state ───────────────────────────
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

	-- A gh-tui session, which announces itself over the same user-var channel
	-- (bash/bash_github_tui's `_gh_tab_var`).
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
	local is_claude = busy or pane_title:find(CLAUDE_IDLE, 1, true) ~= nil or proc:find(CLAUDE_PROC, 1, true) ~= nil

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
		-- Above the Claude branches because gh-tui is a foreground program you
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
				Color = hover and shared.palette.overlay
					or (tab.is_active and shared.palette.base or shared.palette.surface),
			},
		},
		{ Attribute = { Intensity = "Normal" } },
		{ Foreground = { Color = shared.palette.muted } },
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
wezterm.on("format-window-title", function(tab)
	local name = tab.tab_title
	local status = tab.active_pane and tab.active_pane.title or ""
	if name and #name > 0 then
		return status ~= "" and (name .. "  —  " .. status) or name
	end
	return status ~= "" and status or "wezterm"
end)

return config
