#!/usr/bin/env bash
set -euo pipefail

# ─── [claude] Claude Code itself, then platform fixups ───────────────────────
#
# Claude Code: Anthropic's own installer, the way its docs say to install it;
# no distro packages it. It checks the download against a published SHA-256,
# puts the launcher in ~/.local/bin, and from then on Claude Code updates
# itself, so nothing here pins a version. Signing in is the one thing this
# cannot do: run `claude` once.
#
# Skipped when a `claude` is already on PATH, wherever it came from. A second
# copy over the first is the mess docs/decisions/tool-duplication.md describes.
#
# Then the fixups. Registers the git clean filter that .gitattributes names for
# claude/settings.json. It has to happen here rather than in the manifest
# because `filter.*` settings live in .git/config, which is per-clone and by
# design not committable -- .gitattributes can say WHICH filter applies, but
# not what it runs.
#
# Run automatically after the [claude] section's tools by lib/run.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

# ~/.local/bin on PATH before the installer runs, and not only to find the
# result. With that directory off PATH the installer ends by telling you to
# append an export line to ~/.bashrc, which on these machines is a symlink into
# this repo. It edits no profile itself either way (run into an empty home,
# 2.1.332); on PATH it has nothing to say, and bash/bashrc already puts it there.
export PATH="$HOME/.local/bin:$PATH"
if ! command -v claude >/dev/null 2>&1; then
  echo "  ➡️  Installing Claude Code (official installer)..."
  # Judged by whether claude runs afterwards, not by the pipeline's status:
  # offline, curl fails and bash is handed nothing, which exits 0.
  curl -fsSL https://claude.ai/install.sh | bash || true
fi
if command -v claude >/dev/null 2>&1; then
  echo "  ✅ claude $(claude --version 2>/dev/null | head -n1) — sign in once by hand: run 'claude'"
else
  echo "  ❌ Claude Code could not be installed (offline?). By hand:"
  echo "       curl -fsSL https://claude.ai/install.sh | bash"
fi

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
