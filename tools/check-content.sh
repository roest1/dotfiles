#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# Content guards for files this repo publishes.
#
# This repo is PUBLIC, and claude/user-memory.md is linked to
# ~/.claude/CLAUDE.md -- which Claude Code rewrites on its own, from
# any session in any repo, whenever you add a memory with `#`. Every
# other tracked file here changes because someone opened an editor and
# will see the diff. That one can grow a line you never typed into
# this repo, so the usual "you read your own diff" defence is weaker
# for it than for anything else in the tree.
#
# WHAT THIS PROVES, AND WHAT IT CANNOT.
#
# It proves the mechanical half: a string shaped like a credential, and
# an absolute path under someone's home directory. Both are decidable.
#
# It cannot prove the half that actually worries you -- a client's
# name, an employer's internal hostname, an unreleased project. No
# pattern distinguishes those from ordinary prose, and a guard that
# pretended to would be worse than none, because it would feel like
# review. Read the diff. This is a backstop for the strings you would
# not have noticed, not a substitute for looking.
#
# Usage:
#   tools/check-content.sh            every tracked file (the CI sweep)
#   tools/check-content.sh FILE...    just these (the pre-commit hook)
#
# Like tools/lint.sh, this reads the WORKTREE rather than the staged
# blob. The difference only shows if you stage a file and then edit it,
# and it errs toward refusing a commit over passing one -- the safe
# direction when the thing being guarded cannot be un-published.
#####################################################################

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PATTERN_FILE="$ROOT/.githooks/content-patterns"

# The pattern file names every shape this looks for, so a sweep over the
# whole tree would find them in the file that defines them. Excluded by
# path rather than by hoping no regex matches its own text: that holds
# today by accident, and the next pattern added is not bound by it.
SELF="\\.githooks/content-patterns"

# A missing pattern file disables the credential half silently, which is the
# one failure this must not have. Same stance as .githooks/pre-commit.
if [[ ! -f "$PATTERN_FILE" ]]; then
  echo "check-content: $PATTERN_FILE is missing — refusing to run unguarded." >&2
  exit 1
fi

patterns=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue
  patterns+="${patterns:+|}$line"
done < "$PATTERN_FILE"

# Files to scan. No arguments means the full sweep.
files=()
if (( $# )); then
  files=("$@")
else
  while IFS= read -r f; do files+=("$f"); done < <(git -C "$ROOT" ls-files)
fi
(( ${#files[@]} )) || exit 0

fail=0

# ─── 1. Credential-shaped content, in any tracked file ─────────────
#
# -I skips binaries, which is how the committed .ttf files stay out of
# this without being named.
for f in "${files[@]}"; do
  [[ -f "$ROOT/$f" ]] || continue
  [[ "$f" =~ $SELF ]] && continue
  if hits=$(grep -nIE "$patterns" "$ROOT/$f" 2>/dev/null); then
    # LINE NUMBERS ONLY, never the matching text. CI logs on a public repo
    # are public, so a guard that printed the secret it caught would publish
    # it on the very run that was supposed to stop it -- and a truncated
    # prefix is not a fix, since the prefix is the identifying half. Whoever
    # sees this has the file.
    lines=$(cut -d: -f1 <<<"$hits" | paste -sd', ' -)
    echo ""
    echo "check-content: credential-shaped content in $f, line(s): $lines"
    echo "  (not echoed — open the file)"
    fail=1
  fi
done

# ─── 2. Absolute home paths in files that get linked into $HOME ────
#
# Scoped to the `link` sources in deps.conf, and computed from the
# manifest rather than listed here, for the reason deps.conf states
# about itself. Those files are installed verbatim on Fedora, WSL and
# SERHEL, so /home/<someone> in one of them is a portability bug before
# it is a privacy one -- it names a path the other two machines do not
# have. README.md and docs/ are not linked anywhere and legitimately
# quote terminal output containing such paths, which is exactly the
# distinction the manifest already draws.
#
# /home/linuxbrew is not a user's home. It is a fixed system prefix,
# the same string on every machine that has it, and bash/bashrc is
# right to name it.
source "$ROOT/lib/manifest.sh"
while IFS=$'\t' read -r _section src _dest; do
  [[ -f "$ROOT/$src" ]] || continue
  # Only scan what was asked for, so the hook stays about staged files.
  if (( $# )); then
    wanted=0
    for f in "${files[@]}"; do [[ "$f" == "$src" ]] && wanted=1; done
    (( wanted )) || continue
  fi
  if hits=$(grep -nIE '(/home/|/Users/)[A-Za-z][A-Za-z0-9._-]*' "$ROOT/$src" \
              | grep -vE '/home/linuxbrew' || true); then
    [[ -z "$hits" ]] && continue
    echo ""
    echo "check-content: absolute home path in $src, which is linked into \$HOME:"
    printf '  %s\n' "$hits"
    echo "  This file is installed verbatim on every machine. Use \$HOME or ~."
    fail=1
  fi
done < <(cd "$ROOT" && manifest_lines link)

if (( fail )); then
  echo ""
  echo "Patterns: .githooks/content-patterns — see tools/check-content.sh for scope."
  exit 1
fi

echo "ok: no credential-shaped content, no absolute home paths in linked files"
