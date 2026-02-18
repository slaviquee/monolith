#!/bin/bash
# package-companion-dev.sh — Create a runnable .app bundle for the SwiftPM
# companion binary and ad-hoc sign it so macOS notification APIs are allowed.
#
# Usage:
#   ./scripts/package-companion-dev.sh
#   ./scripts/package-companion-dev.sh --open
#
# Note: Run after `cd companion && swift build`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
COMPANION_DIR="$REPO_ROOT/companion"

BINARY="$COMPANION_DIR/.build/debug/ClawVaultCompanion"
INFO_PLIST="$COMPANION_DIR/ClawVaultCompanion/Resources/Info.plist"
APP_BUNDLE="$COMPANION_DIR/.build/debug/ClawVaultCompanion.app"

if [ ! -f "$BINARY" ]; then
    echo "ERROR: Companion binary not found at $BINARY"
    echo "Run 'cd companion && swift build' first."
    exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "ERROR: Info.plist not found at $INFO_PLIST"
    exit 1
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/ClawVaultCompanion"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
chmod +x "$APP_BUNDLE/Contents/MacOS/ClawVaultCompanion"

echo "Ad-hoc signing app bundle..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Companion app bundle is ready:"
echo "  $APP_BUNDLE"

if [[ "${1:-}" == "--open" ]]; then
    echo "Opening app..."
    open "$APP_BUNDLE"
fi
