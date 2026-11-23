# Contributing

This is a personal dotfiles repo that happens to be public. That shapes what's
useful to send.

## What's welcome

- **Fedora and RHEL fixes.** Something breaks on a Fedora or RHEL setup unlike
  mine. Those are the only targets; other distros are out of scope.
- **Bugs in the machinery** — the manifest parser, provider dispatch, drift
  detection, install/link logic.
- **Stale or wrong docs.** Including this file.

## What isn't

Anything that changes *my* preferences: keybindings, prompt design, aliases,
colors, which plugins are installed. Not because the suggestions are bad — it's
that "which editor shortcuts Riley likes" isn't a thing a PR can be right about.

**If you want a different setup, fork it.** That's the expected path for a
dotfiles repo, and the layout is built for it: everything installable lives in
`deps.conf`, so a fork mostly means editing one file.

## How it works, in 30 seconds

`deps.conf` is the single source of truth. It declares every config symlink and
every dependency:

```conf
[nvim]
link  nvim                  ~/.config/nvim
tool  mise||pkg    nvim  neovim
tool  mise||cargo  stylua
post  make -C nvim sync
```

The `Makefile` reads sections from that file — it does not know what a "bash" or
an "nvim" is. **Adding a program is a new section plus its config file, and no
other edits.** If you're editing the Makefile or `install.sh` to add a tool,
something has gone wrong.

Toggling is commenting. There's no flag, no profile, no `WITHOUT=`.

| Path | Role |
| ---- | ---- |
| `deps.conf` | the manifest |
| `lib/manifest.sh` | parses it |
| `lib/providers.sh` | maps a provider name to an installer; handles `\|\|` chains |
| `lib/pkg.sh` | the only implementation of "install a tool" |
| `lib/run.sh` | runs a section's tools, `post` steps, and platform fixups |
| `lib/status.sh` | drift detection — declared vs. actual |
| `tools/adopt.sh` | authoring aid: prints a manifest line for a command |
| `<section>/deps.sh` | optional escape hatch for genuinely conditional platform logic |

`nvim/` came from a separate repo (merged with full history) and keeps its own
`Makefile` and `README.md`, so it still stands alone.

## Adding a tool

Add a `tool` line to the right section:

```conf
tool  <provider>  <command>  [package]     # package defaults to command
```

Providers: `pkg` (system package manager), `mise`, `uv`, `cargo`, and
`manual`. Use `||` for fallbacks: `pkg||cargo eza`.

There is no `npm` provider. It was removed once nothing could reach it — the
`nvim` CI job rejects any `npm` line in `deps.conf`, so the
dispatcher case, the installer, the global-prefix setup and the provenance
detection were all unreachable. JavaScript tools go in
`nvim/lsp-servers/package.json` and run under `bun`.

`./tools/adopt.sh <command>` writes the line for you — it resolves the provider
and the package name, which is the part that's easy to get wrong (`rg` is
`ripgrep`, `fd` is `fd-find`, `clangd` is `clang-tools-extra`). It prints
rather than edits; choosing the section is yours.

Three rules, each of which exists because breaking it caused a real bug here:

1. **Don't add install logic outside `lib/pkg.sh`.** One implementation of
   "install a tool", reused by every provider. Every helper short-circuits on
   `command -v`, which is what makes tools declared in two sections (`rg`, `fd`)
   safe to install once.

