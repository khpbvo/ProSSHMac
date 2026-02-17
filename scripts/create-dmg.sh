#!/usr/bin/env bash
#
# create-dmg.sh — Build ProSSHMac.app and package it into a DMG installer.
#
# Usage:
#   ./scripts/create-dmg.sh                      # Unsigned (development)
#   ./scripts/create-dmg.sh --sign                # Signed + notarized (release)
#
# Requirements for signed builds:
#   - Apple Developer Program membership ($99/year)
#   - "Developer ID Application" certificate installed in Keychain
#   - Set these environment variables (or edit the defaults below):
#       DEVELOPER_ID_APP    — signing identity, e.g. "Developer ID Application: Your Name (TEAMID)"
#       APPLE_ID            — Apple ID email for notarization
#       APPLE_TEAM_ID       — 10-character team ID
#       APPLE_APP_PASSWORD  — app-specific password (create at appleid.apple.com)
#

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

APP_NAME="ProSSHMac"
SCHEME="ProSSHMac"
PROJECT="ProSSHMac.xcodeproj"
CONFIGURATION="Release"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build/dmg"
ARCHIVE_PATH="${BUILD_DIR}/${APP_NAME}.xcarchive"
EXPORT_PATH="${BUILD_DIR}/export"
DMG_DIR="${BUILD_DIR}/dmg-staging"
OUTPUT_DIR="${PROJECT_ROOT}/build"

SIGN=false

# ── Parse arguments ────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sign) SIGN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

info()  { echo "==> $*"; }
error() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    rm -rf "$DMG_DIR"
}
trap cleanup EXIT

# ── Preflight checks ──────────────────────────────────────────────────────────

if $SIGN; then
    [[ -z "${DEVELOPER_ID_APP:-}" ]] && error "Set DEVELOPER_ID_APP (e.g. 'Developer ID Application: Your Name (TEAMID)')"
    [[ -z "${APPLE_ID:-}" ]]         && error "Set APPLE_ID (your Apple ID email)"
    [[ -z "${APPLE_TEAM_ID:-}" ]]    && error "Set APPLE_TEAM_ID (10-character team ID)"
    [[ -z "${APPLE_APP_PASSWORD:-}" ]] && error "Set APPLE_APP_PASSWORD (app-specific password from appleid.apple.com)"
fi

# ── Clean previous build ──────────────────────────────────────────────────────

info "Cleaning previous build artifacts..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

# ── Archive ────────────────────────────────────────────────────────────────────

info "Archiving ${APP_NAME}..."
xcodebuild archive \
    -project "${PROJECT_ROOT}/${PROJECT}" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    SKIP_INSTALL=NO \
    BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
    | tail -5

[[ -d "$ARCHIVE_PATH" ]] || error "Archive failed — ${ARCHIVE_PATH} not found"

# ── Export ─────────────────────────────────────────────────────────────────────

info "Exporting app..."

if $SIGN; then
    # Create export options plist for signed export
    EXPORT_PLIST="${BUILD_DIR}/ExportOptions.plist"
    cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${DEVELOPER_ID_APP}</string>
    <key>teamID</key>
    <string>${APPLE_TEAM_ID}</string>
</dict>
</plist>
PLIST

    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_PLIST" \
        | tail -5
else
    # For unsigned builds, just copy the .app out of the archive
    mkdir -p "$EXPORT_PATH"
    cp -R "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$EXPORT_PATH/"
fi

APP_PATH="${EXPORT_PATH}/${APP_NAME}.app"
[[ -d "$APP_PATH" ]] || error "Export failed — ${APP_PATH} not found"

# ── Notarize (signed builds only) ─────────────────────────────────────────────

if $SIGN; then
    info "Notarizing ${APP_NAME}.app (this may take a few minutes)..."

    # Create a zip for notarization
    NOTARIZE_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "$APPLE_ID" \
        --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --wait

    info "Stapling notarization ticket..."
    xcrun stapler staple "$APP_PATH"

    rm -f "$NOTARIZE_ZIP"
fi

# ── Create DMG ─────────────────────────────────────────────────────────────────

info "Creating DMG..."

mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/"

# Create a symlink to /Applications for drag-and-drop install
ln -s /Applications "$DMG_DIR/Applications"

# Get version from Info.plist
VERSION=$(defaults read "$APP_PATH/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="${OUTPUT_DIR}/${DMG_NAME}"

# Remove existing DMG if present
rm -f "$DMG_PATH"

# Create the DMG
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# ── Sign the DMG itself (signed builds only) ──────────────────────────────────

if $SIGN; then
    info "Signing DMG..."
    codesign --force --sign "$DEVELOPER_ID_APP" "$DMG_PATH"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)

echo ""
echo "================================================"
echo "  DMG created successfully!"
echo "  ${DMG_PATH}"
echo "  Size: ${DMG_SIZE}"
if $SIGN; then
    echo "  Signed + Notarized"
else
    echo "  Unsigned (development build)"
fi
echo "================================================"
