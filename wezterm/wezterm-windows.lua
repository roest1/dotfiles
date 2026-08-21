-- ─── wezterm.exe on WINDOWS ──────────────────────────────────────────────────
--
-- NOT a variant of wezterm.lua — a different job. wezterm.lua configures
-- wezterm running natively ON Linux/macOS and declares the `mux` unix domain
-- the Jarvis sidecar attaches to, whose socket path is a Linux path that means
-- nothing to wezterm.exe. This file configures the Windows HOST terminal, whose
-- job is to drop you into WSL and, when you need it, into PowerShell or cmd.
--
-- This file is NOT symlinked out of ~/dotfiles inside WSL. It can't be: the WSL
-- filesystem isn't visible to wezterm.exe in a way it will load a config from,
-- and `ln -s` run inside WSL onto /mnt/c writes an LX symlink that Windows
-- refuses to follow. windows/install.ps1 links it from the Windows side, where
-- a symlink is a thing Windows understands. See windows/README.md.
--
-- Windows loads it from %USERPROFILE%\.config\wezterm\wezterm.lua.

local wezterm = require("wezterm")
local act = wezterm.action
local config = wezterm.config_builder()

-- ─── Shared body ─────────────────────────────────────────────────────────────
--
-- Fonts, the SGR 6 carrier and the rose-pine surfaces live in shared.lua, which
-- the Linux entry point loads too. They used to be copied into this file by
-- hand, with a comment admitting it -- and the copy had already fallen behind:
-- there was no tab_bar block here at all, so the host's tab bar sat at wezterm's
-- default grey above a themed pane.
--
-- windows\install.ps1 links shared.lua next to this file, exactly as it links
-- the fonts directory, so config_dir finds it. Nothing here is Linux-specific:
-- the fonts come from the linked font_dirs, not the system font store.
--
-- pcall, because a hard failure would take the WHOLE config down -- no launcher,
-- no CTRL+SHIFT+O, no WSL default domain -- and leave you guessing. Degrading to
-- an unstyled but working terminal, with the reason in the debug overlay
-- (CTRL+SHIFT+L), is the better failure.
local ok, shared = pcall(dofile, wezterm.config_dir .. "/shared.lua")
if ok and shared then
	shared.apply(config)
	-- The Claude session glyphs. The guest emits the OSC 1337 user var and this
	-- host reads it, so the only reason this never worked on Windows is that it
	-- lived in the Linux entry point.
	if shared.claude_tab_titles then
		shared.claude_tab_titles()
	end
else
	wezterm.log_error("wezterm: shared.lua did not load (" .. tostring(shared) .. ") — re-run windows\\install.ps1")
end

-- ─── What's actually on this machine ─────────────────────────────────────────
--
-- Probing the filesystem rather than hardcoding paths, because every one of
-- these is genuinely optional: PowerShell 7 is a separate install, and native
-- sudo only exists on Windows 11 24H2+.
--
-- io.open, not run_child_process: wezterm evaluates this file several times per
-- process and warns against side effects in it. Opening a file for read is not
-- one; spawning three shells to ask where they live would be.
local function exists(path)
	local handle = io.open(path, "r")
	if handle then
		handle:close()
		return true
	end
	return false
end

local system_root = os.getenv("SystemRoot") or "C:\\Windows"
local program_files = os.getenv("ProgramFiles") or "C:\\Program Files"

local pwsh = program_files .. "\\PowerShell\\7\\pwsh.exe"
if not exists(pwsh) then
	-- Windows PowerShell 5.1 ships with the OS and cannot be missing, so this
	-- fallback is total: the launcher never contains an entry that can't run.
	pwsh = "powershell.exe"
end

-- wezterm cannot elevate a pane on its own. UAC returns a process at a higher
-- integrity level than the mux, and spawning wezterm-gui.exe from an elevated
-- context attaches to the existing UNelevated instance (wezterm#7660) — so the
-- tab comes back not-admin without saying so, which is the worst outcome
-- available. Both helpers below elevate in place instead.
local elevator
if exists(system_root .. "\\System32\\sudo.exe") then
	-- Windows 11 24H2+. Opens a NEW WINDOW until `sudo config --enable normal`
	-- is run from an admin console; `normal` is what makes it inline.
	elevator = system_root .. "\\System32\\sudo.exe"
elseif exists(program_files .. "\\gsudo\\current\\gsudo.exe") then
	elevator = "gsudo.exe"
end

-- ─── Domains ─────────────────────────────────────────────────────────────────
--
-- default_wsl_domains() shells out to `wsl -l -v` and returns one domain per
-- installed distro, named "WSL:<distro>". Taking it wholesale rather than
-- hand-writing the Ubuntu entry means a distro added later shows up in the
-- launcher without editing this file.
config.wsl_domains = wezterm.default_wsl_domains()

-- The exact name depends on how the distro registered itself — "WSL:Ubuntu" on
-- a Store install, "WSL:Ubuntu-24.04" on a versioned one. Matching a prefix
-- instead of hardcoding avoids wezterm failing to start with an unknown-domain
-- error on a machine where it's the versioned name.
local ubuntu
for _, domain in ipairs(config.wsl_domains) do
	if domain.name:find("WSL:Ubuntu", 1, true) == 1 then
		ubuntu = domain.name
		break
	end
end

-- Without this, wezterm opens %COMSPEC% (cmd.exe). Ubuntu is the shell this
-- machine actually lives in, so it's the one a bare new tab should get. Falls
-- back to the local domain on a box where WSL isn't installed at all, rather
-- than naming a domain that doesn't exist and failing to start.
config.default_domain = ubuntu or "local"

-- ─── Launcher ────────────────────────────────────────────────────────────────
--
-- `domain` is what makes these entries mean anything: a launch_menu entry with
-- no domain inherits the CURRENT pane's domain, so "Command Prompt" chosen from
-- a WSL tab would try to run cmd.exe inside Ubuntu. Pinning each one is the
-- difference between switching environments and just launching programs.
local menu = {
	{ label = "WSL · Ubuntu", domain = { DomainName = ubuntu or "local" } },
	{
		label = "PowerShell",
		args = { pwsh, "-NoLogo" },
		domain = { DomainName = "local" },
	},
	{
		label = "Windows PowerShell 5.1",
		args = { "powershell.exe", "-NoLogo" },
		domain = { DomainName = "local" },
	},
	{
		label = "Command Prompt",
		args = { "cmd.exe" },
		domain = { DomainName = "local" },
	},
}

-- Omitted rather than shown-and-broken when there's no elevator installed.
-- A menu entry that reliably fails teaches you to distrust the menu.
if elevator then
	table.insert(menu, {
		label = "PowerShell (Admin)",
		args = { elevator, pwsh, "-NoLogo" },
		domain = { DomainName = "local" },
	})
end

config.launch_menu = menu

-- CTRL+SHIFT+O is unbound in wezterm's defaults, so this costs nothing.
-- TABS and WORKSPACES are in the flags deliberately: the same key both switches
-- to a shell already open and spawns one that isn't, which is how you actually
-- think about it. Without them this would only ever spawn duplicates.
config.keys = {
	{
		key = "O",
		mods = "CTRL|SHIFT",
		action = act.ShowLauncherArgs({
			title = "shells",
			flags = "FUZZY|LAUNCH_MENU_ITEMS|TABS|WORKSPACES",
		}),
	},
}

return config
