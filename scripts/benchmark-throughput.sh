#!/bin/bash
#
# benchmark-throughput.sh
#
# Builds ProSSHMac (Debug) and runs the in-app throughput benchmark mode.
#
# Usage:
#   ./scripts/benchmark-throughput.sh [--no-build] [--pty-local] [benchmark args...]
#
# Examples:
#   ./scripts/benchmark-throughput.sh
#   ./scripts/benchmark-throughput.sh --benchmark-bytes 33554432 --benchmark-runs 5
#   ./scripts/benchmark-throughput.sh --pty-local --no-build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="ProSSHMac"
APP_NAME="ProSSHMac"
NO_BUILD=0
PTY_LOCAL=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build)
            NO_BUILD=1
            shift
            ;;
        --pty-local)
            PTY_LOCAL=1
            shift
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

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

if [[ "$PTY_LOCAL" -eq 1 ]]; then
    "$APP_PATH/Contents/MacOS/$APP_NAME" --benchmark-pty-local "${EXTRA_ARGS[@]}"
else
    "$APP_PATH/Contents/MacOS/$APP_NAME" --benchmark-base64 "${EXTRA_ARGS[@]}"
fi
