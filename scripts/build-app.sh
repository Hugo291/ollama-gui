#!/usr/bin/env bash
# Builds "Ollama GUI.app" (universal arm64 + x86_64) into dist/, plus a zip for releases.
#
#   scripts/build-app.sh                  # release build, version from VERSION
#   ARCHS=arm64 scripts/build-app.sh      # faster, Apple silicon only
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Ollama GUI"
EXECUTABLE="OllamaGUI"
VERSION="${VERSION:-$(cat VERSION)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
read -r -a ARCH_LIST <<< "${ARCHS:-arm64 x86_64}"
DIST="dist"
APP="$DIST/$APP_NAME.app"

source scripts/sdk.sh

ARGS=(-c release)
for arch in "${ARCH_LIST[@]}"; do ARGS+=(--arch "$arch"); done
ARGS+=(${SDK_ARGS[@]+"${SDK_ARGS[@]}"})

echo "▸ Building $APP_NAME $VERSION ($BUILD_NUMBER) for ${ARCH_LIST[*]}"
swift build "${ARGS[@]}"
BIN_DIR="$(swift build "${ARGS[@]}" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD_NUMBER/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lproj in Resources/*.lproj; do
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# Record the SDK actually used (SwiftPM stamps the deployment target instead), so that
# recent macOS versions give the app their current look.
SDK_VERSION="$(xcrun --sdk "${SDKROOT:-macosx}" --show-sdk-version 2>/dev/null || true)"
if [[ -n "$SDK_VERSION" ]] && command -v vtool >/dev/null; then
    vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
fi

echo "▸ Signing (${CODESIGN_IDENTITY:-ad-hoc})"
codesign --force --timestamp=none --sign "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"

# A stable name, so that the "latest release" download links keep working.
ZIP="$DIST/OllamaGUI-macOS.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "✓ $APP"
echo "✓ $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
