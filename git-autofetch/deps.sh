#!/usr/bin/env bash
set -euo pipefail

# ─── [git-autofetch] platform fixups ─────────────────────────────────────────
#
# The manifest links the script and both units; this enables the timer. That
# step can't be a `post` line because it depends on the machine: CI runners,
# containers and a WSL distro without systemd=true have no user manager, and
# there it has to be a skip, not a failure.
#
# Run automatically after the [git-autofetch] section's tools by lib/run.sh.

if ! command -v systemctl >/dev/null 2>&1 \
  || ! systemctl --user show-environment >/dev/null 2>&1; then
  echo "  ⚠️  no systemd user manager here — timer not enabled"
  exit 0
fi

# Units are symlinks into this repo, so an edit lands on the next reload.
systemctl --user daemon-reload
systemctl --user enable --now git-autofetch.timer
echo "  ✅ git-autofetch.timer enabled — every 20 min; logs: journalctl --user -u git-autofetch"
