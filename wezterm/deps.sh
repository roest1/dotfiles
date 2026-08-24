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

# ─── WSL: this section belongs to the Windows host ───────────────────────────
#
# WSL passes every test the rest of this file makes — uname says Linux, $PM is
# apt — and the terminal still isn't in here. wezterm.exe runs on the host and
# draws the pixels; the guest only writes escape sequences into it. So a wezterm
# installed in the guest is a GUI nothing launches, and fonts installed into the
# guest's fontconfig are glyphs nothing renders — both have to exist on the
# WINDOWS side, which is what windows/deps.ps1 and the wezterm\fonts entry in
# windows/install.ps1 are for.
#
# The config links are deliberately NOT skipped, and they are made by install.sh
# before this ever runs. wezterm.lua declares the `mux` unix domain, whose socket
# path is a Linux path belonging to a process inside the guest, so a
# wezterm-mux-server run in here still reads it. Only the downloads and the
# install advice are dropped.
if is_wsl; then
  echo "  ↷ WSL — wezterm belongs to the Windows host, not this guest."
  echo ""
  echo "    Install it from PowerShell on Windows, not from in here:"
  echo "      irm https://raw.githubusercontent.com/roest1/dotfiles/main/bootstrap.ps1 | iex"
  echo ""
  echo "    That links wezterm-windows.lua and the fonts on the host side and"
  echo "    installs wezterm with winget. See windows/README.md."
  echo ""
  echo "    Skipped in the guest: the wezterm binary, 0xProto Nerd Font and"
  echo "    Science Gothic. The config links are still made — wezterm.lua's"
  echo "    'mux' unix domain is a guest path, so a wezterm-mux-server running"
  echo "    in here still uses it."
  exit 0
fi

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

# ─── JetBrainsMono Nerd Font ─────────────────────────────────────────────────
#
# The `editor` lane's default — the font wezterm.lua's SGR 5 font_rules put the
# file you are editing in nvim into. Same nerd-fonts release pattern as 0xProto
# above, and the same bargain: without it the rules fall through to wezterm's
# bundled 'JetBrains Mono', which is the same typeface without the patched icon
# glyphs, so `font editor` still works and the editor still renders.
#
# Not merely a fallback any more, which is the change worth noticing. This
# family used to appear only as the second entry in config.font's chain, where
# it was what you got when 0xProto was missing. Now it is a named default that
# a correctly installed machine actually renders with, so it earns an install
# of its own rather than riding on wezterm's bundled copy.
if [ "$PM" = brew ]; then
  brew list --cask font-jetbrains-mono-nerd-font >/dev/null 2>&1 \
    || brew install --cask font-jetbrains-mono-nerd-font
elif command -v fc-list >/dev/null 2>&1; then
  # grep without -q, for the SIGPIPE reason spelled out above.
  if fc-list | grep -i 'JetBrainsMono Nerd Font' >/dev/null; then
    echo "  ✅ JetBrainsMono Nerd Font (already installed)"
  else
    echo "  installing JetBrainsMono Nerd Font → ~/.local/share/fonts/JetBrainsMono"
    jb_zip="$(mktemp)"
    if curl -fsSL -o "$jb_zip" \
         https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.zip; then
      mkdir -p "$HOME/.local/share/fonts/JetBrainsMono"
      unzip -o -q "$jb_zip" -d "$HOME/.local/share/fonts/JetBrainsMono"
      fc-cache -f "$HOME/.local/share/fonts/JetBrainsMono" >/dev/null 2>&1 || true
      echo "  ✅ JetBrainsMono Nerd Font"
    else
      echo "  ⚠️  JetBrainsMono Nerd Font download failed — the editor lane falls back to JetBrains Mono"
    fi
    rm -f "$jb_zip"
  fi
fi

