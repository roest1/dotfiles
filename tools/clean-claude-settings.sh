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
# keys REPLACED. The file on disk keeps whatever this machine chose. The result
# is that model and effort move freely per machine and per conversation, and
# git never sees a change.
#
# Replaced rather than deleted, so the committed file still SHOWS how these
# are set. The values come from claude/model-defaults.json — edit that file,
# not settings.json, to change what a fresh checkout starts with. A filter that
# only deleted keys could never commit them at all.
#
# The shape matters as much as the values. /effort writes
# `modelSettings.<model>.effortLevel`; the older top-level `effortLevel` is
# dropped outright. Stripping only the old keys once let modelSettings straight
# through, and two machines committed conflicting effort tables.
#
# A checkout that changes settings.json writes the defaults back to disk, which
# resets this machine's choice once. That is the identity smudge doing its job
# (see claude/deps.sh): the stored file is what lands.
#
# `git status` can still list the file as modified while `git diff` is empty.
# That is git, not this filter: ie_modified() short-circuits on a SIZE mismatch
# against the index and answers "modified" without re-reading the file, so the
# filter never runs. A local choice changes the size, so it fires on every
# /model and /effort.
#
# tools/refresh-claude-settings.sh clears it, called from the SessionStart and
# SessionEnd hooks this file carries. It is `git add` -- which re-records the
# stat and stages nothing -- but only after proving the filtered worktree
# equals the index blob, so a REAL settings change is left visible. Read that
# file before reaching for --assume-unchanged, which hides both kinds.
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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS="$HERE/../claude/model-defaults.json"

input="$(cat)"

# A missing or unparsable defaults file fails jq, and so falls through to the
# pass-through below, the same as a missing jq.
if command -v jq >/dev/null 2>&1 && [ -r "$DEFAULTS" ]; then
  if out="$(printf '%s' "$input" \
              | jq -S --slurpfile d "$DEFAULTS" \
                  'del(.model, .effortLevel, .modelSettings)
                   + ($d[0] | with_entries(select(.key == "model" or .key == "modelSettings")))' \
              2>/dev/null)"; then
    printf '%s\n' "$out"
    exit 0
  fi
fi

printf '%s' "$input"
