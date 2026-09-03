#!/bin/bash
#
# benchmark-throughput.sh
#
# Builds ProSSHMac and runs the in-app throughput benchmark mode.
#
# Usage:
#   ./scripts/benchmark-throughput.sh [--configuration <Debug|Release>] [--no-build]
#                                     [--pty-local | --render | --render-detached] [benchmark args...]
#
# Modes:
#   (default)         parser/grid only, synthetic payload, no PTY and no rendering
#   --pty-local       real PTY -> engine.feed, but NOT the app's reader path and no rendering
#   --render          the real app path in a real window WITH rendering (peer-comparable)
#   --render-detached the same app path parked on the hosts tab, so nothing renders
#
# The --render vs --render-detached delta is the cost of rendering. --render needs
# a focused window: an unfocused terminal surface is throttled to 30 FPS.
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
#   ./scripts/benchmark-throughput.sh --configuration Release --render --benchmark-bytes 2097152
#   ./scripts/benchmark-throughput.sh --configuration Release --no-build --render-detached

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEME="ProSSHMac"
APP_NAME="ProSSHMac"
CONFIGURATION="Debug"
NO_BUILD=0
MODE_FLAG=""
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
            MODE_FLAG="--benchmark-pty-local"
            shift
            ;;
        --render)
            MODE_FLAG="--benchmark-render"
            shift
            ;;
        --render-detached)
            MODE_FLAG="--benchmark-render-detached"
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

MODE_FLAG="${MODE_FLAG:---benchmark-base64}"

if [[ "$MODE_FLAG" == --benchmark-render* ]]; then
    # Rendered runs need a real window, and launching the binary straight from a
    # shell produces a process with zero windows — SwiftUI's WindowGroup never
    # materializes. LaunchServices (`open -n`) gives a proper GUI app, but
    # detaches stdout, so the app writes its report to a file we poll for.
    RESULT_FILE="$(mktemp -t prossh-render-bench)"
    rm -f "$RESULT_FILE"
    trap 'rm -f "$RESULT_FILE"' EXIT

    open -n "$APP_PATH" --args "$MODE_FLAG" --benchmark-out "$RESULT_FILE" "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

    # Each run floods a shell and waits for the renderer to settle; allow plenty.
    for _ in $(seq 1 300); do
        [ -s "$RESULT_FILE" ] && break
        /bin/sleep 2
    done

    if [ ! -s "$RESULT_FILE" ]; then
        echo "ERROR: no result from $APP_NAME after 600s"
        pkill -9 -x "$APP_NAME" 2>/dev/null || true
        exit 1
    fi

    cat "$RESULT_FILE"
else
    if [[ ${#EXTRA_ARGS[@]} -gt 0 ]]; then
        "$APP_PATH/Contents/MacOS/$APP_NAME" "$MODE_FLAG" "${EXTRA_ARGS[@]}"
    else
        "$APP_PATH/Contents/MacOS/$APP_NAME" "$MODE_FLAG"
    fi
fi
