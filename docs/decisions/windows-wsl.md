# Dropping Windows, WSL and Ubuntu

**Status:** done, 2026-11-21.
**Applies to:** the Windows host installer, the WSL guest/host split, every apt
branch, and linuxbrew as a provider.

## Why

Every machine now runs Fedora Workstation or RHEL. The Alienware, the only
Windows host and the only WSL guest, moved to Fedora. That left a lot of code
paid for by a platform nobody runs. About a third of the root `CLAUDE.md`'s
footguns described PowerShell 5.1, binfmt interop, LX symlinks or winget exit
codes. CI ran a `windows-latest` job and an Ubuntu install leg for every PR.
macOS left the same way on 2026-10-26 ([`macos.md`](macos.md)).

## What went

- **Windows host:** `windows/` (`install.ps1`, `deps.ps1`, `README.md`),
  `bootstrap.ps1`, `wezterm/wezterm-windows.lua`, `tools/windows-update.sh`,
  `make windows`, and the `windows` CI job.
- **WSL:** `is_wsl`, `ensure_wsl_interop` and the `/etc/binfmt.d/WSLInterop.conf`
  rule. Also `make status`'s `[windows] host clone` and `[wsl] interop` blocks,
  the `/mnt/` wrong-clone guard in the Makefile, the wezterm-in-the-guest skip
  (`tool_applies_here wezterm`, `wezterm/deps.sh`), `theme show`'s `host` state,
  nvim's `explorer.exe` opener and PowerShell `:PasteImage` backend, the WSL
  OSC52 branch (SSH keeps it), and `downloads`.
- **apt / Ubuntu:** `apt_pkg_name`, the `apt-cache` pre-check, `ensure_symlink`
  (it only served `fdfind`/`batcat`), the `batcat`/`fdfind` fallbacks in
  `make check`, `dpkg` provenance, and the `ubuntu / apt` CI legs.
- **linuxbrew:** `PM=brew`, and `brew shellenv` in `bashrc`. A Homebrew copy
  found on a machine is still reported as provider `brew`, which nothing
  accepts.
- **Dead code found on the way:** `pip_install`, which had no callers. This
  repo installs no pip.

## What stayed

- `wezterm/shared.lua` stayed a separate file at first, so that this change only
  deleted code. It was folded back into `wezterm.lua` on 2026-11-23.
- `.gitattributes`' `eol=lf` and the `_netrc` secret pattern cost nothing and
  still guard against a file arriving from a Windows-configured git.
- TypeScript's `win32` platform map in `lsp_servers.lua`. It is data, not a
  support claim, and its unit test covers it.

## Getting it back

Everything is in git history before this change. The Windows installer's hard
lessons were in the root `CLAUDE.md` footguns, so read that version before
rebuilding anything:

- PowerShell 5.1 is not pwsh 7.
- A `.ps1` file must be pure ASCII.
- `New-Item -ItemType SymbolicLink` fails under 5.1 even with Developer Mode
  on, so fall back to `mklink`.
- winget's `0x8A15002B` exit code means "already installed", not a failure.
- `sudo.exe` being present is not the same as sudo being enabled.
