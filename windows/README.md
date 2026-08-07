# Windows

Configures wezterm on the **Windows host**. If you use WSL, this is the other
half of the install — run it from PowerShell, and run `bootstrap.sh` from inside
your distro. They configure two different environments.

```powershell
irm https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.ps1 | iex
```

Clones to `%USERPROFILE%\dotfiles`, links the config, and installs wezterm with
winget. Already cloned? `.\windows\install.ps1`.

| | |
| --- | --- |
| `.\windows\install.ps1` | links + winget tools |
| `.\windows\install.ps1 -LinkOnly` | symlinks only — no network, no installs |
| `$env:DOTFILES_DIR = 'D:\src\dotfiles'` | clone somewhere else (set before the pipe) |

## Turn on Developer Mode first

**Settings → System → For developers → Developer Mode.**

Creating a symlink on Windows is a privileged operation. Without Developer Mode
you need an elevated shell, and `install.ps1` doesn't want one — it should be
able to set up your account without touching the machine.

If symlink creation is denied, the script **copies the file instead** and says
so. That works, but the copy stops tracking the repo: editing
`wezterm-windows.lua` no longer changes your live config until you re-run the
install. Turn Developer Mode on and re-run to get the link back.

## What you get

`CTRL+SHIFT+O` opens a fuzzy picker over every shell:

| | |
| --- | --- |
| WSL · Ubuntu | the default for new tabs |
| PowerShell | pwsh 7 if installed, else Windows PowerShell |
| Windows PowerShell 5.1 | always present |
| Command Prompt | |
| PowerShell (Admin) | only when an elevation helper exists — see below |

The picker also lists tabs and workspaces you already have open, so the same key
switches to a shell that's running instead of spawning a second one.

New tabs open in Ubuntu, not `cmd.exe`. The distro is detected from `wsl -l -v`
at startup, so `Ubuntu-24.04` works as well as `Ubuntu`, and a distro you install
later shows up without editing anything.

## Elevation

**wezterm cannot elevate a pane.** UAC hands back a process at a higher
integrity level than the multiplexer, and launching `wezterm-gui.exe` from an
elevated context just attaches to the running unelevated instance
([wezterm#7660](https://github.com/wezterm/wezterm/issues/7660)) — so you get a
tab that looks like admin and isn't, which is worse than no tab at all. The
admin entry therefore elevates *in place*, via one of:

- **`sudo`** — ships in Windows 11 24H2+. Enable at Settings → System → For
  developers → Enable sudo. It opens a **new window** until you also run
  `sudo config --enable normal` from an admin console; `normal` is the mode that
  runs elevated in the current pane.
- **`gsudo`** — works on Windows 10 and elevates inline with no mode change.
  Uncomment its line in `deps.conf` and re-run.

With neither installed the entry is omitted rather than shown broken.

## Why this config isn't shared with WSL

`wezterm/wezterm.lua` and `wezterm/wezterm-windows.lua` are separate files that
both install to `~/.config/wezterm/wezterm.lua` — in two different homes. That
isn't duplication to be cleaned up:

- **The Linux config can't run here.** It declares a `unix_domains` socket under
  `$XDG_RUNTIME_DIR` for the Jarvis mux server, which is a Linux path for a
  process running inside WSL. On Windows it means nothing.
- **The Windows config can't live in your WSL clone.** wezterm's maintainer:
  *"The WSL filesystem isn't directly visible on the Windows host, so that isn't
  possible"* ([discussion #2400](https://github.com/wezterm/wezterm/discussions/2400)).
  Pointing `--config-file` or `WEZTERM_CONFIG_FILE` at `\\wsl.localhost\...`
  doesn't work.
- **And you can't symlink across.** `ln -s` run inside WSL onto `/mnt/c` writes
  an *LX symlink* — a reparse point Windows fails on with
  `STATUS_IO_REPARSE_TAG_NOT_HANDLED`. The link has to be made from the Windows
  side, pointing at a path on `C:`, which is exactly what `install.ps1` does.

Ordinary file *writes* from WSL to `/mnt/c` are fine. It's specifically symlinks
that don't cross.

So: two clones, one on each side of the boundary. `deps.conf` stays the single
source of truth for both — `[windows]` declares `platform windows`, which makes
it invisible to `install.sh` and the only thing `install.ps1` looks at.

## Troubleshooting

**"running scripts is disabled on this system"** — Windows client machines
default to a `Restricted` execution policy. The bootstrap one-liner sidesteps it
(piped text isn't a script file), but running `install.ps1` directly needs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\install.ps1
```

**The font looks wrong** — `deps.ps1` installs 0xProto Nerd Font per-user, but
already-running apps keep the font list they started with. Restart wezterm. If
it still doesn't take, the fallback to JetBrains Mono is cosmetic only.

**`winget` not found** — install "App Installer" from the Microsoft Store.

**wezterm isn't in the Start menu** — it should be: the winget package wraps
wezterm's Inno Setup installer, which is the same machine-wide install you'd get
from `setup.exe`, PATH entry and shortcut included. wezterm is not distributed on
the Microsoft Store, so there's no second place to install it from.
