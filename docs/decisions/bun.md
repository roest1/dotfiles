# Bun manages packages; Node runs the tools

**Status:** adopted 2026-11-16 as "remove node", revised 2026-11-17 after it broke
a project, and again 2026-11-25 when apt was gone: node is installed per machine
from the distro's packages; nvim still needs none.
**Applies to:** every JS project on these machines, `nvim/lsp-servers/`, `bunfig.toml`.

## The split

| job | tool | notes |
| --- | --- | --- |
| install / add / remove packages | `bun install`, `bun add`, `bun add -d` | `bun.lock` is the lockfile. npm, pnpm and yarn are not used anywhere. |
| run a package.json script | `bun run <script>` | bun starts the script; the *tool* inside it picks its own runtime (below). |
| runtime for third-party tooling | **node** | anything whose bin starts `#!/usr/bin/env node`: vite, astro, wrangler, tsc, prettier, eslint. `bun run` already hands these to node when node is on PATH. That is the behavior we want. |
| runtime for your own scripts | bun | `bun scripts/foo.ts`, with no build step and no ts-node. |
| one-off command (scaffold, init) | `bunx <pkg>@<version>` | `bunx create-vite`, `bunx tsc --init`. Pin a version when the result must be reproducible. |
| tool a project runs repeatedly | `bun add -d <pkg>` | then call it from a script. It is in the lockfile, so `bun audit` sees it. |
| global CLI on this machine | mise, or `bun add -g` | prefer mise (pinned and checksummed, see `toolchain-policy.md`). `bun add -g` is unpinned. |

**`bunx` is not an install.** It fetches whatever the registry serves at that moment
and runs it from a cache, so it never appears in a lockfile. That is fine for a
one-off and wrong for anything a project depends on. **In this repo it is `bun`,
never `bunx`**: every JS tool nvim needs is declared in `nvim/lsp-servers/package.json`
and run as `bun <path>`, so audit, the Socket scan and the `yarn.lock` mirror describe
the tree that actually runs.

## Why node stays

The first version of this doc removed node on the premise that "nothing this repo
runs depends on it." That held for dotfiles. It did not hold for the machine.
Reproduced 2026-11-17 in `portfolio`:

- Astro 7 declares `engines.node >=22.23.4`, and apt's node is 18.19.1, so `bun run dev`
  refused to start. Bun was not at fault: `astro`'s bin is `#!/usr/bin/env node`.
- Forcing Astro onto bun (`bun --bun run dev`) printed `ws.WebSocket 'upgrade' event is
  not implemented in bun` (the socket Vite's live reload uses) and never served the page.

Astro, Vite and Cloudflare's dev tooling are built and tested against node. Bun's node
compatibility is good but incomplete, and when it falls short the failure blames the
wrong tool. That is the same argument as the shim rule below. **Bun's speed is in
installs, and installs are where it is used.**

## Installing node: the distro's package

Revised 2026-11-25. The 2026-11-17 version of this section said mise, never the
distro, and its case was one number: Ubuntu 24.04's apt carried node 18 against a ≥22
floor, which is how a tool reaches tier 2 in `toolchain-policy.md` ("not reliably
carried"). apt support was dropped on 2026-11-21 ([`windows-wsl.md`](windows-wsl.md)),
and the number went with it. Fedora 44 packages node 22 and 24 (`nodejs22`,
`nodejs24`). So node is tier 1, like everything else the distro carries, and the
Fedora machine was already running it that way with no node in mise.

- **dnf**, with the cost tier 1 always has: the version is the distro's. On
  2026-11-25 Fedora's `nodejs22` was 22.23.1, a patch release under the 22.23.4 that
  Astro 7 asks for. `nodejs24` clears it, and is what `node` means on that machine.
- **A project that needs a version the distro does not carry** pins node in its own
  `mise.toml` (`mise use node@<x>` in that directory), and mise switches when you `cd`
  into it. That is tier 2 doing its job for one project, not a second global node.
- **nvm, fnm, Vite+** are each a second version manager beside mise, which recreates
  the problem `tool-duplication.md` documents.
- **Docker** fits a deployed service, not a dev server you edit live.

RHEL has not been checked against the ≥22 floor. The second bullet is the answer if
its package falls short.

Node ships npm. It stays installed and unused, and nothing calls it.

**Node is machine state, not a dotfiles dependency, and that is deliberate.** nvim must
not need node, and CI's "deps.conf declares no node, npm or pip" guard keeps it that way.
So node is installed by hand on a machine that runs JS projects
(`sudo dnf install nodejs24`) and is not declared in `deps.conf`. The cost: a new
machine has no node until you run that line, and the version can differ between
machines.

### History: the Ubuntu box, 2026-11-17

Before apt was dropped, node went onto the Alienware WSL box through mise
(`mise use -g node@26`), and apt's copy came out so that nothing on PATH shadowed it:

```bash
sudo apt remove nodejs npm && sudo apt autoremove
type -a node   # expect only the mise path
```

`apt remove nodejs npm && apt autoremove` removed 425 packages. Most were Debian's
node module packages (`node-*`, `libjs-*`) and apt's own node 18, npm 9, eslint 6, webpack,
terser and handlebars, none of which anything here uses. The full list with versions is in
`~/.local/state/dotfiles/apt-node-removed-2026-11-17.txt` on that machine.

Four were not node, and went only because node's dev packages had pulled them in:

| package | what it gave you | when you'd notice | restore |
| --- | --- | --- | --- |
| `libnotify-bin` (+ `libnotify4`) | `notify-send` | **`alert` in `bash/bashrc` now fails** with `notify-send: command not found` | `sudo apt install libnotify-bin` |
| `libssl-dev` | OpenSSL C headers | building something that links OpenSSL: a Rust crate using `openssl-sys`, `pyenv`/mise compiling Python | `sudo apt install libssl-dev` |
| `libuv1-dev` | libuv C headers | compiling a native libuv binding (rare) | `sudo apt install libuv1-dev` |

The other machines in the fleet still have whatever their distro installed alongside
node. Check them before assuming this table applies to them.

## No node shim, including `bunfig.toml` `[run] bun = true`

That setting "prepends `$PATH` with a `node` symlink that points to the `bun` binary,"
so it *is* a node shim, forbidden for the reason above. Prettier's `--stdin-filepath`
exits 0 and writes nothing under bun. Behind a shim that reads as "the tool is broken,"
not "this is bun." The setting is also only read from a project-local `bunfig.toml`;
`~/.bunfig.toml` is ignored for `bun run`.

Existing ones: `mdgest/bunfig.toml` sets it only to dodge node 18 being older than
Vite 8 needs. Delete it once node ≥22 is installed.

## Revisit when

Astro and Vite list bun as a supported dev runtime, not just a package manager. Until
then, bun installs and node runs.