2. **Never key provider choice on `$PM`.** Use a `||` chain. The package manager
   is a proxy for facts it can't see: this repo once ran `cargo_install
   tree-sitter` whenever `$PM = dnf`, justified by RHEL 9's glibc — and so spent
   minutes compiling on Fedora, which ships `tree-sitter-cli` and a newer glibc.
   `pkg||mise` asks the question directly instead of guessing.

3. **`manual` installs nothing.** It declares that an official installer or an
   extracted build is an acceptable source, so `make status` doesn't flag a
   correct state as drift. The real install goes in the section's `deps.sh`.

   `[uv]` is the one place `manual` means "prefer the official installer"
   rather than "`pkg` couldn't serve this". The distro build has `uv self
   update` compiled out, so it is pinned to the distro's release cadence
   against a tool that ships weekly. Note the shape of the fix: the preference
   lives in `ensure_uv`, not in a `||` chain, because chains are tried before
   any `deps.sh` runs — `manual||pkg` would install the distro copy first and
   never reach the installer it is meant to prefer.

Genuinely conditional logic — dnf needing `clang-devel` for bindgen, a
clipboard backend picked by display server — belongs in
`<section>/deps.sh`, not in the manifest. Don't invent an `if` syntax for a
config file.

## Before you open a PR

```sh
make test      # Lua unit tests — no plugins, no network
make link      # then run it again: the second run must change nothing
make check     # enabled tools present
make status    # declared state vs. actual machine
```

And lint, which CI enforces:

```sh
shellcheck --severity=warning bootstrap.sh install.sh lib/*.sh */deps.sh tools/*.sh
# no shellcheck? use the container:
podman run --rm -v "$PWD":/mnt:Z -w /mnt docker.io/koalaman/shellcheck:stable \
  --severity=warning bootstrap.sh install.sh lib/*.sh */deps.sh tools/*.sh
```

CI groups its jobs by pillar, so a component that moves to its own repo takes its
jobs with it. Only `ci ok` is required to merge; it fails unless every job passed,
or was skipped on a docs-only PR.

| Job | Proves |
| --- | --- |
| `shellcheck` | The whole tree lints clean; no secrets, credentials or home paths are tracked |
| `engine` | deps.conf, make, linking, sections, plugins and `make status` behave |
| `link only (…)` | The no-sudo, no-network path works and is idempotent, on Fedora 45, RHEL 9 and 10 |
| `install (…)` | `make install bash` and `uv` complete on the same three |
| `bash`, `2* conversions`, `uv` | The shell configs, `h`, and the converters |
| `nvim (docs, servers under bun)` | The help matches the config; no node/npm/pip; every server completes an LSP handshake |
| `neovim floor (…)` | Exactly one nvim, at or above 0.12, on RHEL 9 |
| `bun audit (transitive advisories)` | No known advisories in the language-server tree |
| `wezterm`, `tui (rust)`, `claude`, `git-autofetch` | Each pillar's own checks |

The audit also runs daily on a schedule, and everything runs on Mondays. An
advisory published on a quiet day should not wait for a push. It is the only job
that can go red with no change to the repo; the fix is a version bump or an
`--ignore` entry with its reason, not deleting the job.

## Invariants

Please don't break these. Each is load-bearing:

- **`make link` requires no sudo and no network.** It's the path for a machine
  where you can't install anything. Keep it symlinks-only.
- **`[bash]` stays installable without `mise`, `node`, or a curl-piped
  installer.** It's the section that has to work on a locked-down box. This is
  what moved `uv` out to `[uv]`: it stopped being a `pkg` line, and anything
  needing curl cannot sit here. Don't move it back — `2parquet`, `2feather`
  and `2pickle` guard on `command -v uv` precisely so `[bash]` doesn't have to
  own it.
- **The bootstrap must work on a bare machine.** Nothing on the critical path may
  assume a runtime that `deps.conf` hasn't installed yet.
- **The JS language servers must keep their `bun` cmd prefix.** Six servers are
  npm packages whose bin shims carry `#!/usr/bin/env node`. Running them as
  `bun <path>` is the entire reason this repo never installs node. Lose that
  prefix and they break only on machines without node — the exact machine the
  design exists for. `nvim/tests/lsp_servers_spec.lua` asserts it, and
  `nvim/lsp-servers/verify.ts` proves it with a real LSP handshake.
- **No `node` shim, ever.** Aliasing `node` to bun would make any
  incompatibility surface as an error blaming the wrong tool.
- **`wezterm/wezterm.lua` declares a `mux` unix domain** that an external project
  connects to by name. Don't replace it with a stock config.

## Style

- Shell: bash, `set -euo pipefail` in scripts, shellcheck-clean at
  `--severity=warning`.
- Lua: `stylua` (config in `nvim/.stylua.toml`).
- Comments should say **why**, not what. The repo leans on this heavily — most
  of the non-obvious lines have a note explaining the bug that put them there.
- Commit messages: explain the reasoning, not just the change. If you fixed
  something subtle, the next person needs to know what it was.

## License

MIT — see [LICENSE](LICENSE). Contributions are accepted under the same terms.
