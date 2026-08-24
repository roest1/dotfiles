#!/usr/bin/env bash
# ─── Escapes whose only precondition is a terminal ───────────────────────────
#
# The companion to lib/sgr.sh, and the distinction between the two files is the
# whole reason this one exists rather than three more variables over there.
#
# sgr.sh emits SGR 6, which MEANS something else outside this setup: on any
# other terminal it is rapid blink, so it needs all three of tty + WezTerm +
# linked fonts before it is safe. Color and cursor movement mean the same thing
# everywhere. They need exactly one condition — that stdout is a terminal — and
# folding them into sgr.sh would have put two different guards behind one set of
# variables whose header promises "empty unless all three hold". A caller could
# then no longer tell which guarantee it was getting.
#
# So: one file per guard, named for the guard.
#
#   -t 1   CI runs `make help | grep` and `make status | tee`, and a carriage
#          return or a color code in a pipe is garbage in a log. This is also
#          what keeps `make status > file` readable.
#
# Everything below is empty unless that holds, so callers interpolate
# unconditionally and get nothing when it is not safe — the same contract
# sgr.sh offers, for a different question.

# shellcheck disable=SC2034  # consumed by callers that source this file
if [ -t 1 ]; then
  # 39 (default foreground), NOT 0. A full reset would also clear the Science
  # Gothic carrier, and lib/status.sh wraps whole lines in $SG ... $SG_OFF with
  # these marks INSIDE. Resetting the color must not silently drop the font
  # halfway along the line.
  TTY_OK=$'\033[32m'    # green — matches what the manifest declares
  TTY_BAD=$'\033[31m'   # red   — drift, and the summary will name it
  TTY_NA=$'\033[33m'    # yellow — not applicable / not checked here
  TTY_OFF=$'\033[39m'
  TTY_HIDE=$'\033[?25l'
  TTY_SHOW=$'\033[?25h'
  TTY_ANIM=1
else
  TTY_OK=''
  TTY_BAD=''
  TTY_NA=''
  TTY_OFF=''
  TTY_HIDE=''
  TTY_SHOW=''
  TTY_ANIM=0
fi

