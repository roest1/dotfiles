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

echo "🎉 All done!"

