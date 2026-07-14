#!/bin/bash
# build-app.sh — Build ZenithOS.app (menu bar) + ZenithOSUI.app (dock) from SPM
# ZenithOSUI.app is nested inside ZenithOS.app/Contents/Applications/ and can be
# dragged to the Dock independently.
#
# Usage: ./build-app.sh

set -e

echo "▶ Building release binaries..."
swift build -c release --product ZenithOS
swift build -c release --product ZenithOSUI

ICON_FILE="Resources/ZenithOSIcon.icns"
if [ ! -f "$ICON_FILE" ]; then
    echo "▶ Generating app icon..."
    python3 scripts/generate-app-icon.py
fi

# ── ZenithOS.app (menu bar daemon) ─────────────────────────────────────────────

BUNDLE="ZenithOS.app/Contents"
rm -rf ZenithOS.app
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources" "$BUNDLE/Applications"

cp .build/release/ZenithOS "$BUNDLE/MacOS/ZenithOS"
cp "$ICON_FILE" "$BUNDLE/Resources/ZenithOSIcon.icns"

cat > "$BUNDLE/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>     <string>com.zenith.ZenithOS</string>
    <key>CFBundleName</key>           <string>ZenithOS</string>
    <key>CFBundleDisplayName</key>    <string>ZenithOS</string>
    <key>CFBundleExecutable</key>     <string>ZenithOS</string>
    <key>CFBundleIconFile</key>       <string>ZenithOSIcon</string>
    <key>CFBundlePackageType</key>    <string>APPL</string>
    <key>CFBundleVersion</key>        <string>1</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key> <string>13.0</string>
    <key>LSUIElement</key>            <true/>
    <key>NSPrincipalClass</key>       <string>NSApplication</string>
    <key>NSMicrophoneUsageDescription</key>
        <string>ZenithOS captures your microphone to transcribe FaceTime calls.</string>
    <key>NSScreenCaptureUsageDescription</key>
        <string>ZenithOS captures FaceTime audio to transcribe calls.</string>
</dict>
</plist>
EOF

# ── ZenithOSUI.app (dock app, nested inside ZenithOS.app) ────────────────────────

UI_BUNDLE="ZenithOS.app/Contents/Applications/ZenithOSUI.app/Contents"
mkdir -p "$UI_BUNDLE/MacOS" "$UI_BUNDLE/Resources"

cp .build/release/ZenithOSUI "$UI_BUNDLE/MacOS/ZenithOSUI"
cp "$ICON_FILE" "$UI_BUNDLE/Resources/ZenithOSIcon.icns"

cat > "$UI_BUNDLE/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>     <string>com.zenith.ZenithOSUI</string>
    <key>CFBundleName</key>           <string>ZenithOS</string>
    <key>CFBundleDisplayName</key>    <string>ZenithOS</string>
    <key>CFBundleExecutable</key>     <string>ZenithOSUI</string>
    <key>CFBundleIconFile</key>       <string>ZenithOSIcon</string>
    <key>CFBundlePackageType</key>    <string>APPL</string>
    <key>CFBundleVersion</key>        <string>1</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>LSMinimumSystemVersion</key> <string>13.0</string>
    <key>NSPrincipalClass</key>       <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key> <true/>
</dict>
</plist>
EOF

# ── Verify bundled dependencies ───────────────────────────────────────────────

# Fail before signing when an executable references a non-system dynamic library
# that was not copied into its app bundle. This turns a launch-time dyld crash
# into an actionable build failure.
echo "▶ Verifying bundled dependencies..."
python3 scripts/verify_app_dependencies.py \
    --contents "$BUNDLE" \
    --executable "$BUNDLE/MacOS/ZenithOS"
python3 scripts/verify_app_dependencies.py \
    --contents "$UI_BUNDLE" \
    --executable "$UI_BUNDLE/MacOS/ZenithOSUI"

# ── Sign both ─────────────────────────────────────────────────────────────────

echo "▶ Signing..."
# Sign nested app first, then the outer bundle
codesign --force --sign - \
    "ZenithOS.app/Contents/Applications/ZenithOSUI.app"
codesign --force --sign - --entitlements ZenithOS.entitlements \
    "ZenithOS.app"

echo ""
echo "✓ Done"
echo ""
echo "  Run menu bar app:   open ZenithOS.app"
echo "  Run dock app:       open ZenithOS.app/Contents/Applications/ZenithOSUI.app"
echo ""
echo "  Add to Dock (one-time):"
echo "    Right-click ZenithOS.app → Show Package Contents"
echo "    → Contents/Applications/ZenithOSUI.app → drag to Dock"
echo ""
echo "  Install both:"
echo "    cp -r ZenithOS.app /Applications/"
echo "    Then drag /Applications/ZenithOS.app/Contents/Applications/ZenithOSUI.app to Dock"
