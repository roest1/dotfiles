# Toolchain policy: one provider per tool, chosen by rule

**Status:** adopted 2026-11-07. Screening section is open.
**Applies to:** `deps.conf`, `lib/status.sh`, `.github/dependabot.yml`.

## The rule

Every `tool` line answers one question: **whose release stream do you want for this
tool?** There are three answers, tried in this order.

1. **The distro's, unpinned (`pkg`).** The default. Security fixes arrive as the
   distro's backports, into the version it already ships. Pinning would block exactly
   those fixes, and apt and dnf do not keep old versions around to pin to anyway. The
   cost is accepted: the version differs between Fedora, RHEL and Ubuntu.
2. **Upstream's, pinned (`mise`, recorded in `mise.toml` + `mise.lock`).** Only when a
   caller needs a version the distros don't reliably ship (nvim 0.12 against Ubuntu's
   0.9.5), or when no distro carries the tool at all (`qsv`, `stylua`,
   `lua-language-server`). The result is the same version on every machine, with a
   verified checksum.
3. **Something else (`uv`, `cargo`, `manual`).** Only when neither of the above can
   do the job. Examples: uv's distro build has `self update` compiled out; `tui/` is built from
   this tree; tree-sitter has to compile against RHEL 9's glibc 2.34.

A fallback after `||` must name the machine or condition that needs it, in a comment
above the line.

