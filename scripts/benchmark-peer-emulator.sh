#!/bin/bash
#
# benchmark-peer-emulator.sh
#
# Measures how fast a peer terminal emulator ingests bulk output, to calibrate
# ProSSHMac's own throughput target. Produced the Terminal.app / iTerm2 numbers
# in docs/Optimization.md § "Phase 5 — retarget against peer emulators".
#
# Method: drive the emulator via AppleScript to run `dd | base64` in one of its
# own windows, with only /usr/bin/time's stderr redirected to a file. stdout
# still goes to the terminal, so the emulator must actually ingest and render
# it. When its reader falls behind, the PTY buffer fills and the writer blocks —
# so the writer's elapsed time reflects the emulator's throughput.
#
# Caveats, which matter when comparing against ProSSHMac's own numbers:
#   - These figures INCLUDE rendering. ProSSHMac's --pty-local benchmark does
#     not render at all, so it is flattered by this comparison.
#   - Emulators that coalesce or drop output rather than emulating every cell
#     (Terminal.app does) score better here than their per-cell work implies.
#
# Usage:
#   ./scripts/benchmark-peer-emulator.sh [--app <Terminal|iTerm>] [--mb <n>] [--runs <n>]
#
# Examples:
#   ./scripts/benchmark-peer-emulator.sh --app Terminal --mb 6 --runs 3
#   ./scripts/benchmark-peer-emulator.sh --app iTerm

set -euo pipefail

APP="Terminal"
MB=6
RUNS=3

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)  APP="$2";  shift 2 ;;
        --mb)   MB="$2";   shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        *) echo "ERROR: unknown argument '$1'"; exit 1 ;;
    esac
done

case "$APP" in
    Terminal|iTerm) ;;
    *) echo "ERROR: unsupported --app '$APP' (expected Terminal or iTerm)"; exit 1 ;;
esac

# 1 MB of random bytes base64-encodes to ~1.33 MB, so ask dd for MB*3/4
# kilobytes to put approximately $MB megabytes on the wire.
KB=$(( MB * 1024 * 3 / 4 ))

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/payload.sh" <<PAYLOAD
#!/bin/bash
# LC_ALL=C so \`time\` emits a dot decimal separator regardless of the user's
# locale — under e.g. nl_NL it prints "0,17", which awk then parses as 0.
export LC_ALL=C
OUT="\$1"
{ /usr/bin/time -p sh -c 'dd if=/dev/urandom bs=1024 count=$KB 2>/dev/null | base64' ; } 2>"\$OUT.raw"
grep real "\$OUT.raw" | awk '{print \$2}' > "\$OUT"
PAYLOAD
chmod +x "$WORK/payload.sh"

echo "==> Peer emulator throughput: $APP"
echo "    ~${MB} MB of base64 per run, ${RUNS} runs, rendering included"
echo ""

for run in $(seq 1 "$RUNS"); do
    RESULT="$WORK/run$run.txt"
    rm -f "$RESULT"

    if [[ "$APP" == "Terminal" ]]; then
        osascript -e "tell application \"Terminal\" to do script \"$WORK/payload.sh $RESULT; exit\"" >/dev/null 2>&1
    else
        osascript >/dev/null 2>&1 <<APPLESCRIPT
tell application "iTerm"
  create window with default profile
  tell current session of current window
    write text "$WORK/payload.sh $RESULT; exit"
  end tell
end tell
APPLESCRIPT
    fi

    for _ in $(seq 1 90); do
        [ -s "$RESULT" ] && break
        /bin/sleep 2
    done

    if [ ! -s "$RESULT" ]; then
        echo "run $run/$RUNS: TIMED OUT (no result from $APP)"
        continue
    fi

    # Normalise a comma decimal separator, then parse under LC_ALL=C — awk uses
    # the locale for string-to-number conversion, so a dotted "0.17" reads as 0
    # under a comma locale such as nl_NL.
    LC_ALL=C awk -v run="$run" -v runs="$RUNS" -v mb="$MB" '
        { gsub(/,/, ".", $1)
          secs = $1 + 0
          if (secs > 0) printf "run %s/%s: %ss -> %.2f MB/s\n", run, runs, $1, mb/secs
          else          printf "run %s/%s: %ss -> (too fast to measure)\n", run, runs, $1 }
    ' "$RESULT"
done

echo ""
echo "Compare against: ./scripts/benchmark-throughput.sh --configuration Release --pty-local"
echo "NOTE: that ProSSHMac benchmark excludes rendering; these peer numbers include it."
