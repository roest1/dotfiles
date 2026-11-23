# wezterm/ — the terminal

`deps.conf` links `wezterm.lua` and `fonts/` one by one into `~/.config/wezterm/`, so this
file never reaches that directory. The code comments in `wezterm.lua` are the detailed
reference; this is what to know before changing it.

## `wezterm.lua` is load-bearing beyond wezterm

It declares the `mux` unix domain that the Jarvis sidecar connects to
(`JARVIS_WEZTERM_DOMAIN` defaults to `'mux'` in `jarvis-ui/server/workerSession.ts`).
Don't replace it with a stock config.

It is one file. `shared.lua` was split out for a Windows entry point and folded back in on
2026-11-23, once that entry point was gone.

## Science Gothic Mono is generated, not downloaded

`wezterm/mkmono.py` (PEP 723, run by `make mono-font`, same arrangement as `mise.toml`)
derives a monospaced cut from upstream's variable Science Gothic, and the two `.ttf` files
it writes are committed under `wezterm/fonts/`. A fresh machine builds nothing. It exists
because a terminal is a fixed grid and Science Gothic is proportional: its `m` wants 0.99em
against a 0.62em cell while its `l` wants 0.30em, so raw Science Gothic collides and gaps.
It works in the tab bar only because that is proportional text laid out proportionally.

**The fonts are read via `font_dirs`, never installed into the system font path.**
`deps.conf` links `wezterm/fonts` → `~/.config/wezterm/fonts` and the config says
`wezterm.config_dir .. "/fonts"`. No `fc-cache`, no system font directory, and — the real
reason — no chance of a stale copy elsewhere shadowing it. Two files claiming family
`Science Gothic Mono` style `Regular` resolve by first match, and the loser is silently the
wrong glyphs. That already happened once during development and cost an afternoon.

**The two `.ttf` files are OFL, not MIT, and `LICENSE` carves them out explicitly.** That
is required, not tidy: OFL 1.1 §5 says the font must be distributed *entirely* under the
OFL and under no other licence, so a repo-wide MIT grant would conflict.
`wezterm/fonts/OFL.txt` is the standalone copy, and `mkmono.py` deliberately preserves name
IDs 0/13/14 (upstream copyright and licence) — don't "clean up" those fields. Upstream
declares **no** Reserved Font Name, which is the only OFL clause that would have restricted
the derivative's name, so `Science Gothic Mono` is permissible. CI asserts both the licence
file and the carve-out survive.

## The blink attribute is fully spent — both halves

wezterm can pick a font by SGR attribute (`font_rules`) and can set a blink rate to zero,
which turns blink into a spare bit meaning "draw this in the other font". **SGR 6** (rapid
blink) is Science Gothic Mono for `make` output, written by `lib/sgr.sh` (see
`lib/CLAUDE.md`). **SGR 5** (slow blink, `text_blink_rate = 0`) is the file you are editing
in nvim, written by `nvim/lua/external/altfont.lua` (see `nvim/CLAUDE.md`).

There is no third carrier and there is not going to be one: everything else wezterm can
match a font on — intensity, italic, underline, reverse, strikethrough — *means* something
on screen, and blink was only available because the rate can be set to zero. So do not
reach for a blink attribute for anything else, and do not assume an SGR 5 in a capture is a
bug. Both writers use the same three-condition guard, because outside WezTerm running this
config both are blinking text.

The four lanes are `shell`, `nvim.ui`, `nvim.editor` and `claude`. `nvim.ui` is NOT "oil" —
oil is the most visible thing it draws, but the lane is the window's base font while nvim
holds focus, so it is also telescope, the statusline, the gutter and every float. Which
font each lane gets is picked by `font` (`tui/font`) and written to
`~/.config/wezterm/fonts.conf` — machine-local, not linked, not in `deps.conf`, same footing
as `~/.bash_local`. Details: `wezterm.lua` for the lanes, `nvim/CLAUDE.md` for the writer,
`tui/CLAUDE.md` for the picker.

## A symptom is a stale-process question first

`wezterm --config <name>=<value> start` opens a window with that value forced, independent
of any file, symlink or reload — so it separates "the setting does not work" from "this
process never read the setting" in one command. It settled a multi-hour hunt in which
`text_blink_rate_rapid = 0` appeared to be ignored: the value was correct and the running
GUI predated it.

Two corollaries worth reaching for before reading any renderer source. `wezterm ls-fonts`
prints the file each rule resolved to, which is the only way to tell a correct config from a
font shadowed by a system-installed copy of the same family. And a running wezterm does not
pick up a pulled config: a tab switch is not a reload, and the file watcher does not
reliably follow a symlink, so `pkill -x wezterm-gui` is part of the test rather than an
afterthought.

The asymmetry that makes this bite: wezterm **warns** when a `font_rule` cannot be matched,
and says **nothing** when a fallback resolves. A wrong-but-valid font is silent by design.
