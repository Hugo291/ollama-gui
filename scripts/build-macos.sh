#!/usr/bin/env bash
# Builds "Ollama GUI.app" (universal: Apple Silicon + Intel) and dist/OllamaGUI-macOS.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' Cargo.toml | head -1)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="dist/Ollama GUI.app"

for target in aarch64-apple-darwin x86_64-apple-darwin; do
    rustup target add "$target" >/dev/null 2>&1 || true
    MACOSX_DEPLOYMENT_TARGET=11.0 cargo build --release --locked --target "$target"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/ollama-gui" \
    target/aarch64-apple-darwin/release/ollama-gui \
    target/x86_64-apple-darwin/release/ollama-gui
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" packaging/macos/Info.plist > "$APP/Contents/Info.plist"
cp packaging/macos/AppIcon.icns "$APP/Contents/Resources/"
cp -R packaging/macos/en.lproj packaging/macos/fr.lproj "$APP/Contents/Resources/"

# Ad-hoc signature: required to run on Apple Silicon. Not notarized.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

rm -f dist/OllamaGUI-macOS.zip
ditto -c -k --keepParent "$APP" dist/OllamaGUI-macOS.zip
lipo -archs "$APP/Contents/MacOS/ollama-gui"
echo "✓ $APP ($VERSION), dist/OllamaGUI-macOS.zip ($(du -h dist/OllamaGUI-macOS.zip | cut -f1))"
