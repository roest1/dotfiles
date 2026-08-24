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

# ─── The `make help` animation ───────────────────────────────────────────────
#
# Two effects on ONE frame clock: the banner decrypts while every menu row types
# out at once. Sharing the clock is the whole reason they compose -- run
# sequentially they would be two delays stacked, and `make help` would cost the
# sum. Run together the whole thing is one budget.
#
# THE ROWS TYPE IN PARALLEL, not one after another. Sequentially, 22 rows at any
# readable speed is several seconds; in parallel the menu costs the same as its
# longest row. And because typing runs left to right and `make <target>` lives
# in the left column, the useful half of the menu is legible at ~25% of the
# budget -- the descriptions, which you mostly already know, arrive last.
#
# This is the one command with an animation, and it stays that way. `make help`
# is short, self-contained and run deliberately; `make install` and `make
# status` produce output as work completes and have nothing to animate against.
#
# The budget is a TOTAL, not a per-character delay. The obvious spelling --
# 50ms a character, as the React components this came from do -- gets slower
# every time a target is added, which is a tax that arrives silently.
#
#   $1 escapes before the banner text   $3 the banner text
#   $2 escapes after it                 $4 the rest of the help output
tty_banner() {
  local pre="$1" post="$2" text="$3" body="$4"
  local budget_ms=400 frames=16

  _tty_plain() {
    printf '%s%s%s\n' "$pre" "$text" "$post"
    printf '%s\n\n' "$body"
  }

  [ "$TTY_ANIM" = 1 ] || { _tty_plain; return; }

  # Slicing with ${s:i:1} is character-aware only in a UTF-8 locale; under
  # LC_ALL=C it slices BYTES and would cut the em dash into three pieces of
  # mojibake. Decline rather than guess.
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf-8* | *UTF8* | *utf8*) ;;
    *) _tty_plain; return ;;
  esac

  local n
  n=${#text}
  [ "$n" -gt 0 ] || { _tty_plain; return; }

  local -a rows=()
  while IFS= read -r line; do rows[${#rows[@]}]="$line"; done <<<"$body"
  local nb=${#rows[@]} region
  region=$((nb + 1))   # the banner plus every body row

  # ── The two preconditions this shape needs, both settled BEFORE printing ───
  #
  # Once a half-drawn menu is on screen there is no safe way back: undoing it
  # needs the same cursor movement that is in question. So both are decided
  # while the only thing that has happened is arithmetic.
  #
  # Scrolling is NOT one of them, which is the case that looks fatal and is not.
  # Relative cursor movement survives a scroll -- the region and the cursor move
  # up together -- so running this at the bottom of a full screen is fine. What
  # is fatal is the region leaving the SCREEN, and a line that WRAPS: a wrapped
  # line occupies two screen rows, so the up-count undercounts and each frame
  # walks further into the menu, shredding it.
  #
  # stty rather than tput, and not as a style preference: `tput lines` needs a
  # valid $TERM and dies with "No value for $TERM" without one. CI sets no TERM,
  # so tput made this decline on every runner. stty reads the ioctl and never
  # consults terminfo, so it answers in strictly more places -- which matters
  # beyond CI, in a minimal container or an ssh session with a stripped
  # environment. From /dev/tty, not fd 1: inside $( ) fd 1 is the capture PIPE,
  # so `stty size <&1` reports "Inappropriate ioctl for device".
  local size height width
  size=$(stty size < /dev/tty 2>/dev/null) || { _tty_plain; return; }
  height=${size%% *}
  width=${size##* }
  case "$height$width" in
    *[!0-9]* | '') _tty_plain; return ;;
  esac
  # A pty nothing has sized reports 0 0. Declining is right: with no idea how
  # tall the screen is there is no way to know the region survives on it.
  [ "$height" -gt 0 ] && [ "$width" -gt 0 ] || { _tty_plain; return; }
  [ "$((region + 2))" -lt "$height" ] || { _tty_plain; return; }

  # Escapes are zero-width on screen but are characters in the string, so the
  # SG carrier codes have to come out before anything is measured.
  local maxw=0 l
  while IFS= read -r l; do
    [ ${#l} -gt $maxw ] && maxw=${#l}
  done < <(printf '%s\n%s\n' "$text" "$body" | sed $'s/\033\[[0-9;?]*[a-zA-Z]//g')
  [ "$maxw" -le "$width" ] || { _tty_plain; return; }

  # ── Per-row prefixes, escape-aware ────────────────────────────────────────
  #
  # A row cannot be truncated with ${row:0:k}. It carries SG carrier codes,
  # which are zero-width on screen but real characters in the string, so
  # slicing by character both MISCOUNTS and can cut an escape in half -- and
  # half an escape leaves the terminal in whatever state the fragment implied.
  #
  # Each row is therefore walked ONCE and snapshotted at the frame points, not
  # re-truncated per frame: 22 rows x ~70 chars of bash looping instead of
  # 22 x 70 x 17, which is the difference between imperceptible and a visible
  # stall before the first frame.
  local -a prefix=()
  local li i c vis seen f target acc esc
  for ((li = 0; li < nb; li++)); do
    l="${rows[li]}"
    local ln=${#l}

    vis=0
    for ((i = 0; i < ln; i++)); do
      if [ "${l:i:1}" = $'\033' ]; then
        while ((i < ln)); do
          i=$((i + 1))
          case "${l:i:1}" in [a-zA-Z]) break ;; esac
        done
      else
        vis=$((vis + 1))
      fi
    done

    acc=''; seen=0; f=0
    while [ "$f" -le "$frames" ] && [ $((vis * f / frames)) -le 0 ]; do
      prefix[li * (frames + 1) + f]=''
      f=$((f + 1))
    done
    i=0
    while ((i < ln)); do
      c="${l:i:1}"
      if [ "$c" = $'\033' ]; then
        esc="$c"
        while ((i < ln)); do
          i=$((i + 1))
          esc="$esc${l:i:1}"
          case "${l:i:1}" in [a-zA-Z]) break ;; esac
        done
        acc="$acc$esc"; i=$((i + 1)); continue
      fi
      acc="$acc$c"; seen=$((seen + 1)); i=$((i + 1))
      while [ "$f" -le "$frames" ]; do
        target=$((vis * f / frames))
        [ "$seen" -ge "$target" ] || break
        prefix[li * (frames + 1) + f]="$acc"
        f=$((f + 1))
      done
    done
    # The last frame is the WHOLE row, always. Everything the animation is
    # allowed to do is hide characters that are about to arrive; it may never
    # drop one. A CI row compares the final frame against the piped output.
    while [ "$f" -le "$frames" ]; do prefix[li * (frames + 1) + f]="$acc"; f=$((f + 1)); done
  done

  # ── The banner's gibberish pool ───────────────────────────────────────────
  #
  # ASCII only and every one single-width, so the line cannot change width
  # between frames and jitter against the menu. A space is deliberately absent,
  # so word gaps hold still and the shape of the line is readable long before
  # its letters are.
  local pool='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()_+-=[]{};:,.<>/?'
  local pool_n=${#pool}
  local -a chars=()
  for ((i = 0; i < n; i++)); do chars[i]="${text:i:1}"; done

  _tty_draw() { # $1 frame
    local out='' j ch reveal=$(( n * $1 / frames ))
    for ((j = 0; j < n; j++)); do
      ch="${chars[j]}"
      # Substitutable only if the pool can actually spell it -- stricter than
      # "is it punctuation", and locale-proof: [[:punct:]] matches the em dash
      # in a UTF-8 locale and there is no like-for-like ASCII stand-in for it.
      if [ "$j" -lt "$reveal" ] || [ "${pool#*"$ch"}" = "$pool" ]; then
        out="$out$ch"
      else
        out="$out${pool:$((RANDOM % pool_n)):1}"
      fi
    done
    printf '\r%s%s%s\033[K\n' "$pre" "$out" "$post"
    local k
    for ((k = 0; k < nb; k++)); do
      printf '%s\033[K\n' "${prefix[k * (frames + 1) + $1]}"
    done
  }

  # An interrupt lands mid-region, so the trap has to finish the whole thing --
  # a complete final frame and the trailing blank -- not just show the cursor.
  # Without it the next prompt is drawn into the middle of a half-typed menu.
  trap '_tty_draw '"$frames"'; printf "\n%s" "$TTY_SHOW"; trap - INT; kill -INT $$' INT

  local step
  step=$(awk -v b="$budget_ms" -v f="$frames" 'BEGIN { printf "%.3f", b / f / 1000 }')

  printf '%s' "$TTY_HIDE"
  for ((f = 0; f <= frames; f++)); do
    [ "$f" -gt 0 ] && printf '\033[%dA' "$region"
    _tty_draw "$f"
    [ "$f" -lt "$frames" ] && sleep "$step"
  done

  trap - INT
  printf '\n%s' "$TTY_SHOW"
}
