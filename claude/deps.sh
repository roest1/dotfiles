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
echo "  ✅ git clean filter registered — model and effort stay local; git sees claude/model-defaults.json"

if ! command -v jq >/dev/null 2>&1; then
  echo "  ⚠️  jq is missing, so the filter passes through unchanged for now."
  echo "     Install it ('make install bash') and the churn stops."
fi

# The sandbox (see [claude] in deps.conf) needs unprivileged user namespaces as
# well as the two packages. Where it cannot start, Claude Code runs every
# command unsandboxed without saying so, so say it here.
if command -v bwrap >/dev/null 2>&1; then
  if bwrap --ro-bind / / --dev /dev --unshare-user --unshare-net true 2>/dev/null; then
    echo "  ✅ the Claude Code sandbox can start here"
  else
    echo "  ⚠️  bubblewrap cannot start a sandbox here (user namespaces off?)."
    echo "     Claude Code will run its commands unsandboxed on this machine."
  fi
fi
