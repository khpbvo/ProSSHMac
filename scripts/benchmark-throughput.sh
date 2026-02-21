#!/bin/bash
#
# benchmark-throughput.sh
#
# Builds ProSSHMac (Debug) and runs the in-app base64 throughput benchmark mode.
#
# Usage:
#   ./scripts/benchmark-throughput.sh [--no-build] [benchmark args...]
#
# Examples:
#   ./scripts/benchmark-throughput.sh
#   ./scripts/benchmark-throughput.sh --benchmark-bytes 33554432 --benchmark-runs 5

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="ProSSHMac"
APP_NAME="ProSSHMac"
NO_BUILD=0

if [[ "${1:-}" == "--no-build" ]]; then
    NO_BUILD=1
    shift
fi

echo "==> ProSSHMac Throughput Benchmark"
echo ""

if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "==> Building $SCHEME..."
    xcodebuild \
        -project "$PROJECT_DIR/ProSSHMac.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination 'platform=macOS' \
        build \
        2>&1 | tail -3
fi

DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData"
APP_PATH=$(find "$DERIVED_DATA" -path "*/ProSSHMac-*/Build/Products/Debug/$APP_NAME.app" -type d -maxdepth 5 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built $APP_NAME.app in DerivedData"
    exit 1
fi

echo "    Built: $APP_PATH"
echo ""
echo "==> Running benchmark..."
echo ""

pkill -9 -x "$APP_NAME" 2>/dev/null || true
sleep 1

"$APP_PATH/Contents/MacOS/$APP_NAME" --benchmark-base64 "$@"
