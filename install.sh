#!/usr/bin/env bash
set -euo pipefail

#####################################################################
# ~/.dotfiles/install.sh
#
# Symlinks dotfiles into place. Safe to re-run — skips existing links,
# backs up existing files.
#
# Usage:
#   git clone https://github.com/roest1/dotfiles.git ~/.dotfiles
#   cd ~/.dotfiles
#   ./install.sh
#####################################################################

DOTFILES_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$HOME/.dotfiles_backup/$(date +%Y%m%d_%H%M%S)"

# ─── Helpers ──────────────────────────────────────────────────────

link_file() {
  local src="$1"
  local dest="$2"

  # Already linked correctly
  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    echo "  ✅ $dest"
    return
  fi

  # Existing file/dir — back it up
  if [[ -e "$dest" || -L "$dest" ]]; then
    mkdir -p "$BACKUP_DIR"
    mv "$dest" "$BACKUP_DIR/"
    echo "  📦 Backed up existing $dest → $BACKUP_DIR/"
  fi

  # Ensure parent directory exists
  mkdir -p "$(dirname "$dest")"

  ln -s "$src" "$dest"
  echo "  🔗 $dest → $src"
}

echo ""
echo "🔧 Installing dotfiles from $DOTFILES_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ─── Bash config ──────────────────────────────────────────────────

echo ""
echo "📂 Bash:"

link_file "$DOTFILES_DIR/bash/bashrc"                  "$HOME/.bashrc"
link_file "$DOTFILES_DIR/bash/bash_roest_theme"        "$HOME/.bash_roest_theme"
link_file "$DOTFILES_DIR/bash/bash_roest_productivity" "$HOME/.bash_roest_productivity"
link_file "$DOTFILES_DIR/bash/bash_roest_git"          "$HOME/.bash_roest_git"

# Password commands (if it exists — not tracked in public repo)
if [[ -f "$DOTFILES_DIR/bash/bash_roest_password_commands" ]]; then
  link_file "$DOTFILES_DIR/bash/bash_roest_password_commands" "$HOME/.bash_roest_password_commands"
fi

# ─── Neovim config ────────────────────────────────────────────────

echo ""
echo "📂 Neovim:"

# Nvim config is its own repo — just symlink if not already cloned there
if [[ -d "$HOME/.config/nvim/.git" ]]; then
  echo "  ✅ ~/.config/nvim (separate git repo, skipping)"
else
  link_file "$DOTFILES_DIR/nvim" "$HOME/.config/nvim"
fi

# ─── Git config ───────────────────────────────────────────────────

echo ""
echo "📂 Git:"

if [[ -f "$DOTFILES_DIR/git/gitconfig" ]]; then
  link_file "$DOTFILES_DIR/git/gitconfig" "$HOME/.gitconfig"
fi

# ─── Summary ──────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ -d "$BACKUP_DIR" ]]; then
  echo "⚠️  Backed up existing files to: $BACKUP_DIR"
fi

echo "✅ Done! Restart your shell or run: source ~/.bashrc"
echo ""
