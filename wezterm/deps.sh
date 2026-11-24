#!/usr/bin/env bash
set -euo pipefail

# ─── [wezterm] platform fixups ───────────────────────────────────────────────
#
# The manifest declares `pkg||manual wezterm`. Neither Fedora nor RHEL
# packages wezterm in their default repos, so `pkg` rarely serves it and this
# fills the gap with the fonts and the install advice.
#
# Deliberately does NOT guess at a COPR name or a release-asset URL. A fabricated
# URL that 404s a year from now is worse than a clear instruction, and `make
# check` will honestly report wezterm as MISSING until it's installed.
#
# Run automatically after the [wezterm] section's tools by lib/run.sh.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/pkg.sh
source "$HERE/../lib/pkg.sh"

pkg_detect
ensure_local_bin_on_path

# ─── Fonts ───────────────────────────────────────────────────────────────────
#
# Every family wezterm.lua names, plus IosevkaTerm: no lane defaults to it, but
# it is the one family that draws Claude Code's glyphs at cell width, so it is
# here for `font` to offer. CI holds this list to wezterm.lua.
#
# Where each one comes from is not this repo's to know. roest1/fonts, the
# submodule at fonts/, keeps a catalogue with one file per font and installs
# from it, skipping a family fontconfig already has. Why each font is here --
# 0xProto's 0.62em cell, the glyphs IosevkaTerm has and the others lack -- is
# written in those files.
FONTS=(
  '0xProto Nerd Font'
  'JetBrainsMono Nerd Font'
  'IosevkaTerm Nerd Font'
  'Science Gothic'
)
if [[ -x "$HERE/fonts/install.sh" ]]; then
  # Exit 1 is a download that failed, which costs looks, not function: wezterm
  # falls back to its bundled JetBrains Mono. Exit 2 is a family the catalogue
  # does not have, which no retry fixes, so that one stops the script.
  "$HERE/fonts/install.sh" "${FONTS[@]}" || [[ $? -eq 1 ]]
else
  echo "  ⚠️  wezterm/fonts has no install.sh — is the submodule checked out? No fonts installed."
fi

# There used to be a version floor here, reading wezterm/MIN_VERSION, and it was
# the wrong shape. It guessed at the ONE thing no program can prove -- whether
# this binary applies font_rules on the blink attribute at draw time -- from a
# build stamp, while the four things that CAN be proven went unchecked. A floor
# also cannot fail safe: anything at or above it passed untested, so the silent
# failure it existed to catch survived inside its own green tick.
#
# `make status wezterm` asks the answerable half (files, link, ls-fonts
# resolution) and `font` shows the carrier line for the half only an eye can
# read. See status_fonts in lib/status.sh.
if command -v wezterm >/dev/null 2>&1; then
  echo "  ✅ wezterm ($(wezterm --version 2>/dev/null | head -1))"
  echo "     font lanes: make status wezterm"
  exit 0
fi

echo ""
echo "  wezterm is not installed and isn't in this platform's default repos."
echo ""
cat <<'EOF'
    Fedora and RHEL don't package wezterm. Options:

      1. Official instructions:  https://wezterm.org/installation.html

      2. Rootless install (no sudo) — the pattern this machine uses:

           mkdir -p ~/.local/wezterm-root
           # download the .rpm for your distro from
           #   https://github.com/wezterm/wezterm/releases
           rpm2cpio wezterm-*.rpm | (cd ~/.local/wezterm-root && cpio -idmv)
           ln -sf ~/.local/wezterm-root/usr/bin/wezterm{,-gui,-mux-server} ~/.local/bin/

         Useful on a machine where you can't install packages but can write
         to $HOME — the same constraint the section toggles exist for.
EOF

echo ""
echo "  NOTE: wezterm.lua declares the 'mux' unix domain the Jarvis sidecar"
echo "        connects to. Installing wezterm-mux-server matters for that, not"
echo "        just the GUI."
echo ""