# ─── The decrypt banner ──────────────────────────────────────────────────────
#
# Characters flip through gibberish and resolve left to right. Scramble rather
# than typewriter, deliberately: a typewriter's line does not EXIST until it is
# finished, so every millisecond is spent waiting on something unreadable. A
# scramble is at full width from the first frame, so the layout is stable and
# only legibility arrives late.
#
# THE ANIMATION RUNS AFTER THE WHOLE MENU IS ON SCREEN, and that is the point of
# this function rather than a bare scramble. The first version animated the
# banner and THEN printed the menu, which made `make help` -- the command whose
# entire job is fast orientation -- cost 400ms before its first useful line. So
# the body is printed first and the cursor comes back UP to the banner, which
# means everything is readable at t=0 and the effect happens next to it.
#
# It is the banner and nothing else for the same reason: `dotfiles — Linux`
# tells you nothing you did not already know, so nothing is lost while it is
# illegible. The menu underneath is the payload and is never animated.
#
# The budget is a TOTAL, not a per-character delay. The obvious spelling --
# 50ms a character, as the React component this came from does -- gets slower
# every time the string grows, which is a tax that arrives silently.
#
#   $1 escapes before the banner text   $3 the banner text
#   $2 escapes after it                 $4 the rest of the help output
tty_banner() {
  local pre="$1" post="$2" text="$3" body="$4"
  local budget_ms=400 frames=16

  # Body first, then one blank line, so the caller does not have to think about
  # trailing newlines -- $( ) strips them, so a trailing echo "" cannot survive
  # the capture and has to be added back on this side.
  _tty_banner_plain() {
    printf '%s%s%s\n' "$pre" "$text" "$post"
    printf '%s\n\n' "$body"
  }

  [ "$TTY_ANIM" = 1 ] || { _tty_banner_plain; return; }

  # Slicing with ${text:i:1} is character-aware only in a UTF-8 locale; under
  # LC_ALL=C it slices BYTES and would cut the em dash into three pieces of
  # mojibake. Decline rather than guess.
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf-8* | *UTF8* | *utf8*) ;;
    *) _tty_banner_plain; return ;;
  esac

  local n
  n=${#text}
  [ "$n" -gt 0 ] || { _tty_banner_plain; return; }

  # How far back up the banner is. Body lines, plus the blank after it, plus
  # the banner's own line.
  local bl up
  bl=$(printf '%s\n' "$body" | wc -l | tr -d ' ')
  up=$((bl + 2))

  # ── The two preconditions that only this shape needs ──────────────────────
  #
  # Relative cursor movement SURVIVES scrolling -- if the terminal scrolls, the
  # banner and the cursor move up together and \033[<n>A still lands on it. So
  # running `make help` at the bottom of a full screen is fine, which is the
  # case that looks fatal and is not.
  #
  # What is fatal is the banner leaving the SCREEN (not the scrollback), and a
  # line that WRAPS: a wrapped line occupies two screen rows, so the count above
  # undercounts and the cursor lands somewhere in the middle of the menu and
  # scribbles on it. Both are decided here, before anything is printed, because
  # once a scrambled banner is on screen there is no safe way to go back and fix
  # it -- the same movement would be needed to undo it.
  local height width
  height=$(tput lines 2>/dev/null) || height=""
  width=$(tput cols 2>/dev/null) || width=""
  case "$height$width" in
    *[!0-9]* | '') _tty_banner_plain; return ;;
  esac
  [ "$((up + 1))" -lt "$height" ] || { _tty_banner_plain; return; }

  # Escapes are zero-width on screen but are characters in the string, so the
  # SG carrier codes have to come out before anything is measured. ${#l} is
  # character-aware in a UTF-8 locale, which is already guaranteed above.
  local maxw=0 l
  while IFS= read -r l; do
    [ ${#l} -gt $maxw ] && maxw=${#l}
  done < <(printf '%s\n%s\n' "$text" "$body" | sed $'s/\033\[[0-9;?]*[a-zA-Z]//g')
  [ "$maxw" -le "$width" ] || { _tty_banner_plain; return; }

  local -a chars=()
  local i
  for ((i = 0; i < n; i++)); do chars[i]="${text:i:1}"; done

  # ASCII only, and every one of them single-width: the line must not change
  # width between frames or the banner jitters against the menu below it.
  # A space is deliberately NOT in here, so the word gaps hold still and the
  # shape of the line is readable long before its letters are.
  local pool='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-=[]{};:,.<>/?'
  local pool_n=${#pool}

  local step
  step=$(awk -v b="$budget_ms" -v f="$frames" 'BEGIN { printf "%.3f", b / f / 1000 }')

  _tty_frame() { # $1 how many leading characters are already resolved
    local out='' j c
    for ((j = 0; j < n; j++)); do
      c="${chars[j]}"
      # Substitutable only if the pool can actually spell it. Stricter than "is
      # it punctuation", and locale-proof: [[:punct:]] matches the em dash in a
      # UTF-8 locale, and there is no like-for-like ASCII stand-in for it.
      if [ "$j" -lt "$1" ] || [ "${pool#*"$c"}" = "$pool" ]; then
        out="$out$c"
      else
        out="$out${pool:$((RANDOM % pool_n)):1}"
      fi
    done
    printf '\r%s%s%s' "$pre" "$out" "$post"
  }

  # Everything on screen at t=0: a scrambled banner, then the whole menu.
  printf '%s' "$TTY_HIDE"
  _tty_frame 0
  printf '\n'
  printf '%s\n\n' "$body"

  # An interrupt leaves the cursor UP at the banner, so the trap has to finish
  # the line AND walk back down before re-raising -- otherwise the next prompt
  # is drawn over the middle of the menu. Single-quoted so it expands when it
  # fires; the locals are still in scope because it is cleared before returning.
  trap 'printf "\r%s%s%s" "$pre" "$text" "$post"; printf "\033[%dB\r%s" "$up" "$TTY_SHOW"; trap - INT; kill -INT $$' INT

  printf '\033[%dA' "$up"
  local f
  for ((f = 1; f <= frames; f++)); do
    sleep "$step"
    _tty_frame $((n * f / frames))
  done

  trap - INT
  printf '\r%s%s%s' "$pre" "$text" "$post"
  printf '\033[%dB\r%s' "$up" "$TTY_SHOW"
}
