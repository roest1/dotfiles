#!/usr/bin/env bash
# claude/tab-state.sh <asking|waiting|stop|idle|prompt>
#
# Publishes this Claude session's state to wezterm's tab as the `claude_state`
# user var (OSC 1337 SetUserVar), which wezterm/wezterm.lua turns into the tab
# glyph. The hooks in claude/settings.json call it, with the hook's JSON on
# stdin. It never fails: a hook that errors would print into the session.
#
# Claude Code has no hook for an interrupt. Esc skips `Stop`, so a claim made
# before it (asking, waiting) would stay up until the next turn ended. Two
# events bound that instead:
#   prompt  a new prompt clears the claim; the title's spinner speaks for a turn
#   idle    Claude's idle notification turns a stale asking/waiting into
#           complete. A background claim stays: its tasks may still be running.
# So the last claim is kept per session, in $XDG_RUNTIME_DIR (per user, in
# memory, gone at logout).
#
# CLAUDE_TAB_TTY overrides /dev/tty, for tests.

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
printf '\033]1337;SetUserVar=claude_state=%s\007' "$(printf '%s' "$state" | base64 -w0)" \
  >"${CLAUDE_TAB_TTY:-/dev/tty}" 2>/dev/null
exit 0
