#!/usr/bin/env bash
# ─── Science Gothic Mono carrier ─────────────────────────────────────────────
#
# wezterm/wezterm.lua maps SGR 6 to the monospaced Science Gothic in
# wezterm/fonts/. SGR 6 is "rapid blink", and it renders steady rather than
# blinking because the same config sets text_blink_rate_rapid = 0 — so the
# attribute is free to reuse as "draw this in the other font".
#
# Italic was the obvious carrier and is the wrong one: rose-pine italicises
# nvim's comments, so every comment in the editor would have silently changed
# font. Nothing in this repo, or in any tool it drives, emits SGR 6.
#
# THE GUARD IS THE WHOLE SAFETY STORY, and both halves are load-bearing:
#
#   -t 1                   CI runs `make check bash | tee /tmp/check.txt` and
#                          greps it, and the same for `make link`. Escape codes
#                          must never reach a pipe.
#
#   TERM_PROGRAM=WezTerm   Every OTHER terminal renders SGR 6 as what it
#                          actually means: BLINKING TEXT. Over ssh, in GNOME
#                          Terminal, in Terminal.app, in a mac's default shell,
#                          inside `script`, this must degrade to plain text —
#                          and does, because the variables stay empty.
#
#   the fonts are linked    Being IN wezterm is not the same as wezterm having
#                          the font_rules. On a machine that hasn't run
#                          `make link` yet, or one pointed at a stock config,
#                          the rule is absent and SGR 6 blinks again. The
#                          linked font directory is the cheapest true proxy for
#                          "this repo's wezterm.lua is the live config", since
#                          deps.conf links the two together.
#
# Everything below is empty unless all three hold, so callers never branch:
# they interpolate the variables unconditionally and get nothing when it isn't
# safe. That is why this is one file and not a conditional at each call site.
#
# Sourced by the Makefile's help target and by lib/status.sh.

# shellcheck disable=SC2034  # consumed by callers that source this file
if [ -t 1 ] && [ "${TERM_PROGRAM:-}" = "WezTerm" ] \
   && [ -d "${XDG_CONFIG_HOME:-$HOME/.config}/wezterm/fonts" ]; then
  SG=$'\033[6m'        # carrier on, regular cut
  SG_B=$'\033[6;1m'    # carrier on, bold cut
  SG_R=$'\033[22m'     # back to the regular cut, carrier still on
  SG_OFF=$'\033[22;25m'
else
  SG=''
  SG_B=''
  SG_R=''
  SG_OFF=''
fi