# ─── IosevkaTerm Nerd Font ───────────────────────────────────────────────────
#
# The `claude` lane. Claude Code's TUI draws U+23FA (the tool-call bullet) and
# U+23BF (the tool-result elbow) on EVERY tool call, plus U+2733 and the
# U+25D0-D3 spinner -- Misc Technical and Dingbats codepoints that coding fonts
# routinely skip. Measured against the font files: neither 0xProto nor
# JetBrainsMono carries either of the two per-tool-call glyphs. They fall
# through to STIX Two Math, Noto Serif CJK and Symbola, and come back WIDER
# THAN THE CELL -- U+23BF at 16 units in a 10-unit cell.
#
# Count them flat and this looks survivable, which is the trap: Fira Code has
# five of the nine and none of the two that matter. wezterm/fontpreview.py
# scores them in tiers for that reason.
#
# IosevkaTerm is the only family tested that carries all nine natively AND
# keeps the Nerd Font icons at exact cell width. Adwaita Mono covers the nine
# too but has no patched icons, so those fall back 25% oversized.
#
# Note the advance: 0.50em against 0xProto's 0.62em. Deliberate -- Iosevka's
# terminal cut is narrow. It is fine for `claude`, and it is the wrong choice
# for `ui` while `editor` is a 0.60em font, because the editor lane draws inside
# the base lane's cell and a wider glyph in a narrower cell collides. Same
# arithmetic mkmono.py exists to satisfy.
if [ "$PM" = brew ]; then
  brew list --cask font-iosevka-term-nerd-font >/dev/null 2>&1 \
    || brew install --cask font-iosevka-term-nerd-font
elif command -v fc-list >/dev/null 2>&1; then
  # grep without -q, for the SIGPIPE reason spelled out above.
  if fc-list | grep -i 'IosevkaTerm Nerd Font' >/dev/null; then
    echo "  ✅ IosevkaTerm Nerd Font (already installed)"
  else
    echo "  installing IosevkaTerm Nerd Font → ~/.local/share/fonts/IosevkaTerm"
    io_zip="$(mktemp)"
    if curl -fsSL -o "$io_zip" \
         https://github.com/ryanoasis/nerd-fonts/releases/latest/download/IosevkaTerm.zip; then
      mkdir -p "$HOME/.local/share/fonts/IosevkaTerm"
      unzip -o -q "$io_zip" -d "$HOME/.local/share/fonts/IosevkaTerm"
      fc-cache -f "$HOME/.local/share/fonts/IosevkaTerm" >/dev/null 2>&1 || true
      echo "  ✅ IosevkaTerm Nerd Font"
    else
      echo "  ⚠️  IosevkaTerm Nerd Font download failed — the claude lane falls back to its default"
    fi
    rm -f "$io_zip"
  fi
fi

# ─── Science Gothic (tab bar font) ────────────────────────────────────────
#
# wezterm.lua's window_frame.font names 'Science Gothic'; without it wezterm
# falls back to 0xProto for the tab bar, so a failure here degrades looks,
# not function.
#
# A Google Fonts family (OFL-licensed), pulled from google/fonts' own repo
# rather than fonts.google.com — the latter has no stable direct-download
# URL, while raw.githubusercontent.com/google/fonts is a stable, checksum-free
# but content-addressed-by-path source that doesn't change under a family
# once published.
if command -v fc-list >/dev/null 2>&1; then
  if fc-list | grep -i 'Science Gothic' >/dev/null; then
    echo "  ✅ Science Gothic (already installed)"
  else
    echo "  installing Science Gothic → ~/.local/share/fonts/ScienceGothic"
    sg_font="$(mktemp)"
    if curl -fsSL -o "$sg_font" \
         "https://raw.githubusercontent.com/google/fonts/main/ofl/sciencegothic/ScienceGothic%5BCTRS,slnt,wdth,wght%5D.ttf"; then
      mkdir -p "$HOME/.local/share/fonts/ScienceGothic"
      cp "$sg_font" "$HOME/.local/share/fonts/ScienceGothic/ScienceGothic.ttf"
      fc-cache -f "$HOME/.local/share/fonts/ScienceGothic" >/dev/null 2>&1 || true
      echo "  ✅ Science Gothic"
    else
      echo "  ⚠️  Science Gothic download failed — tab bar falls back to 0xProto"
    fi
    rm -f "$sg_font"
  fi
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
