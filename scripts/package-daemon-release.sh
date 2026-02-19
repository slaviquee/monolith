#!/bin/bash
# package-daemon-release.sh
# Build/sign/notarize a Monolith daemon installer package for release.
#
# Usage:
#   ./scripts/package-daemon-release.sh [version]
#
# Defaults:
#   version=0.1.2
#   app cert:   Developer ID Application: Denis Kostikov (Q4E837WNXN)
#   pkg cert:   Developer ID Installer: Denis Kostikov (Q4E837WNXN)
#   notary profile: clawvault-notary

set -euo pipefail

VERSION="${1:-0.1.2}"
APP_SIGN_ID="${APP_SIGN_ID:-Developer ID Application: Denis Kostikov (Q4E837WNXN)}"
PKG_SIGN_ID="${PKG_SIGN_ID:-Developer ID Installer: Denis Kostikov (Q4E837WNXN)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-clawvault-notary}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."
DIST_DIR="$REPO_ROOT/dist"
RELEASE_DIR="$DIST_DIR/release"
PKGROOT_DIR="$DIST_DIR/pkgbuild/root"
PKGSCRIPTS_DIR="$DIST_DIR/pkgbuild/scripts"

DAEMON_DIR="$REPO_ROOT/daemon"
DAEMON_BIN="$DAEMON_DIR/.build/release/MonolithDaemon"
DAEMON_ENTITLEMENTS="$DAEMON_DIR/MonolithDaemon.entitlements"
LAUNCHD_PLIST="$DAEMON_DIR/com.monolith.daemon.plist"
POSTINSTALL_SRC="$REPO_ROOT/scripts/daemon-postinstall.sh"

mkdir -p "$RELEASE_DIR" "$PKGROOT_DIR/usr/local/bin" "$PKGROOT_DIR/Library/LaunchAgents" "$PKGSCRIPTS_DIR"

echo "Building release daemon binary..."
(
  cd "$DAEMON_DIR"
  swift build -c release
)

if [ ! -f "$DAEMON_BIN" ]; then
  echo "ERROR: Missing daemon binary at $DAEMON_BIN" >&2
  exit 1
fi

cp "$DAEMON_BIN" "$RELEASE_DIR/MonolithDaemon"
cp "$DAEMON_BIN" "$PKGROOT_DIR/usr/local/bin/MonolithDaemon"
cp "$LAUNCHD_PLIST" "$PKGROOT_DIR/Library/LaunchAgents/com.monolith.daemon.plist"
cp "$POSTINSTALL_SRC" "$PKGSCRIPTS_DIR/postinstall"
chmod 755 "$PKGSCRIPTS_DIR/postinstall"

echo "Signing daemon binaries..."
codesign --force --options runtime --timestamp --entitlements "$DAEMON_ENTITLEMENTS" --sign "$APP_SIGN_ID" "$RELEASE_DIR/MonolithDaemon"
codesign --force --options runtime --timestamp --entitlements "$DAEMON_ENTITLEMENTS" --sign "$APP_SIGN_ID" "$PKGROOT_DIR/usr/local/bin/MonolithDaemon"

UNSIGNED_PKG="$RELEASE_DIR/MonolithDaemon-v$VERSION-unsigned.pkg"
SIGNED_PKG="$RELEASE_DIR/MonolithDaemon-v$VERSION.pkg"
ALIAS_PKG="$RELEASE_DIR/MonolithDaemon.pkg"

echo "Building installer package..."
pkgbuild \
  --root "$PKGROOT_DIR" \
  --scripts "$PKGSCRIPTS_DIR" \
  --identifier "com.monolith.daemon" \
  --version "$VERSION" \
  --install-location "/" \
  "$UNSIGNED_PKG"

echo "Signing installer package..."
productsign --sign "$PKG_SIGN_ID" "$UNSIGNED_PKG" "$SIGNED_PKG"

echo "Notarizing package..."
xcrun notarytool submit "$SIGNED_PKG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$SIGNED_PKG"
xcrun stapler validate "$SIGNED_PKG"

cp "$SIGNED_PKG" "$ALIAS_PKG"
ditto -c -k --keepParent "$RELEASE_DIR/MonolithDaemon" "$RELEASE_DIR/MonolithDaemon.zip"

echo "Done. Artifacts:"
ls -lah "$RELEASE_DIR" | rg "MonolithDaemon"
