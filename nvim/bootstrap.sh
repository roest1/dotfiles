#!/usr/bin/env bash

echo "🔧 Installing external tools from reqs.lua..."

# Extract tool names from reqs.lua by looking for strings wrapped in single quotes
tools=$(grep -oP "'\K[^']+" lua/external/reqs.lua)

# Loop through each tool name in the extracted list
for tool in $tools; do
  # Check if the tool is already available in the system's PATH
  if ! command -v "$tool" >/dev/null 2>&1; then
    # If not installed, print a message and try to install it using a package manager

    echo "➡️ Installing $tool..."

    # Check if Homebrew is installed (macOS and Linux)
    if command -v brew >/dev/null 2>&1; then
      brew install "$tool"

    # Else, check if apt is available (typical for Ubuntu/WSL)
    elif command -v apt >/dev/null 2>&1; then
      sudo apt install -y "$tool"
    
    # Else, check if dnf is available (RHEL)
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y "$tool"

    else
      # If no supported package manager is found, warn the user
      echo "❌ No supported package manager found for $tool"
    fi

  else
    # If the tool is already installed, print a success message
    echo "✅ $tool is already installed."
  fi
done

###############################################
# 🟦 WSL-SPECIFIC CLIPBOARD SUPPORT (win32yank)
###############################################
echo ""
echo "🔍 Checking for WSL clipboard support..."

# Detect WSL by checking /proc/version
if grep -qi "microsoft" /proc/version; then
  echo "💠 WSL detected — ensuring win32yank clipboard provider is installed"

  WIN32YANK="$HOME/.local/bin/win32yank.exe"

  # Create bin directory if not present
  mkdir -p "$HOME/.local/bin"

  # Install win32yank only if missing
  if [ ! -f "$WIN32YANK" ]; then
    echo "➡️ Downloading win32yank.exe..."
    curl -sLo "$WIN32YANK" \
      https://github.com/equalsraf/win32yank/releases/download/v0.1.1/win32yank-x64.exe

    chmod +x "$WIN32YANK"
    echo "✅ win32yank.exe installed at $WIN32YANK"
  else
    echo "✅ win32yank.exe already present at $WIN32YANK"
  fi

  # Ensure ~/.local/bin is on PATH
  if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
    echo "🔧 Adding ~/.local/bin to PATH (you may need to re-source your shell)"
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
  fi

else
  echo "ℹ️ Not running inside WSL — skipping win32yank installation."
fi

echo ""
echo "🎉 All done!"

