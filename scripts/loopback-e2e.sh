#!/bin/bash
# Loopback end-to-end check for the Phase 0 host: build (debug), start
# ledgehostd on a scratch config, pair ledgehost-probe with the typed
# code, open a session, restart the host, and confirm the session
# reconnects without re-pairing (the identity persisted).
#
#   scripts/loopback-e2e.sh [port]
#
# Needs: swift in PATH, openssl. Exits non-zero on the first failure.
set -u
port="${1:-17456}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'kill ${HOSTPID:-} 2>/dev/null; rm -rf "$work"' EXIT

cd "$root"
swift build --product ledgehostd 2>&1 | tail -1; swift build --product ledgehost-probe 2>&1 | tail -1
bin="$root/.build/debug"

wait_log() {  # file, pattern, seconds
    for _ in $(seq 1 "$3"); do
        grep -q "$2" "$1" 2>/dev/null && return 0
        sleep 1
    done
    echo "FAIL: '$2' not in $1"; cat "$1"; exit 1
}

export XDG_CONFIG_HOME="$work/host"
"$bin/ledgehostd" "$port" > "$work/host.log" 2>&1 &
HOSTPID=$!
wait_log "$work/host.log" "listening on port" 120
code=$(grep -o 'code [0-9 ]*' "$work/host.log" | head -1 | sed 's/code //' | tr -d ' ')
fp1=$(grep -o 'fingerprint [A-Za-z0-9_-]*' "$work/host.log" | head -1 | awk '{print $2}')
echo "host up: code $code fingerprint $fp1"

export XDG_CONFIG_HOME="$work/probe"
"$bin/ledgehost-probe" pair --port "$port" --code "$code" > "$work/pair.log" 2>&1 \
    || { echo "FAIL: pairing"; cat "$work/pair.log"; exit 1; }
grep -q "PAIRED" "$work/pair.log" || { echo "FAIL: pairing output"; cat "$work/pair.log"; exit 1; }
echo "pairing ok"

"$bin/ledgehost-probe" connect --port "$port" > "$work/connect.log" 2>&1 \
    || { echo "FAIL: session"; cat "$work/connect.log"; exit 1; }
grep -q "SESSION PASS" "$work/connect.log" || { echo "FAIL: session output"; cat "$work/connect.log"; exit 1; }
echo "session ok"

kill "$HOSTPID"; sleep 1
export XDG_CONFIG_HOME="$work/host"
"$bin/ledgehostd" "$port" > "$work/host2.log" 2>&1 &
HOSTPID=$!
wait_log "$work/host2.log" "listening on port" 120
fp2=$(grep -o 'fingerprint [A-Za-z0-9_-]*' "$work/host2.log" | head -1 | awk '{print $2}')
[ "$fp1" = "$fp2" ] || { echo "FAIL: fingerprint changed across restart ($fp1 != $fp2)"; exit 1; }
grep -q "1 paired device" "$work/host2.log" || { echo "FAIL: pin not persisted"; cat "$work/host2.log"; exit 1; }

export XDG_CONFIG_HOME="$work/probe"
"$bin/ledgehost-probe" connect --port "$port" > "$work/connect2.log" 2>&1 \
    || { echo "FAIL: session after restart"; cat "$work/connect2.log"; exit 1; }
grep -q "SESSION PASS" "$work/connect2.log" || { echo "FAIL: session after restart output"; cat "$work/connect2.log"; exit 1; }
echo "restart + reconnect ok"
echo "LOOPBACK E2E: PASS"
