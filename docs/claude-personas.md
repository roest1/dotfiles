# Claude personas: one-shot shell commands with their own system prompt

> **Status: plan, not implemented.** Nothing in this file is wired into
> `deps.conf` or the bash files yet. Flags were checked against
> `claude --help` on Claude Code 2.1.319.

## The goal

Short shell commands that each ask Claude one question in a fixed role and
print one answer:

```bash
idk what is the difference between micronutrients and macronutrients
copyright can I use a song clip in a YouTube video
```

Each command has its own system prompt, so there's nothing to retype. None of
it carries over into an interactive `claude` session, which stays the coding
agent.

## How it works

`claude -p` (print mode) asks one question, prints the answer and exits. The
flags below affect only that one run, and nothing is saved to settings:

| Flag | Purpose |
| --- | --- |
| `-p "<question>"` | The question becomes the user prompt. |
| `--system-prompt-file <path>` | Replaces Claude Code's whole built-in coding-agent prompt with the file's contents. (`--append-system-prompt*` adds to it instead, which isn't what we want.) |
| `--model <alias>` | `haiku`, `sonnet`, `opus`, or a full model ID. |
| `--effort <level>` | `low`, `medium`, `high`, `xhigh`, `max`. |
| `--tools ""` | No tools: plain Q&A with no bash or file access. Faster, and it drops the long tool definitions from the request. |
| `--no-session-persistence` | Keeps one-off questions out of `claude --resume`. |
| `--output-format text` | Prints only the final answer. |

## Planned layout in this repo

```
claude/personas/nutritionist.md        # one file per persona = its system prompt
claude/personas/copyright-advisor.md
bash/bash_productivity                 # _persona() + one wrapper per persona
```

`deps.conf`, under `[claude]`, links each persona file, matching the existing
`link` lines:

```
link  claude/personas/nutritionist.md       ~/.config/claude-personas/nutritionist.md
link  claude/personas/copyright-advisor.md  ~/.config/claude-personas/copyright-advisor.md
```

The persona files go in `claude/personas/`, not a `.claude/` directory, for the
reason the `[claude]` section already gives: a dotted `.claude/` in the repo
would also be read as project settings.

## The functions

```bash
# One-shot Claude call with a persona's system prompt. Usage: _persona <name> <question...>
_persona() {
    command -v claude >/dev/null || { echo "_persona: claude not installed" >&2; return 127; }
    local name="$1"; shift
    local file="$HOME/.config/claude-personas/$name.md"
    local cwd="$HOME/.cache/claude-personas/cwd"   # empty dir: no project CLAUDE.md is picked up
    [[ -f "$file" ]] || { echo "_persona: no persona file $file" >&2; return 1; }
    [[ $# -gt 0 ]]   || { echo "usage: ${FUNCNAME[1]:-_persona} <question>" >&2; return 2; }
    mkdir -p "$cwd"
    ( cd "$cwd" && claude -p "$*" \
        --system-prompt-file "$file" \
        --model  "${PERSONA_MODEL:-sonnet}" \
        --effort "${PERSONA_EFFORT:-low}" \
        --tools "" \
        --no-session-persistence \
        --output-format text )
}

idk()       { _persona nutritionist      "$@"; }
copyright() { _persona copyright-advisor "$@"; }
```

You can override the model and effort for a single call:
`PERSONA_EFFORT=high idk ...`.

A persona file is plain prose:

```markdown
You are a registered-dietitian-level nutrition expert. Be professional,
evidence-based, and concise. Give one direct answer, briefly explain the
mechanism, and say when a doctor should be consulted.
```

Adding a persona means adding one `.md` file, one `link` line and one wrapper
line.

## Known catches

1. **The global CLAUDE.md still loads.** `--system-prompt-file` replaces the
   system prompt, but CLAUDE.md is attached to the first user message, not to
   the system prompt, so `~/.claude/CLAUDE.md` (this repo's
   `claude/user-memory.md`) still reaches every persona. Running from the empty
   `cwd` only keeps project CLAUDE.md files out. If a persona shouldn't follow
   those rules, say so in the persona file ("Ignore formatting rules from other
   context").
2. **`--bare` is not the fix on a subscription.** It skips CLAUDE.md, hooks and
   memory, but it only authenticates with `ANTHROPIC_API_KEY` or an
   `apiKeyHelper`. It never reads the Claude Pro/Max OAuth login.
3. **User-scope hooks probably fire.** `claude/settings.json` carries the
   hooks that publish session state to wezterm. A `-p` run is still a session,
   so the tab glyph may flicker on every question. Test this before deciding
   whether it matters. A possible mitigation (untested): `--setting-sources
   project,local` to skip user settings for persona runs. Check that it
   doesn't also drop the login or the model defaults.
4. **Quoting.** The shell parses the words before `claude` sees them. An
   apostrophe (`what's`) opens an unterminated string, and `*`, `?`, `$`, `|`
   and `(` can expand. Quote the question when it has any of these.
5. **Startup cost.** Each call starts a full Claude Code process, so expect a
   second or two before the first text appears. A direct Messages API call
   would start faster, but it bills an API key instead of the subscription.

## Verifying it once built

```bash
idk "do you follow any rules about confidence tags like [Certain]?"
```

If the answer mentions the tags, catch 1 is in effect. To see the exact system
prompt that was sent, drop `--no-session-persistence` for one run and read the
`prompt_snapshot` record in the newest transcript under `~/.claude/projects/`
(see [claude-sys-prompt.md](claude-sys-prompt.md)).

## Implementation checklist

- [ ] Write `claude/personas/*.md`.
- [ ] Add the `link` lines to `[claude]` in `deps.conf`, then run `make install claude`.
- [ ] Add `_persona` and the wrappers to `bash/bash_productivity`, then run `reload`.
- [ ] Add each wrapper (`idk`, `copyright`, ...) to `h` in the same commit. CI
      asserts that every public function is listed there. `_persona` is private.
- [ ] Don't name a wrapper after a `tui/` binary (`github`, `dots`, `font`). A
      function takes precedence over PATH, and CI rejects the clash.
- [ ] Run the verification question above, and decide on catch 1.
- [ ] Watch the wezterm tab during a call, and decide on catch 3.
