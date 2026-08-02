# JavaScript language servers

The six JS-based language servers this config uses, installed with **bun** and
run with **bun**. No node, no npm, anywhere in the chain.

```sh
bun install --cwd nvim/lsp-servers    # what deps.conf's [nvim] post step runs
```

## Why they live here instead of in Mason

Mason installs npm packages by shelling out to `npm`, which only exists if node
is installed. This repo's whole dependency story is bun and uv, so Mason was the
one thing forcing node onto every machine.

Tracking them in a `package.json` instead buys three things Mason couldn't:

- **Pinned in `bun.lock`**, in the repo, reviewable in a diff. Mason's versions
  live in `~/.local/share/nvim/mason` where nothing watches them.
- **Dependabot sees them.** `bun.lock` is supported under the `npm_and_yarn`
  ecosystem, so version bumps arrive as PRs.
- **One package manager.** `deps.conf` already declares every other dependency;
  language servers were the exception.

## Four packages, six servers

| Package                        | Provides                                        |
| ------------------------------ | ----------------------------------------------- |
| `typescript-language-server`   | `ts_ls` (+ `typescript`, its peer)              |
| `bash-language-server`         | `bashls`                                        |
| `yaml-language-server`         | `yamlls`                                        |
| `vscode-langservers-extracted` | `jsonls`, `cssls`, `html`                       |

## Invocation is explicit, and differs per server

`lsp.lua` runs each one as `bun <path> <args>`. There is deliberately **no
`node` shim** — routing `node`/`npm` calls to bun silently would turn any
incompatibility into a confusing error attributed to the wrong tool. If bun
can't run something, the error should say bun.

The arguments are not uniform, so each was verified rather than assumed:

| Server                              | Args      |
| ----------------------------------- | --------- |
| `typescript-language-server`        | `--stdio` |
| `yaml-language-server`              | `--stdio` |
| `vscode-json-language-server`       | `--stdio` |
| `vscode-css-language-server`        | `--stdio` |
| `vscode-html-language-server`       | `--stdio` |
| **`bash-language-server`**          | **`start`** — rejects `--stdio` |

All six were confirmed to complete a real LSP `initialize` handshake under bun
with `node` and `npm` absent from `$PATH`.

## Notes

- Bun blocks a `core-js` postinstall (a donation banner). Harmless — nothing
  here depends on it running.
- `typescript` is a direct dependency because `typescript-language-server` needs
  a `tsserver` to drive; pinning it here keeps that explicit rather than
  inherited.
- Native-binary servers — `clangd`, `lua_ls`, `lemminx` — are **not** here.
  They aren't JavaScript and come from `deps.conf` via `pkg` / `mise`.
