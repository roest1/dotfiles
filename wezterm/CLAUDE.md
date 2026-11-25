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

## Science Gothic Mono comes from roest1/fonts

`fonts/` is the [roest1/fonts](https://github.com/roest1/fonts) submodule: a monospaced cut
of the proportional Science Gothic at 0xProto's 0.62em advance, generated there by
`mkmono.py` and committed, with its OFL and the CI that checks it. A fresh machine builds
nothing. To change the font, change roest1/fonts, then bump the pin here, as with `ps1/`.

The same submodule installs every other font. `deps.sh` hands a list of family names to
`fonts/install.sh`, which looks each one up in the submodule's `catalog/` and downloads it
into `~/.local/share/fonts`. This repo says which families; roest1/fonts says where they
come from. A family `wezterm.lua` names has to be in `deps.sh`'s `FONTS` list and in the
catalogue, and CI checks both. To add one, add its catalogue file there first, bump the
pin, then name it here.

**The fonts are read via `font_dirs`, never installed into the system font path.**
`deps.conf` links `wezterm/fonts` → `~/.config/wezterm/fonts` and the config says
`wezterm.config_dir .. "/fonts"`. No `fc-cache`, no system font directory, and — the real
reason — no chance of a stale copy elsewhere shadowing it. Two files claiming family
`Science Gothic Mono` style `Regular` resolve by first match, and the loser is silently the
wrong glyphs. That already happened once during development and cost an afternoon.

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
font each lane gets is picked by `theme` (`tui/theme`, roest1/theme-tui) and written to
`~/.config/dotfiles/theme.conf` — machine-local, not linked, not in `deps.conf`, same footing
as `~/.bash_local`. Details: `wezterm.lua` for the lanes, `nvim/CLAUDE.md` for the writer,
`tui/CLAUDE.md` for the picker.

## theme.conf: one file, two readers

`theme` writes every pick to `~/.config/dotfiles/theme.conf`, keyed by lane and then by what
is set: `shell.font`, `shell.colors`, `shell.opacity`, `nvim.editor.colors`. `wezterm.lua`
reads the fonts and the three `shell` keys; `nvim/lua/external/theme.lua` reads the nvim
colors. Both skip a line they cannot read and ignore a key they do not know.

- **A theme is nine colors in `wezterm/themes/<name>.conf`**, linked to
  `~/.config/wezterm/themes`. `shell.colors` names one. It is the terminal's background and
  the tab bar and nothing else: the ANSI 16 are still left alone, for the reason given over
  `config.colors`. That has a cost on the two lighter backgrounds: wezterm's default ANSI
  blue (`#5555cc`) is 2.99:1 on rose-pine's base, which is why that base was chosen, and
  2.41:1 on Dracula's and 2.37:1 on One Dark's. Directory names and `gh`'s blue are harder to
  read there. A theme file has no key to fix that with, on purpose, until someone wants one.
- **A theme is whole or it is not applied.** A file missing a color, or holding something
  that is not `#rrggbb`, leaves the default palette. Half of one theme over half of another
  is worse than the default.
- **The default palette is a table in `wezterm.lua`, not `themes/rose-pine.conf`**, so the
  terminal has its colors before the directory is linked. The file exists for `theme` to list
  and preview. `wezterm/tests/theme_spec.lua` holds the two to each other.
- **`~/.config/wezterm/fonts.conf` is still read**, underneath `theme.conf`. It is where the
  fonts lived, keyed by bare lane name, until 2026-11. A machine keeps its fonts between
  pulling and rebuilding `theme`; the first pick with the new `theme` moves them and removes
  the file. Take the fallback out once no machine has one.
- **`make test` runs the reader** against a stand-in for the `wezterm` module, because
  wezterm cannot be asked what a config evaluated to. The cases are the files a machine can
  really have. A new key read from `theme.conf` gets a case there.

## The icon font is a fallback, and a window holds its font as an override

Material Icon Theme (`fonts/MaterialIconTheme.ttf`, built in roest1/fonts) is named at the
end of every fallback chain whenever the file is there. `icons = material` in `theme.conf`
is NOT what puts it there: that key decides who prints the characters (`ls`, nvim), and
`theme` has to be able to show the set before it is picked.

- **`assume_emoji_presentation = false`, or it is never drawn from.** wezterm takes a color
  font for an emoji font and uses one only for a character with emoji presentation, which a
  private-use code point never has. `wezterm ls-fonts` lists the font as found and `--text`
  on an icon still says no font has the glyph.
- **`scale = 1.2`, and no more.** The icons already fill their square (the median one spans
  89% of it), so a small icon is not the font's to fix: the square is one em beside a
  25px line. wezterm lets a glyph run over one neighboring cell when that cell is a space, and
  two cells of a monospace face are about 1.2em. Past that it shrinks the glyph to fit, and a
  bigger number draws a smaller icon. Scaled, an icon covers the space after it, so whoever
  prints one puts two spaces before the name.
- **It is in `FONTS_SIG`, with its scale.** Every window holds its font as an override
  (`apply_overrides`), built from `with_fallback` and cached against that signature. The
  first time the font was tried it was not in the signature: the reload that added it
  matched the cache, the window kept the chain it had, and every icon was an empty box until
  focus happened to cross into another lane. Anything `with_fallback` adds goes in the
  signature.
- **The file's path is watched**, so the font arriving with a pull of the submodule is a
  reload. Nothing else wezterm watches changes then.

`wezterm/tests/theme_spec.lua` covers all four, the override through a stand-in window.

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
