#!/bin/bash
#
# benchmark-throughput.sh
#
# Builds ProSSHMac and runs the in-app throughput benchmark mode.
#
# Usage:
#   ./scripts/benchmark-throughput.sh [--configuration <Debug|Release>] [--no-build] [--pty-local] [benchmark args...]
#
# The build configuration defaults to Debug so that historical numbers in
# docs/Optimization.md stay reproducible. Every recorded measurement must state
# which configuration it came from — see docs/FasterThenYouWillEverLiveToBe.md.
#
# Examples:
#   ./scripts/benchmark-throughput.sh
#   ./scripts/benchmark-throughput.sh --configuration Release --benchmark-bytes 2097152 --benchmark-runs 4
#   ./scripts/benchmark-throughput.sh --benchmark-bytes 33554432 --benchmark-runs 5
#   ./scripts/benchmark-throughput.sh --pty-local --no-build

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="ProSSHMac"
APP_NAME="ProSSHMac"
CONFIGURATION="Debug"
NO_BUILD=0
PTY_LOCAL=0
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --configuration requires a value (Debug or Release)"
                exit 1
            fi
            CONFIGURATION="$2"
            shift 2
            ;;
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

case "$CONFIGURATION" in
    Debug|Release) ;;
    *)
        echo "ERROR: unsupported --configuration '$CONFIGURATION' (expected Debug or Release)"
        exit 1
        ;;
esac

echo "==> ProSSHMac Throughput Benchmark"
echo "    configuration: $CONFIGURATION"
echo ""

if [[ "$NO_BUILD" -eq 0 ]]; then
    echo "==> Building $SCHEME ($CONFIGURATION)..."
    xcodebuild \
        -project "$PROJECT_DIR/ProSSHMac.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'platform=macOS' \
        build \
        2>&1 | tail -3
fi

TARGET_BUILD_DIR=$(xcodebuild \
    -project "$PROJECT_DIR/ProSSHMac.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -showBuildSettings \
    2>/dev/null | awk '
        /^[[:space:]]*TARGET_BUILD_DIR = / && !found {
            sub(/^[[:space:]]*TARGET_BUILD_DIR = /, "")
            value = $0
            found = 1
        }
        END { if (found) print value }
    ')
if [ -z "$TARGET_BUILD_DIR" ]; then
    echo "ERROR: Could not resolve the $APP_NAME build directory"
    exit 1
fi
APP_PATH="$TARGET_BUILD_DIR/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: Could not find built $APP_NAME.app at $APP_PATH"
    exit 1
fi

echo "    Built: $APP_PATH"
echo ""
echo "==> Running benchmark..."
echo ""

pkill -9 -x "$APP_NAME" 2>/dev/null || true
sleep 1

if [[ "$PTY_LOCAL" -eq 1 ]]; then
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        "$APP_PATH/Contents/MacOS/$APP_NAME" --benchmark-pty-local "${EXTRA_ARGS[@]}"
    else
        "$APP_PATH/Contents/MacOS/$APP_NAME" --benchmark-pty-local
    fi
else
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        "$APP_PATH/Contents/MacOS/$APP_NAME" --benchmark-base64 "${EXTRA_ARGS[@]}"
    else
        "$APP_PATH/Contents/MacOS/$APP_NAME" --benchmark-base64
    fi
fi
