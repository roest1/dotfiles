#!/usr/bin/env bash
set -euo pipefail

# ─── [wezterm] platform fixups ───────────────────────────────────────────────
#
# The manifest declares `pkg wezterm`, which is correct on macOS (brew ships it)
# but NOT on Fedora or stock Ubuntu — neither packages wezterm in their default
# repos. So this fills the gap.
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

# ─── 0xProto Nerd Font ───────────────────────────────────────────────────────
#
# wezterm.lua names '0xProto Nerd Font'; without it wezterm silently falls back
# to its bundled JetBrains Mono, so a failure here degrades looks, not function.
#
# Unlike the wezterm binary below, this download IS safe to hardcode: nerd-fonts'
# `releases/latest/download/<Name>.zip` pattern is distro-independent and stable
# across releases, so there's no per-platform asset name to guess wrong.
if [ "$PM" = brew ]; then
  brew list --cask font-0xproto-nerd-font >/dev/null 2>&1 \
    || brew install --cask font-0xproto-nerd-font
elif command -v fc-list >/dev/null 2>&1; then
  # grep without -q: under pipefail, `grep -q` exits at first match and can
  # SIGPIPE fc-list mid-write, failing the pipeline and re-installing every run.
  if fc-list | grep -i '0xProto Nerd Font' >/dev/null; then
    echo "  ✅ 0xProto Nerd Font (already installed)"
  else
    echo "  installing 0xProto Nerd Font → ~/.local/share/fonts/0xProto"
    font_zip="$(mktemp)"
    if curl -fsSL -o "$font_zip" \
         https://github.com/ryanoasis/nerd-fonts/releases/latest/download/0xProto.zip; then
      mkdir -p "$HOME/.local/share/fonts/0xProto"
      unzip -o -q "$font_zip" -d "$HOME/.local/share/fonts/0xProto"
      fc-cache -f "$HOME/.local/share/fonts/0xProto" >/dev/null 2>&1 || true
      echo "  ✅ 0xProto Nerd Font"
    else
      echo "  ⚠️  0xProto Nerd Font download failed — wezterm falls back to JetBrains Mono"
    fi
    rm -f "$font_zip"
  fi
fi

if command -v wezterm >/dev/null 2>&1; then
  echo "  ✅ wezterm ($(wezterm --version 2>/dev/null | head -1))"
  exit 0
fi

echo ""
echo "  wezterm is not installed and isn't in this platform's default repos."
echo ""
case "$PM" in
  brew)
    echo "    brew install --cask wezterm"
    ;;
  *)
    cat <<'EOF'
    Fedora/RHEL and stock Ubuntu don't package wezterm. Options:

      1. Official instructions:  https://wezterm.org/installation.html

      2. Rootless install (no sudo) — the pattern this machine uses:

           mkdir -p ~/.local/wezterm-root
           # download the .rpm (or .deb) for your distro from
           #   https://github.com/wezterm/wezterm/releases
           rpm2cpio wezterm-*.rpm | (cd ~/.local/wezterm-root && cpio -idmv)
           ln -sf ~/.local/wezterm-root/usr/bin/wezterm{,-gui,-mux-server} ~/.local/bin/

         Useful on a machine where you can't install packages but can write
         to $HOME — the same constraint the section toggles exist for.
EOF
    ;;
esac

echo ""
echo "  NOTE: wezterm.lua declares the 'mux' unix domain the Jarvis sidecar"
echo "        connects to. Installing wezterm-mux-server matters for that, not"
echo "        just the GUI."
echo ""
