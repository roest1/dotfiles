# Contributing

This is a personal dotfiles repo that happens to be public. That shapes what's
useful to send.

## What's welcome

- **Portability fixes.** Something breaks on a distro or platform I don't run —
  Arch, Alpine, macOS on Apple Silicon, WSL quirks. This is the most valuable
  kind of PR, because I can only test what I have.
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
tool  pkg   nvim      neovim
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
| `lib/adopt.sh` | generates manifest lines (`make adopt`) |
| `<section>/deps.sh` | optional escape hatch for genuinely conditional platform logic |

`nvim/` came from a separate repo (merged with full history) and keeps its own
`Makefile` and `README.md`, so it still stands alone.

## Adding a tool

Add a `tool` line to the right section:

```conf
tool  <provider>  <command>  [package]     # package defaults to command
```

Providers: `pkg` (system package manager), `mise`, `npm`, `uv`, `cargo`, and
`manual`. Use `||` for fallbacks: `pkg||cargo eza`.

`make adopt <command>` writes the line for you — it resolves the provider and the
package name, which is the part that's easy to get wrong (`rg` is `ripgrep`, `fd`
is `fd-find`, `prettierd` is `@fsouza/prettierd`). It prints rather than edits;
choosing the section is yours.

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

Genuinely conditional logic — apt naming `fd` as `fdfind`, dnf needing
`clang-devel` for bindgen, probing `/proc/version` for WSL — belongs in
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
shellcheck --severity=warning bootstrap.sh install.sh lib/*.sh */deps.sh
# no shellcheck? use the container:
podman run --rm -v "$PWD":/mnt:Z -w /mnt docker.io/koalaman/shellcheck:stable \
  --severity=warning bootstrap.sh install.sh lib/*.sh */deps.sh
```

CI additionally runs `make link` on Ubuntu and macOS, full installs across
apt/brew/dnf, manifest validation, and a job that comments out the node block to
prove the editor degrades rather than breaking.

## Invariants

Please don't break these. Each is load-bearing:

- **`make link` requires no sudo and no network.** It's the path for a machine
  where you can't install anything. Keep it symlinks-only.
- **`[bash]` stays installable without `mise`, `node`, or a curl-piped
  installer.** It's the section that has to work on a locked-down box.
- **The bootstrap must work on a bare machine.** Nothing on the critical path may
  assume a runtime that `deps.conf` hasn't installed yet.
- **`lsp.lua` must keep the node gate.** Six language servers are JavaScript and
  can't run without a JS runtime; dropping them when `node` is absent is what
  makes a node-free install produce a working editor instead of Mason failing on
  every startup. `nvim/tests/node_gate_spec.lua` covers it.
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
