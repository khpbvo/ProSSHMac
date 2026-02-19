#!/bin/bash
#
# take-screenshots.sh
#
# Builds ProSSHMac in screenshot mode, launches it with sample data.
# The app self-navigates through each tab, captures window screenshots
# to the Screenshots/ directory, and quits automatically.
#
# Usage:
#   ./scripts/take-screenshots.sh
#
# Output:
#   Screenshots are saved to the Screenshots/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCREENSHOTS_DIR="$PROJECT_DIR/Screenshots"
SCHEME="ProSSHMac"
APP_NAME="ProSSHMac"

echo "==> ProSSHMac Screenshot Generator"
echo ""

# Ensure Screenshots directory exists
mkdir -p "$SCREENSHOTS_DIR"

# Clean previous screenshots and done marker
rm -f "$SCREENSHOTS_DIR"/*.png
rm -f "$SCREENSHOTS_DIR/.screenshots-done"
echo "    Cleaned previous screenshots."

# ── Step 1: Build the app ───────────────────────────────────────────
echo ""
echo "==> Building $SCHEME..."

xcodebuild \
    -project "$PROJECT_DIR/ProSSHMac.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS' \
    build \
    2>&1 | tail -3

# Find the built app in Xcode's default DerivedData
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
APP_PATH=$(find "$DERIVED_DATA" -path "*/ProSSHMac-*/Build/Products/Debug/$APP_NAME.app" -type d -maxdepth 5 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built $APP_NAME.app in DerivedData"
    exit 1
fi
echo "    Built: $APP_PATH"

# ── Step 2: Launch app in screenshot mode ───────────────────────────
echo ""
echo "==> Launching $APP_NAME in screenshot mode..."

# Force kill any existing instance
pkill -9 -x "$APP_NAME" 2>/dev/null || true
sleep 1

# Launch the binary directly (not via `open`) so launch arguments are passed reliably
"$APP_PATH/Contents/MacOS/$APP_NAME" --screenshot-mode --screenshot-dir "$SCREENSHOTS_DIR" &
APP_PID=$!

echo "    App is navigating tabs and capturing screenshots (PID $APP_PID)..."

# ── Step 3: Wait for the app to finish ──────────────────────────────

TIMEOUT=60
ELAPSED=0
while [ ! -f "$SCREENSHOTS_DIR/.screenshots-done" ] && [ $ELAPSED -lt $TIMEOUT ]; do
    sleep 1
    ELAPSED=$((ELAPSED + 1))
    # Show progress dots
    if [ $((ELAPSED % 5)) -eq 0 ]; then
        echo "    ... waiting (${ELAPSED}s)"
    fi
done

# Clean up the done marker
rm -f "$SCREENSHOTS_DIR/.screenshots-done"

if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "    WARNING: Timed out waiting for screenshots (${TIMEOUT}s)."
    kill -9 "$APP_PID" 2>/dev/null || true
fi

# Give the app a moment to terminate gracefully
sleep 2
kill "$APP_PID" 2>/dev/null || true

# ── Step 4: Report results ──────────────────────────────────────────

SCREENSHOT_COUNT=$(ls -1 "$SCREENSHOTS_DIR"/*.png 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "==> Done! $SCREENSHOT_COUNT screenshots saved to Screenshots/"
echo ""
ls -lh "$SCREENSHOTS_DIR"/*.png 2>/dev/null || echo "    (no screenshots found)"
