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

local wezterm = require 'wezterm'
local act = wezterm.action
local config = wezterm.config_builder()

-- Same font as the Linux config, but nothing here installs it — wezterm/deps.sh
-- runs under bash. windows/deps.ps1 is what puts it on this machine; until then
-- the fallback chain quietly uses JetBrains Mono.
config.font = wezterm.font_with_fallback { '0xProto Nerd Font', 'JetBrains Mono' }

-- ─── Science Gothic Mono, for `make` output ──────────────────────────────────
--
-- Kept in sync with wezterm.lua BY HAND, like the colours below, and for the
-- same reason: this file is never symlinked out of the repo.
--
-- This one is easy to think is unnecessary. `make` runs in the WSL guest, but
-- the guest only writes an escape sequence — wezterm.exe out here is what
-- draws it. Without these rules the output arrives as SGR 6 with no font
-- attached to it, and 'rapid blink' is exactly what it would then mean.
--
-- windows\install.ps1 links wezterm\fonts alongside this config, and
-- config_dir follows the config file's own path, so the same expression works
-- on both sides.
config.font_dirs = { wezterm.config_dir .. '/fonts' }
config.text_blink_rate = 0
config.text_blink_rate_rapid = 0
config.font_rules = {
	{
		blink = 'Rapid',
		intensity = 'Bold',
		font = wezterm.font_with_fallback {
			{ family = 'Science Gothic Mono', weight = 'Bold' },
			'0xProto Nerd Font',
		},
	},
	{
		blink = 'Rapid',
		font = wezterm.font_with_fallback {
			{ family = 'Science Gothic Mono', weight = 'Regular' },
			'0xProto Nerd Font',
		},
	},

	-- ─── SGR 5: the file you are editing in nvim ─────────────────────────
	--
	-- The same argument as the block above, one attribute over, and it is even
	-- easier to talk yourself out of because nvim feels further away than
	-- `make` does. It is not: nvim runs in the WSL guest and emits SGR 5 over
	-- file buffers (nvim/lua/external/altfont.lua), and wezterm.exe out here is
	-- what draws it. Leave these rules out and every source file you open
	-- through this config BLINKS.
	--
	-- nvim's own guard does not save you either. It checks TERM_PROGRAM and a
	-- linked ~/.config/wezterm/fonts, and inside WSL under wezterm.exe both are
	-- true — it is asking "is this wezterm with the repo's fonts linked", and
	-- on this path the honest answer is yes.
	--
	-- Four rules for the reason the Linux config gives at more length: a
	-- font_rule REPLACES the face for a matching cell, so bold and italic have
	-- to be rebuilt here or they are silently dropped.
	--
	-- Static family names rather than a picked one, which is the one place this
	-- file deliberately does less than its Linux twin: `font` writes its state
	-- into the WSL guest's home, and that is not a path this side can read. The
	-- host gets the defaults, which is fine at the point where you are looking
	-- at the shell that gets you into WSL rather than editing in it.
	{
		blink = 'Slow',
		intensity = 'Bold',
		italic = true,
		font = wezterm.font_with_fallback {
			{ family = 'JetBrainsMono Nerd Font', weight = 'Bold', style = 'Italic' },
			'JetBrains Mono',
		},
	},
	{
		blink = 'Slow',
		intensity = 'Bold',
		font = wezterm.font_with_fallback {
			{ family = 'JetBrainsMono Nerd Font', weight = 'Bold' },
			'JetBrains Mono',
		},
	},
	{
		blink = 'Slow',
		italic = true,
		font = wezterm.font_with_fallback {
			{ family = 'JetBrainsMono Nerd Font', style = 'Italic' },
			'JetBrains Mono',
		},
	},
	{
		blink = 'Slow',
		font = wezterm.font_with_fallback {
			{ family = 'JetBrainsMono Nerd Font' },
			'JetBrains Mono',
		},
	},
}

