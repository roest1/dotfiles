#!/usr/bin/env bash
set -euo pipefail

# ─── [claude] platform fixups ────────────────────────────────────────────────
#
# Registers the git clean filter that .gitattributes names for
# claude/settings.json. It has to happen here rather than in the manifest
# because `filter.*` settings live in .git/config, which is per-clone and by
# design not committable -- .gitattributes can say WHICH filter applies, but
# not what it runs.
#
# Run automatically after the [claude] section's tools by lib/run.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

if ! command -v git >/dev/null 2>&1; then
  echo "  ⚠️  git not found — skipping the settings.json clean filter"
  exit 0
fi

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "  ⚠️  not a git clone — skipping the settings.json clean filter"
  exit 0
fi

git -C "$REPO" config filter.claude-settings.clean "$REPO/tools/clean-claude-settings.sh"

# No smudge. The identity default is what we want: git writes the stored file
# back verbatim, so a checkout that genuinely changes settings.json still lands.
echo "  ✅ git clean filter registered — model/effortLevel are now local-only"

if ! command -v jq >/dev/null 2>&1; then
  echo "  ⚠️  jq is missing, so the filter passes through unchanged for now."
  echo "     Install it ('make install bash') and the churn stops."
fi
