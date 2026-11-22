# lib/ — the engine

`manifest.sh` parses `deps.conf`, `providers.sh` maps a provider to an installer and walks
`||` chains, `pkg.sh` is the only implementation of "install a tool", `run.sh` runs a
section, `status.sh` compares the machine with the manifest, `plugins.sh` runs other repos
through the same engine. The rules for using them are in the root `CLAUDE.md`; what follows
is what you need before editing the two escape files and the status font block.

## `make status`'s font block

The font block is the one part that admits a limit rather than answering. It
reports what a program can prove — the files are where `font_dirs` points, and
what `wezterm ls-fonts` actually resolved the family to — and then runs
`font show`, whose carrier prints real SGR 6 and SGR 5 text for the half only an
eye can read. **Only the provable half counts as drift**, because the carrier is
unreadable over ssh, in a pipe and on any other terminal, and counting it would
report red on machines that are fine. This replaced a `wezterm/MIN_VERSION`
floor that inferred render-time behavior from a build stamp; don't restore it,
for the reason in `wezterm/deps.sh` — a floor cannot fail safe, so every build
above it passed untested and the silent failure survived inside a green tick.

## `sgr.sh`: the Science Gothic Mono carrier (SGR 6)

`make` output is rendered in Science Gothic Mono, and the carrier is `SGR 6`.
`lib/sgr.sh` is the only thing that emits it, and every escape it defines is empty
unless **all three** of `[ -t 1 ]`, `TERM_PROGRAM=WezTerm`, and a linked
`~/.config/wezterm/fonts` hold. That guard is not belt-and-braces; each condition is a
different failure. Without the tty half, escapes reach a pipe — and CI itself greps
`make check bash | tee`. Without the WezTerm half, SGR 6 means what it actually says on
every other terminal: **rapid blink**, over ssh, in GNOME Terminal, in a plain console. And being
*in* WezTerm still isn't enough, because WezTerm only honours the attribute if this
repo's config is the live one — on a machine that hasn't run `make link`, or one
pointed at a stock config, it blinks again. The linked font directory is the cheapest
true proxy for that, since `deps.conf` links config and fonts together. All three
directions are asserted in the `manifest` CI job, because none of them is visible to
whoever writes the code — they're always in WezTerm, always on a tty, always linked.

Italic looks like the obvious carrier and is wrong: rose-pine italicises nvim's
comments, so the whole editor would silently change font. Why blink is the only
attribute available, and why there is no third carrier: `wezterm/CLAUDE.md`.

## `tty.sh`: escapes that need a terminal, not a particular one

**`lib/tty.sh` is the sibling file, and the split between them is the guard,
not the feature.** It holds the escapes that need a terminal but
nothing about *which* terminal — the green/red/yellow marks in `make status`,
and the decrypt animation on `make help`'s banner. Green means green and `\r`
means `\r` everywhere, where SGR 6 means *rapid blink* off this setup.

So the two files ask different questions. `sgr.sh` asks "is this WezTerm,
running our config". `tty.sh` asks "is this a terminal at all, and does its
owner want decoration" — a tty, `TERM` not `dumb`, and `NO_COLOR` unset.
**`NO_COLOR` is tested for being SET, not for being non-empty**: the spec says
any value including the empty string means no, and `[ -n "$NO_COLOR" ]` is
exactly how that gets missed. CI asserts the empty case on its own for that
reason. `TERM=dumb` is the value defined as having no capabilities, so CSI
lands in it as literal text — an animation there is not a degraded effect,
it is garbage.

The animation is gated on `NO_COLOR` too, which reads past the letter of a
spec that only governs color. It is right anyway: the banner is decoration by
exactly the argument `NO_COLOR` is making, and someone who asked for less has
not asked for more. `TTY_ANIM` is computed separately from the color block so
the two can diverge if that turns out to be wrong. Folding the two together would have put two
different guarantees behind one set of variables whose header promises "empty
unless all three hold", and a caller could no longer tell which it was getting.

The cost is real and worth naming: the CI row that used to assert **no escape
at all** reaches a non-wezterm tty can no longer say that, because the banner
legitimately animates there. It now asserts the absence of both *carriers*
(SGR 6 and SGR 5) instead, plus the presence of the cursor-hide escape — that
last one in the other direction, so `lib/tty.sh` cannot quietly acquire
`lib/sgr.sh`'s three conditions and go plain everywhere without failing.
Probing that with `\r` would have passed vacuously: `script(1)` writes CRLF,
so a carriage return is in the capture whether anything animated or not.

## The `make help` banner animation

**`tty_banner` runs two effects on ONE frame clock**: the banner decrypts
while every menu row types out. Sharing the clock is why they compose — run
in sequence they would be two delays stacked and `make help` would cost the
sum; together the whole thing is one ~400ms budget. The budget is a TOTAL,
not a per-character delay, because the obvious 50ms-a-character spelling gets
slower every time a target is added, silently.

**The rows type in PARALLEL, not one after another.** Sequentially, 22 rows
at any readable speed is several seconds. In parallel the menu costs the same
as its longest row — and because typing runs left to right and `make <target>`
is the left column, the useful half is legible at ~25% of the budget, with the
descriptions you already know arriving last.

There was an intermediate design where only the banner animated and the menu
printed instantly, and the reason it lost is worth keeping: it was chosen
because a *sequential* typewriter leaves the menu unreadable for its whole
duration, which is a real cost on the command you run when you are lost. The
parallel version does not have that property, which is what made the trade
affordable. If this ever feels like a tax again, that intermediate shape is
the fallback, not "make it faster".

That buys two more preconditions, both decided *before* anything is printed,
because once a half-drawn menu is on screen there is no safe way back — the
same cursor movement would be needed to undo it. The output must fit the
screen, and no line may wrap: a wrapped line occupies two screen rows, so the
up-count undercounts and the cursor scribbles into the middle of the menu.
Measuring the width means stripping the escapes first, since the SG codes are
zero-width on screen but are characters in the string.

Scrolling is *not* one of the failure modes, which is the case that looks
fatal and isn't: relative cursor movement survives a scroll, because the
banner and the cursor move up together. Running `make help` at the bottom of
a full screen is fine.

**CI compares the animation's FINAL FRAME against the plain render**, and
that is the assertion worth keeping rather than the byte-order one it
replaced. The animation may hide characters that are about to arrive; it may
never drop one. A bug in the escape-aware prefix walk would truncate a row and
the final frame would still look entirely plausible — only the comparison
catches it. (A row cannot be cut with `${row:0:k}`: the SG codes are
zero-width on screen but real characters in the string, so slicing by
character both miscounts and can sever an escape, leaving the terminal in
whatever state the fragment implied. Each row is walked once and snapshotted
at the frame points instead.)

Both CI rows drive `script(1)` with an explicit `stty rows 50 cols 200`. A
runner's pty is unsized until something sets it — `stty size` reports `0 0` —
so without it the animation would correctly decline and the row asserting it
happens would fail for a reason unrelated to the guard being tested.

**The screen size comes from `stty size < /dev/tty`, never `tput`.** `tput
lines` needs a valid `$TERM` and exits 2 with *"No value for $TERM and no -T
specified"* without one — and CI sets no TERM, so the tput version declined on
every runner and failed the row asserting the animation happens. `stty` reads
the ioctl and never consults terminfo, so it answers in strictly more places.
It has to read `/dev/tty` rather than fd 1: inside `$( )` fd 1 is the capture
pipe, so `stty size <&1` reports *"Inappropriate ioctl for device"*.
