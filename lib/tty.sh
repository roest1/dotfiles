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
# only legibility arrives late — you can look straight past it to the command
# list, which is what you actually ran `make help` for.
#
# It is on the banner and nothing else for the same reason: `dotfiles — Linux`
# tells you nothing you did not already know, so nothing is lost while it is
# illegible. The command list underneath is the payload and is never animated.
#
# The budget is a TOTAL, not a per-character delay. The obvious spelling —
# 50ms a character, as the React component this came from does — gets slower
# every time the string grows, which is a tax that arrives silently.
tty_scramble() {
  local pre="$1" post="$2" text="$3"
  local budget_ms=400 frames=16

  if [ "$TTY_ANIM" != 1 ]; then
    printf '%s%s%s\n' "$pre" "$text" "$post"
    return
  fi

  # Slicing a string with ${text:i:1} is character-aware only in a UTF-8
  # locale; under LC_ALL=C it slices BYTES and would cut the em dash into three
  # pieces of mojibake. Rather than guess, decline to animate and print it.
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf-8* | *UTF8* | *utf8*) ;;
    *)
      printf '%s%s%s\n' "$pre" "$text" "$post"
      return
      ;;
  esac

  local n i
  n=${#text}
  if [ "$n" -eq 0 ]; then
    printf '%s%s%s\n' "$pre" "$text" "$post"
    return
  fi

  local -a chars=()
  for ((i = 0; i < n; i++)); do chars[i]="${text:i:1}"; done

  # ASCII only, and every one of them single-width: the line must not change
  # width between frames or the banner jitters against the text below it.
  # A space is deliberately NOT in here, so the word gaps hold still and the
  # shape of the line is readable long before its letters are.
  local pool='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-=[]{};:,.<>/?'
  local pool_n=${#pool}

  # An interrupted animation must not leave a half-scrambled line as the last
  # thing on screen, and must not leave the cursor hidden for the rest of the
  # session. Single-quoted so it expands when it FIRES, not now: the locals are
  # still in scope because the trap is cleared before this function returns.
  trap 'printf "\r%s%s%s%s\n" "$TTY_SHOW" "$pre" "$text" "$post"; trap - INT; kill -INT $$' INT

  # Computed once. Spelling it inside the loop costs a fork per frame, on top of
  # the one sleep already costs, in a command that used to fork none at all.
  local step
  step=$(awk -v b="$budget_ms" -v f="$frames" 'BEGIN { printf "%.3f", b / f / 1000 }')

  printf '%s' "$TTY_HIDE"

  local f reveal line c
  for ((f = 0; f < frames; f++)); do
    reveal=$((n * f / frames))
    line=''
    for ((i = 0; i < n; i++)); do
      c="${chars[i]}"
      # Substitutable only if the pool actually contains it. That is a stricter
      # test than "is it punctuation", and it is locale-proof: [[:punct:]] in a
      # UTF-8 locale matches the em dash, which has no like-for-like ASCII
      # stand-in. Anything the pool cannot spell is left exactly as it is.
      if [ "$i" -lt "$reveal" ] || [ "${pool#*"$c"}" = "$pool" ]; then
        line="$line$c"
      else
        line="$line${pool:$((RANDOM % pool_n)):1}"
      fi
    done
    printf '\r%s%s%s' "$pre" "$line" "$post"
    sleep "$step"
  done

  trap - INT
  printf '\r%s%s%s%s\n' "$TTY_SHOW" "$pre" "$text" "$post"
}
