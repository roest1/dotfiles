#!/usr/bin/env bash
# claude/tab-state.sh <asking|waiting|stop|idle|prompt>
#
# Publishes this Claude session's state to wezterm's tab as the `claude_state`
# user var (OSC 1337 SetUserVar), which wezterm/wezterm.lua turns into the tab
# glyph. The hooks in claude/settings.json call it, with the hook's JSON on
# stdin. It never fails: a hook that errors would print into the session.
#
# Claude Code has no hook for an interrupt. Esc skips `Stop`, so a claim made
# before it (asking, waiting) would stay up until the next turn ended. What
# retires it instead:
#   watch   asking and waiting start a watcher on the session transcript. The
#           question or permission prompt ends with that tool call's result;
#           Esc writes it as an error, so an error result turns the claim into
#           complete. The watcher exits at the first result, or as soon as
#           anything else changes the claim, or after two hours.
#   prompt  a new prompt clears the claim; the title's spinner speaks for a turn
#   idle    Claude's idle notification turns a stale asking/waiting into
#           complete. It is a backstop, not the fix: Claude sends it only when
#           you seem to be away from the terminal.
# A background claim is never retired: its tasks may still be running. The last
# claim is kept per session, in $XDG_RUNTIME_DIR (per user, in memory, gone at
# logout).
#
# Where it writes: Claude Code starts hooks in a new session with no
# controlling terminal, so /dev/tty is "No such device or address" in here and
# a write to it silently does nothing. Claude itself still has the pane's pty
# as its stdout, so the first ancestor whose stdout is a pty is the tab.
# CLAUDE_TAB_TTY overrides that, for tests.

emit() { # <state> <tty>
  printf '\033]1337;SetUserVar=claude_state=%s\007' "$(printf '%s' "$1" | base64 -w0)" \
    >"$2" 2>/dev/null
}

# Internal: tab-state.sh watch <claim> <state file> <transcript> <offset> <tty>
if [ "${1:-}" = watch ]; then
  claim=$2 sf=$3 tp=$4 off=$5 tty=$6 n=0
  while [ $n -lt 7200 ] && [ "$(cat "$sf" 2>/dev/null)" = "$claim" ]; do
    if line=$(tail -c +"$((off + 1))" "$tp" 2>/dev/null | grep -m1 -F '"type":"tool_result"'); then
      case "$line" in
        *'"is_error":true'*) printf complete >"$sf" 2>/dev/null && emit complete "$tty" ;;
      esac
      exit 0
    fi
    sleep 1
    n=$((n + 1))
  done
  exit 0
fi

event="${1:-}"
input=$(cat 2>/dev/null)
field() { command -v jq >/dev/null 2>&1 && jq -r "$1" <<<"$input" 2>/dev/null; }

sid=$(field '.session_id // empty')
dir="${XDG_RUNTIME_DIR:-/tmp}/claude-tab-state"
last_file="$dir/${sid:-unknown}"
last=$(cat "$last_file" 2>/dev/null)

case "$event" in
  asking | waiting) state=$event ;;
  stop)
    n=$(field '(.background_tasks // []) | length')
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then state=background; else state=complete; fi
    ;;
  idle)
    case "$last" in
      asking | waiting) state=complete ;;
      *) exit 0 ;;
    esac
    ;;
  prompt) state= ;;
  *) exit 0 ;;
esac

mkdir -p "$dir" 2>/dev/null && printf '%s' "$state" >"$last_file" 2>/dev/null
tty=${CLAUDE_TAB_TTY:-}
p=$PPID n=0
while [ -z "$tty" ] && [ "${p:-0}" -gt 1 ] && [ $n -lt 4 ]; do
  t=$(readlink "/proc/$p/fd/1" 2>/dev/null)
  case "$t" in /dev/pts/*) tty=$t ;; esac
  # Field 4 of /proc/<pid>/stat is the parent; cut after the ")" that ends
  # the command name, which may itself hold spaces.
  p=$(sed 's/.*) //' "/proc/$p/stat" 2>/dev/null | cut -d' ' -f2) n=$((n + 1))
done
[ -n "$tty" ] || exit 0
emit "$state" "$tty"

# Detached with setsid and every stream closed: Claude waits on the hook's
# output, so a watcher holding it open would hang the session.
case "$state" in
  asking | waiting)
    tp=$(field '.transcript_path // empty')
    if [ -f "$tp" ] && command -v setsid >/dev/null 2>&1; then
      setsid -f "$0" watch "$state" "$last_file" "$tp" "$(stat -c %s "$tp")" "$tty" \
        </dev/null >/dev/null 2>&1
    fi
    ;;
esac
exit 0
