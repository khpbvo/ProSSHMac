#!/bin/bash
#
# benchmark-ssh.sh
#
# Measures raw SSH throughput by piping random data through base64 on the remote host.
# This gives the baseline SSH transport speed without terminal emulation overhead.
# Compare against in-app benchmark to measure the pipeline overhead.
#
# Usage:
#   ./scripts/benchmark-ssh.sh --host <hostname> --user <username> [--port 22] [--bytes 100000]
#
# Examples:
#   ./scripts/benchmark-ssh.sh --host myserver.example.com --user admin
#   ./scripts/benchmark-ssh.sh --host localhost --user $USER --bytes 50000
#   ./scripts/benchmark-ssh.sh --host 192.168.1.10 --user root --port 2222

set -euo pipefail

HOST=""
USER_NAME=""
PORT=22
BYTES_KB=100000

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)
            HOST="$2"
            shift 2
            ;;
        --user)
            USER_NAME="$2"
            shift 2
            ;;
        --port)
            PORT="$2"
            shift 2
            ;;
        --bytes)
            BYTES_KB="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 --host <hostname> --user <username> [--port 22] [--bytes 100000]"
            exit 1
            ;;
    esac
done

if [ -z "$HOST" ] || [ -z "$USER_NAME" ]; then
    echo "Usage: $0 --host <hostname> --user <username> [--port 22] [--bytes 100000]"
    echo ""
    echo "Options:"
    echo "  --host    Remote hostname or IP"
    echo "  --user    SSH username"
    echo "  --port    SSH port (default: 22)"
    echo "  --bytes   Kilobytes of random data to generate (default: 100000)"
    exit 1
fi

EXPECTED_BYTES=$(( BYTES_KB * 1024 * 4 / 3 ))  # base64 expansion ~4/3

echo "==> ProSSHMac Remote SSH Throughput Benchmark"
echo ""
echo "    host=$USER_NAME@$HOST:$PORT"
echo "    payload=${BYTES_KB} KB raw → ~$(( EXPECTED_BYTES / 1024 )) KB base64"
echo ""
echo "==> Running remote command..."
echo ""

START_TIME=$(python3 -c 'import time; print(time.time())')

ACTUAL_BYTES=$(ssh -p "$PORT" "$USER_NAME@$HOST" \
    "dd if=/dev/urandom bs=1024 count=$BYTES_KB 2>/dev/null | base64 | wc -c" \
    2>/dev/null)

END_TIME=$(python3 -c 'import time; print(time.time())')

ELAPSED=$(python3 -c "print(f'{$END_TIME - $START_TIME:.3f}')")
MBPS=$(python3 -c "
elapsed = $END_TIME - $START_TIME
bytes = int('$ACTUAL_BYTES'.strip())
if elapsed > 0:
    print(f'{bytes / elapsed / 1048576:.2f}')
else:
    print('N/A')
")

echo "results:"
echo "  bytes transferred: $(echo "$ACTUAL_BYTES" | tr -d '[:space:]')"
echo "  elapsed: ${ELAPSED}s"
echo "  throughput: ${MBPS} MB/s"
echo ""
echo "NOTE: This is raw SSH transport throughput (no terminal emulation)."
echo "      Compare against in-app benchmark to measure pipeline overhead:"
echo "      ./scripts/benchmark-throughput.sh --pty-local"
echo ""