-- ─── Colors ──────────────────────────────────────────────────────────────────
--
-- Kept in sync with wezterm.lua BY HAND, and it has to be: this file is never
-- symlinked out of the repo (see the header), so there is no shared source for
-- the two to read. If you retune the colours there, retune them here.
--
-- The ANSI 16 are left alone for the same reason as the Linux config — the
-- shell inside WSL is the same bash, with the same 256-colour prompt and the
-- same gh/git output, and remapping the slots would re-tint all of it. This
-- sets the window chrome only, which is what makes the two hosts look like one
-- terminal.
-- Literal hex for the same reason as the Linux config: reading the value from
-- wezterm.color.get_builtin_schemes() costs ~24ms per config evaluation, and
-- this file is evaluated several times per process.
config.colors = {
  foreground = '#e0def4',
  background = '#191724',
  cursor_bg = '#e0def4',
  cursor_fg = '#191724',
  cursor_border = '#e0def4',

  -- The builtin's selection_bg equals its background, which renders a selection
  -- invisible; this is rose-pine main's "highlight med" instead.
  selection_fg = '#e0def4',
  selection_bg = '#403d52',
}

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
  local handle = io.open(path, 'r')
  if handle then
    handle:close()
    return true
  end
  return false
end

local system_root = os.getenv 'SystemRoot' or 'C:\\Windows'
local program_files = os.getenv 'ProgramFiles' or 'C:\\Program Files'

local pwsh = program_files .. '\\PowerShell\\7\\pwsh.exe'
if not exists(pwsh) then
  -- Windows PowerShell 5.1 ships with the OS and cannot be missing, so this
  -- fallback is total: the launcher never contains an entry that can't run.
  pwsh = 'powershell.exe'
end

-- wezterm cannot elevate a pane on its own. UAC returns a process at a higher
-- integrity level than the mux, and spawning wezterm-gui.exe from an elevated
-- context attaches to the existing UNelevated instance (wezterm#7660) — so the
-- tab comes back not-admin without saying so, which is the worst outcome
-- available. Both helpers below elevate in place instead.
local elevator
if exists(system_root .. '\\System32\\sudo.exe') then
  -- Windows 11 24H2+. Opens a NEW WINDOW until `sudo config --enable normal`
  -- is run from an admin console; `normal` is what makes it inline.
  elevator = system_root .. '\\System32\\sudo.exe'
elseif exists(program_files .. '\\gsudo\\current\\gsudo.exe') then
  elevator = 'gsudo.exe'
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
  if domain.name:find('WSL:Ubuntu', 1, true) == 1 then
    ubuntu = domain.name
    break
  end
end

-- Without this, wezterm opens %COMSPEC% (cmd.exe). Ubuntu is the shell this
-- machine actually lives in, so it's the one a bare new tab should get. Falls
-- back to the local domain on a box where WSL isn't installed at all, rather
-- than naming a domain that doesn't exist and failing to start.
config.default_domain = ubuntu or 'local'

-- ─── Launcher ────────────────────────────────────────────────────────────────
--
-- `domain` is what makes these entries mean anything: a launch_menu entry with
-- no domain inherits the CURRENT pane's domain, so "Command Prompt" chosen from
-- a WSL tab would try to run cmd.exe inside Ubuntu. Pinning each one is the
-- difference between switching environments and just launching programs.
local menu = {
  { label = 'WSL · Ubuntu', domain = { DomainName = ubuntu or 'local' } },
  {
    label = 'PowerShell',
    args = { pwsh, '-NoLogo' },
    domain = { DomainName = 'local' },
  },
  {
    label = 'Windows PowerShell 5.1',
    args = { 'powershell.exe', '-NoLogo' },
    domain = { DomainName = 'local' },
  },
  {
    label = 'Command Prompt',
    args = { 'cmd.exe' },
    domain = { DomainName = 'local' },
  },
}

-- Omitted rather than shown-and-broken when there's no elevator installed.
-- A menu entry that reliably fails teaches you to distrust the menu.
if elevator then
  table.insert(menu, {
    label = 'PowerShell (Admin)',
    args = { elevator, pwsh, '-NoLogo' },
    domain = { DomainName = 'local' },
  })
end

config.launch_menu = menu

-- CTRL+SHIFT+O is unbound in wezterm's defaults, so this costs nothing.
-- TABS and WORKSPACES are in the flags deliberately: the same key both switches
-- to a shell already open and spawns one that isn't, which is how you actually
-- think about it. Without them this would only ever spawn duplicates.
config.keys = {
  {
    key = 'O',
    mods = 'CTRL|SHIFT',
    action = act.ShowLauncherArgs {
      title = 'shells',
      flags = 'FUZZY|LAUNCH_MENU_ITEMS|TABS|WORKSPACES',
    },
  },
}

return config
