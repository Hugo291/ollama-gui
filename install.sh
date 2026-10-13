#!/bin/sh
# Installs the latest release of Ollama GUI, or updates it, then opens it.
#
#   curl -fsSL https://raw.githubusercontent.com/Hugo291/ollama-gui/main/install.sh | sh
#
# OLLAMA_GUI_DIR=~/Applications chooses another folder than /Applications.
set -eu

# In a function, so that a download cut short runs nothing.
main() {
    [ "$(uname -s)" = Darwin ] || { echo "Ollama GUI is a macOS app." >&2; exit 1; }

    dest="${OLLAMA_GUI_DIR:-}"
    if [ -z "$dest" ]; then
        dest=/Applications
        # Standard accounts cannot write there.
        [ -w "$dest" ] || dest="$HOME/Applications"
    fi
    mkdir -p "$dest"
    app="$dest/Ollama GUI.app"

    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT

    echo "Downloading Ollama GUI…"
    curl -fL --progress-bar -o "$tmp/app.zip" \
        https://github.com/Hugo291/ollama-gui/releases/latest/download/OllamaGUI-macOS.zip
    ditto -x -k "$tmp/app.zip" "$tmp"

    # Only the copy being replaced is closed.
    if [ -d "$app" ]; then
        pkill -f "$app/Contents/MacOS/OllamaGUI" || true
        rm -rf "$app"
    fi
    mv "$tmp/Ollama GUI.app" "$app"

    echo "Ollama GUI $(defaults read "$app/Contents/Info" CFBundleShortVersionString) is installed in $dest."
    open "$app"
}

main
