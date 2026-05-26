#!/bin/bash
# build.sh — build both ZenithOS targets, update the app bundle, and re-sign
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$REPO/ZenithOS.app"
UI_BUNDLE="$BUNDLE/Contents/Applications/ZenithOSUI.app"

MODE="${1:-release}"

echo "▸ Building ($MODE)..."
swift build -c "$MODE"

BUILD="$REPO/.build/arm64-apple-macosx/$MODE"

echo "▸ Copying binaries into bundle..."
cp "$BUILD/ZenithOS"   "$BUNDLE/Contents/MacOS/ZenithOS"
cp "$BUILD/ZenithOSUI" "$UI_BUNDLE/Contents/MacOS/ZenithOSUI"

echo "▸ Re-signing (ad-hoc, inner first)..."
rm -rf "$BUNDLE/Contents/_CodeSignature"
rm -rf "$UI_BUNDLE/Contents/_CodeSignature"
codesign --force --sign - "$UI_BUNDLE"
codesign --force --sign - "$BUNDLE"

echo "✓ Done"
echo "  Hub UI:  open \"$UI_BUNDLE\""
echo "  Daemon:  open \"$BUNDLE\""
