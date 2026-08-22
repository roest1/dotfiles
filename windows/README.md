# Windows

Configures wezterm on the **Windows host**. If you use WSL, this is the other
half of the install — run it from PowerShell, and run `bootstrap.sh` from inside
your distro. They configure two different environments.

`make install` inside WSL knows this: it links the wezterm config in the guest
but installs no wezterm and no fonts there, and `make check` reports the binary
as `n/a (Windows host)` rather than MISSING. The terminal is out here.

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

```powershell
start ms-settings:developers
```

That lands on **Settings → System → Advanced**, which carries both toggles this
repo cares about. Windows 10 files the same page under *Privacy & security*,
which is why the URI is given rather than a menu path.

| Toggle | Section on that page | |
| --- | --- | --- |
| **Developer Mode** | For developers | **Required** — see below |
| **Enable sudo** | Terminal | Optional — only the admin entry in the picker uses it |

`sudo.exe` ships in System32 on Windows 11 24H2+ **whether or not the feature is
enabled**, so the presence of the binary proves nothing. Enable it here first,
then see [Elevation](#elevation) for the second step that makes it elevate in
the current pane instead of a new window.

Creating a symlink on Windows is a privileged operation. Without Developer Mode
you need an elevated shell, and `install.ps1` doesn't want one — it should be
able to set up your account without touching the machine.

Developer Mode alone is not quite enough, and this is the part that surprises:
**Windows PowerShell 5.1's `New-Item -ItemType SymbolicLink` fails anyway**, with
*"Administrator privilege required for this operation"*, because it never passes
the flag that Developer Mode exists to honour. PowerShell 7's version does — so
it works when you test it in pwsh and fails for everyone pasting the bootstrap
line into the shell a fresh box opens. `install.ps1` therefore falls back to
`cmd`'s `mklink`, which does pass the flag and does work unprivileged.

Only if *both* routes are denied does the script **copy the file instead** and
say so. That works, but the copy stops tracking the repo: editing
`wezterm-windows.lua` no longer changes your live config until you re-run the
install. Turn Developer Mode on and re-run to get the link back.

## Staying up to date

**From WSL, which is where you already are:**

```bash
make windows
```

That finds the host clone under `/mnt/c/Users/*/dotfiles`, switches it to `main`,
pulls, and runs `install.ps1` — through WSL's Windows interop, so there is
nothing to install and no path to type. It is the counterpart to the `[windows]`
line in `make status`, which is what tells you it is needed:

```
[windows] host clone
  ✗ [out of date]  main @ c3a580c — origin/main is d66eeb2
```

It refuses rather than guessing if that clone has real local changes. Line-ending
churn is not "real": a clone made before `.gitattributes` pinned `eol=lf` holds
CRLF, and the script renormalizes that on its own.

**From Windows, if you would rather:**

```powershell
irm https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.ps1 | iex
```

The same line that installs a fresh machine also updates one. `bootstrap.ps1`
pulls when the clone already exists and then hands off to `install.ps1`, so
there is no separate update command to remember.

**Why the long `powershell -NoProfile -ExecutionPolicy Bypass -File ...` form
exists at all:** Windows client machines default to a `Restricted` execution
policy, which refuses to run a `.ps1` file. The `irm | iex` pipe sidesteps it
because piped text is not a script file. If you would rather run the script
directly, lift the restriction once for your account:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

After that `.\windows\install.ps1` works on its own. `RemoteSigned` still
blocks unsigned scripts *downloaded* from the internet; a git clone carries no
mark-of-the-web, so this repo's scripts run.

**Whichever route, `install.ps1` has to run — a `git pull` alone is not enough.**
The pull moves files; only the installer creates a link or installs a font that
the update added. Skipping it is how the host ended up without `shared.lua`,
without JetBrainsMono, and with a tab bar in the wrong face — each time looking
like a wezterm bug.

A running wezterm does **not** pick up a pulled config on its own. After
updating, close every wezterm window and relaunch — see Troubleshooting for how
to tell a stale process from a bad config.

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
  Uncomment its line in `windows/install.ps1` and re-run.

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

So: two clones, one on each side of the boundary — and two declarations, not
one. `deps.conf` describes the Unix side and nothing else; the Windows payload
lives in the `$Links` and `$WingetTools` tables at the top of `install.ps1`,
which reads no manifest at all. There is no `[windows]` section and no
`platform` line type; CI rejects both. The reasoning for that reversal is in
`install.ps1`'s own header and in the note under `[wezterm]` in `deps.conf`.

## Troubleshooting

**"running scripts is disabled on this system"** — Windows client machines
default to a `Restricted` execution policy. The bootstrap one-liner sidesteps it
(piped text isn't a script file), but running `install.ps1` directly needs:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\install.ps1
```

**Git says every file is modified, and the diff is all `^M`** — a one-time
consequence of Git for Windows' `core.autocrlf=true`, which checked this clone
out with CRLF before `.gitattributes` pinned `eol=lf`. Nothing was edited; the
guest's git and the host's git just disagree about what the file says. Settle
the working tree once:

```powershell
git add --renormalize .; git checkout -- .
```

This matters beyond tidiness: everything in `lib/`, `install.sh` and
`*/deps.sh` runs under bash, where a CRLF shebang is a syntax error.

**Something in wezterm ignores the config — wrong font, blinking text, stale
colors.** Before theorizing, prove whether the running process has your config
at all. wezterm takes overrides on the command line, independent of any file,
symlink, or reload:

```powershell
wezterm --config text_blink_rate_rapid=0 start
```

If the new window behaves and your existing one doesn't, the config is fine and
the *process* is stale — wezterm was launched before the change, and a tab
switch won't reload it. Kill it properly:

```powershell
Get-Process wezterm* | Stop-Process -Force
```

Then relaunch from the Start menu. This single test replaced several hours of
guessing at wezterm's renderer; reach for it first.

**A font resolves to the wrong file** — `ls-fonts` prints what each rule
actually resolved to, including the path, which is the only way to tell a
correct config from a shadowed font file:

```powershell
wezterm ls-fonts
wezterm ls-fonts --list-system | Select-String "Science"
```

Two files claiming the same family win by first match, and the loser is
silently the wrong glyphs. If a face resolves anywhere other than
`.config\wezterm\fonts`, a system-installed copy is shadowing the repo's.

**The font looks wrong after an update** — `deps.ps1` installs 0xProto Nerd
Font, JetBrainsMono Nerd Font and Science Gothic per-user, but already-running
apps keep the font list they started with. Restart wezterm. A missing font is
cosmetic, but note it is not always announced: wezterm warns when a `font_rule`
cannot be matched, and says nothing at all when a *fallback* resolves — which
is how the tab bar rendered in the wrong face for a week.

**`winget` not found** — install "App Installer" from the Microsoft Store.

**wezterm isn't in the Start menu** — it should be: the winget package wraps
wezterm's Inno Setup installer, which is the same machine-wide install you'd get
from `setup.exe`, PATH entry and shortcut included. wezterm is not distributed on
the Microsoft Store, so there's no second place to install it from.
