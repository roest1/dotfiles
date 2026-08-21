#!/usr/bin/env bash
# ─── git clean filter for claude/settings.json ───────────────────────────────
#
# Claude Code writes its own settings at runtime, and ~/.claude/settings.json is
# a SYMLINK into this repo (see [claude] in deps.conf). So switching model or
# effort level in a session edits a tracked file, and every machine reports
# drift for a preference that is deliberately per-machine.
#
# This is the `clean` half of a clean/smudge pair: git runs it on the way IN
# (add, diff, status), so the version git compares and stores has the volatile
# keys removed. The file on disk keeps them. The result is that model and
# effortLevel move freely per machine and per conversation, and git never sees
# a change.
#
# -S sorts keys, which kills the other churn: Claude Code rewrites the file
# whole, so an unrelated setting change reorders `permissions` and shows up as
# a diff that means nothing.
#
# FAILURE IS PASS-THROUGH, deliberately. A clean filter that emits nothing on
# error would commit an EMPTY settings.json, and git would not warn. So the
# input is buffered and echoed verbatim unless jq both exists and succeeds:
# the worst case is the old behaviour (a noisy diff), never data loss.
#
# Registered per-clone by claude/deps.sh — filter config lives in .git/config
# and cannot be committed, which is why it is part of the install rather than
# something .gitattributes can do alone.

input="$(cat)"

if command -v jq >/dev/null 2>&1; then
  if out="$(printf '%s' "$input" | jq -S 'del(.model, .effortLevel)' 2>/dev/null)"; then
    printf '%s\n' "$out"
    exit 0
  fi
fi

printf '%s' "$input"
