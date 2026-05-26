#!/usr/bin/env bash
# release.sh — build a signed ZenithOSUI.app for local use
# Ad-hoc signing (sign with -) — no Apple developer account needed.
# Run from the ZenithOS package root.

set -euo pipefail

PRODUCT=ZenithOSUI
BUILD_DIR=".build/arm64-apple-macosx/release"
APP_DIR="release/${PRODUCT}.app"
CONTENTS="${APP_DIR}/Contents"

echo "▶ Building ${PRODUCT} (release)…"
swift build -c release --product "${PRODUCT}"

ICON_FILE="Resources/ZenithOSIcon.icns"
if [ ! -f "${ICON_FILE}" ]; then
  echo "▶ Generating app icon…"
  python3 scripts/generate-app-icon.py
fi

echo "▶ Assembling .app bundle…"
rm -rf "${APP_DIR}"
mkdir -p "${CONTENTS}/MacOS"
mkdir -p "${CONTENTS}/Resources"

# Binary
cp "${BUILD_DIR}/${PRODUCT}" "${CONTENTS}/MacOS/${PRODUCT}"
cp "${ICON_FILE}" "${CONTENTS}/Resources/ZenithOSIcon.icns"

# Info.plist — tells macOS this is a proper app
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>       <string>${PRODUCT}</string>
  <key>CFBundleIconFile</key>         <string>ZenithOSIcon</string>
  <key>CFBundleIdentifier</key>       <string>ca.zenith.${PRODUCT}</string>
  <key>CFBundleName</key>             <string>${PRODUCT}</string>
  <key>CFBundlePackageType</key>      <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key>          <string>1</string>
  <key>LSMinimumSystemVersion</key>   <string>13.0</string>
  <key>NSPrincipalClass</key>         <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>  <true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
  <!-- Microphone access for audio capture -->
  <key>NSMicrophoneUsageDescription</key>
  <string>ZenithOS uses the microphone for FaceTime transcript capture.</string>
  <!-- Screen recording for SCStream -->
  <key>NSScreenCaptureUsageDescription</key>
  <string>ZenithOS captures system audio to generate transcripts.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign — no Developer ID needed; prevents "app is damaged" on first run
echo "▶ Signing (ad-hoc)…"
codesign --force --deep --sign - "${APP_DIR}"

# Remove quarantine if it crept in during the build
xattr -dr com.apple.quarantine "${APP_DIR}" 2>/dev/null || true

echo "✓ Built: ${APP_DIR}"
echo "  Open with: open ${APP_DIR}"