`deps.conf` already followed this rule before this file was written. Every chain that is
not `pkg`-first carries its own reason (`[bash]`'s header, nvim, tree-sitter, uv, qsv).
This file states the rule those comments were each applying, so the next tool is
placed by the rule rather than by analogy with a neighbor.

**"I'd like the same version everywhere" is not "a caller needs this version".** The
first draft of this policy moved `fzf` and `tree-sitter` to mise for uniformity, and both
moves were wrong. `fzf` has no caller with a version need (`CLAUDE.md`, the fzf
convention), and tree-sitter's `pkg||cargo||mise` order is the RHEL glibc case. Uniformity
is tier 2's *side effect*, not its entry criterion.

## Why mise, rather than a curl installer per tool

Measured 2026-11-09 against `fedora:44` and AlmaLinux 9.8 + EPEL (the work box's
point release): no distro in the fleet ships `bun`, `qsv`, `stylua` or
`lua-language-server`. RHEL 9 also lacks `eza`, `uv` and `ruff`, and its neovim is
0.8.0 against a 0.12 floor. Something has to install those, and the question is
only what.

A curl installer per tool would work, and mise is still the better answer, because
of what each curl line would lose:

- **The pin.** Most installers fetch latest. Pinning means a different flag or URL
  per tool, scattered across `deps.sh` files.
- **The checksum.** `curl | sh` runs whatever the server returns at that moment.
  `mise.lock` records a sha256 per platform, so a swapped release fails to install.
  That is the supply-chain half of the reason this repo pins anything. It holds only
  for backends that write a hash. Until 2026-11-09 neovim was locked through
  mise's registry default, a vfox plugin, which records a URL and no hash, so the
  one binary this repo depends on most was the one installed unchecked.
  `tools/gen-mise.sh` now pins such a tool under its `aqua:` backend
  (`"aqua:neovim"`, the same upstream tarball), and `--check` fails CI if
  any tool in `mise.lock` lacks a linux-x64 sha256. Verified with a tampered hash:
  `mise use -g` from the repo root refuses it.
- **One update route.** A bump is one line in `mise.toml` and `make mise-lock`, and
  Renovate can open that PR. Curl installers each have their own story: `bun
  upgrade`, `uv self update`, nothing at all for qsv.

mise is itself one curl install, so the trade is **one trusted installer in exchange
for many, and the tools become data**. It stays small on purpose: the tier-2 tools
above, and nothing the distro already serves.

## Applying a bump: pull, then `make install`

The workflow this repo is for is: a PR bumps a version, every machine pulls and
runs `make install`, and that machine now runs the bumped version. For mise tools
that did not hold until 2026-11-09. `mise_install` stopped at `command -v`, and the
version a mise tool runs comes from the *global* mise config, which only
`mise_install` writes. The Alienware's still said `neovim = "latest"`,
`qsv = "latest"` and `lua-language-server = "latest"`, from before pins existed.
Inside the repo the repo's `mise.toml` overrode them, which is why `make status`
(run from the repo) looked clean.

Now, when the global config lists a tool, `mise_install` compares the entry with
the pin. Any difference (value, backend key, or the pinned version missing from
disk) runs `mise use -g <pin>` from the repo root, so `mise.lock` is enforced. It
then retires the old entry with `mise unuse -g`, after the new one is in. A tool
the global config does not list is left alone: mise does not manage it on that
machine, and tier 1 says the distro's copy is fine. `make status` reports the same
comparison under `pins`.

What `make install` applies, by lane:

| Lane | Applied by `make install` |
| --- | --- |
| mise tools | yes, as above |
| `nvim/lsp-servers` (bun) | yes, `bun install --frozen-lockfile` on every run |
| `nvim/lazy-lock.json` | yes, `make -C nvim sync` |
| `tui/` crates | yes, `cargo install --locked --path` |
| distro packages | no: tier 1, the distro's own upgrade (`dnf upgrade`) |
| uv | no: `uv self update` |

uv is the exception that proves the rule. Its own installer is preferred over both
mise and `pkg` because only that build can `uv self update` (see `[uv]`).

## dnf: one key, never the file

`max_parallel_downloads=10` on every machine with dnf, set by `bash/deps.sh` through
dnf's own setter (`dnf config-manager setopt` on dnf5, `--save --setopt` on dnf4).
That edits the one key in place. CI asserts every other line of `dnf.conf` survives on
both dnfs, which matters on the work box, whose `dnf.conf` is not this repo's to
rewrite. `make status` reports the *effective* value, as dnf resolves it after any
drop-in.

It lives in `[bash]`, beside `ensure_wsl_interop`, rather than in a section of its
own. A section with no link and no tool is a section the `dots` console treats as
doing nothing, and no machine would opt out of this anyway.

## What is not a provider

**linuxbrew on a machine with apt or dnf.** `pkg_detect` reaches brew only when neither
exists, so on every real target `pkg` means apt or dnf. `provider_of` disagreed: it
answered `pkg` for any `Cellar` path, a leftover from when macOS made brew the system
package manager. Found on the Alienware's WSL guest, 2026-11-07: 11 declared tools,
five of them present *only* as Homebrew copies, all reading `✓ pkg`.

Now:

- a linuxbrew copy reports as `brew`, and no declaration accepts it;
- `manual`'s wildcard does not absorb it. zoxide is `pkg||manual`, and was the one
  tool still green.

CI asserts both, plus the `PM=brew` direction, where brew *is* `pkg`.

**Order matters when removing it: remove linuxbrew first, then `make install`.** The
reverse order looks safer and does nothing, because every installer short-circuits on
`command -v`, and the brew copies answer it. Removed from the Alienware 2026-11-09. The
inventory is in `~/.local/state/dotfiles/homebrew-removed-2026-11-09.txt` there.

`bash/bashrc` still evaluates `brew shellenv` where a brew binary exists, which
*prepends* linuxbrew to PATH. No machine in the fleet needs brew (Fedora, RHEL, and
Ubuntu until the WSL guest moves to Fedora), so brew support goes entirely in the same
change that drops apt.

## Known mismatches, not fixed here

- **shellcheck.** CI installs apt's (`ubuntu-latest`), while the local machine runs mise's
  pinned 0.11.0. A script can lint clean locally and fail in CI when the two versions
  disagree on a rule. Two ways to fix it: CI installs the mise pin, or the local machine
  uses `pkg`. Open.
- **ruff on the Alienware** is a standalone binary in `~/.local/bin` that is neither a
  uv tool nor a package. `make status` reports it. That is machine state, not repo state.

## Vulnerability screening (open)

GitHub's advisory database covers 12 language ecosystems and **no** deb or rpm
packages, so tier 1 above can never raise a Dependabot alert. That is the trade the
rule makes on purpose: the distro's security stream is tier 1's screen.

| Lane | Screened by | State |
| --- | --- | --- |
| `nvim/lsp-servers/yarn.lock` (bun's tree, regenerated) | Dependabot | working — see `.github/dependabot.yml` |
| `tui/Cargo.lock` | Dependabot | working, alerts and monthly version PRs (`cargo` in `dependabot.yml`) |
| GitHub Actions | Dependabot | working |
| `mise.toml` / `mise.lock` | Renovate (`renovate.json`), version bumps only | configured; needs the Renovate GitHub app on the repo. No advisory database covers these as CLI tools |
| distro packages | the distro | `dnf updateinfo --security` / `apt list --upgradable` |
| `nvim/lazy-lock.json` | nothing | no advisory database exists; pinned commits are the mitigation |

Every version PR, from either bot, waits for a release to be 7 days old
(`cooldown` in `dependabot.yml`, `minimumReleaseAge` in `renovate.json`, and
`SERVER_COOLDOWN` for `make -C nvim servers`). Security updates are exempt from
Dependabot's cooldown. Renovate touches only `mise.toml`, so the two bots never
propose the same bump. A Renovate PR that bumps `mise.toml` without
regenerating `mise.lock` fails `gen-mise.sh --check` until `make mise-lock`
runs on its branch. Hosted Renovate treats `mise lock` as an unsafe execution,
so expect to do that by hand.

Proposed, not decided:

- **`make audit`**, run locally on each machine: `syft` inventories installed packages
  and the Go/Rust libraries compiled into binaries; `grype` checks that inventory against
  distro trackers and NVD. It is the only lane that sees tier 1 and the libraries
  inside `fzf` and `gh`. The cost is two more tools in `deps.conf`.
- **Dependency submission of mise tools as PURLs (package URLs).** Rejected for now. Of
  the eight tools, only four map to an ecosystem GitHub tracks (`stylua`, `tree-sitter`
  and `qsv` as cargo, `fzf` as Go), and advisories against whole CLI programs are rare.
