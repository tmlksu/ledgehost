#!/usr/bin/env bash
# real-app-roundtrip.sh — headless regression for the two real-client
# acceptance failures (non-ASCII .text typing; clipboard interop with
# real applications). Runs against :21 with a SCRATCH daemon on a
# scratch port and a scratch XDG_CONFIG_HOME — never the live service.
#
#   scripts/real-app-roundtrip.sh [display]   (default :21)
#
# Needs: bin/ledgehost-input, bin/xquery, .build/debug/{ledgehostd,
# ledgehost-probe} — `make helpers && swift build` first. Mousepad and
# xfce4-terminal on the display.

set -u
cd "$(dirname "$0")/.."
DISP="${1:-:21}"
PORT=17463
SCRATCH=/tmp/lh-rt
X="$PWD/bin/xquery"
DRV="python3 scripts/helper-driver.py"
PROBECFG=/tmp/lh-rt-probe
fail=0

note() { echo "== $*"; }
pass() { echo "PASS: $*"; }
bad()  { echo "FAIL: $*"; fail=1; }

rm -rf "$SCRATCH" "$PROBECFG" /tmp/lh-rt-rec /tmp/rt-hclip.txt
mkdir -p "$SCRATCH" "$PROBECFG" /tmp/lh-rt-rec

# --- scratch daemon ---------------------------------------------------
XDG_CONFIG_HOME="$SCRATCH" DISPLAY=$DISP ./.build/debug/ledgehostd $PORT \
    > /tmp/lh-rt-daemon.log 2>&1 &
DPID=$!
# The first pairing-code derivation is a 600k-round PBKDF2 (~10 s in a
# debug build under load); poll rather than sleep a fixed span.
code=""
for _ in $(seq 1 40); do
    code="$(sed -n 's/.*pairing: code //p' /tmp/lh-rt-daemon.log | tail -1 | tr -d ' ')"
    [ -n "$code" ] && break
    sleep 1
done
[ -n "$code" ] || { echo "no pairing code"; kill $DPID; exit 1; }
XDG_CONFIG_HOME=$PROBECFG ./.build/debug/ledgehost-probe pair \
    --host 127.0.0.1 --port $PORT --code "$code" > /dev/null 2>&1 \
    || { echo "pair failed"; kill $DPID; exit 1; }
note "paired probe to scratch daemon on $PORT"

clip_get() { DISPLAY=$DISP "$X" clip get 2>/dev/null | sed 's/^clip [0-9]* byte(s): //'; }

# --- issue 1: .text through daemon->helper->mousepad ------------------
DISPLAY=$DISP "$X" activate mousepad >/dev/null || { echo "no mousepad"; exit 1; }

note "1a: multi-char .text record (ASCII+kana+kanji+vowel+punct)"
want='Hello日本語テストー。z漢字'
XDG_CONFIG_HOME=$PROBECFG ./.build/debug/ledgehost-probe input \
    --host 127.0.0.1 --port $PORT --seconds 8 \
    --script "key 4 down 262144; key 4 up 262144; key 76 down 0; key 76 up 0; text $want; key 4 down 262144; key 4 up 262144; key 6 down 262144; key 6 up 262144" \
    > /dev/null 2>&1
sleep 1
got="$(clip_get)"
[ "$got" = "$want" ] && pass "one-record .text exact: $got" \
                   || bad "one-record .text: want '$want' got '$got'"

note "1b: per-char .text events (client sends one char per event)"
want2='ab日本語テストー。'
script="key 4 down 262144; key 4 up 262144; key 76 down 0; key 76 up 0;"
for ((i=0; i<${#want2}; i++)); do script="$script text ${want2:$i:1};"; done
script="$script key 4 down 262144; key 4 up 262144; key 6 down 262144; key 6 up 262144"
XDG_CONFIG_HOME=$PROBECFG ./.build/debug/ledgehost-probe input \
    --host 127.0.0.1 --port $PORT --seconds 12 --script "$script" > /dev/null 2>&1
sleep 1
got="$(clip_get)"
[ "$got" = "$want2" ] && pass "per-char .text exact: $got" \
                    || bad "per-char .text: want '$want2' got '$got'"

note "1c: ASCII unchanged"
want3='PlainASCII-123!'
XDG_CONFIG_HOME=$PROBECFG ./.build/debug/ledgehost-probe input \
    --host 127.0.0.1 --port $PORT --seconds 8 \
    --script "key 4 down 262144; key 4 up 262144; key 76 down 0; key 76 up 0; text $want3; key 4 down 262144; key 4 up 262144; key 6 down 262144; key 6 up 262144" \
    > /dev/null 2>&1
sleep 1
got="$(clip_get)"
[ "$got" = "$want3" ] && pass "ASCII exact" || bad "ASCII: got '$got'"

# --- issue 2: clipboard interop ----------------------------------------
note "2a: real-app copy -> subscribed probe (host->device)"
(XDG_CONFIG_HOME=$PROBECFG ./.build/debug/ledgehost-probe clipboard \
    --host 127.0.0.1 --port $PORT --seconds 14 --show \
    > /tmp/lh-rt-probe.log 2>&1) &
P_A=$!
sleep 2
DISPLAY=$DISP "$X" activate mousepad >/dev/null
# buffer = want3; select-all + copy puts a NEW foreign text on CLIPBOARD
python3 scripts/helper-driver.py --display $DISP --helper bin/ledgehost-input \
    text "HOSTCOPY-デスクトップ" sleep 0.4 ctrl 04 ctrl 06 sleep 0.8 2>/dev/null
sleep 3
if grep -q "text: HOSTCOPY-デスクトップ" /tmp/lh-rt-probe.log; then
    pass "probe received real-app copy"
else
    bad "probe got no real-app copy:"; grep "clipboard" /tmp/lh-rt-probe.log
fi

note "2b: device text -> real-app paste (device->host, UTF-8)"
want4='端末に貼り付け-JP-42'
DISPLAY=$DISP "$X" activate mousepad >/dev/null
XDG_CONFIG_HOME=$PROBECFG ./.build/debug/ledgehost-probe clipboard \
    --host 127.0.0.1 --port $PORT --seconds 6 --text "$want4" > /dev/null 2>&1 &
P_B=$!
sleep 2
python3 scripts/helper-driver.py --display $DISP --helper bin/ledgehost-input \
    ctrl 04 key 4c sleep 0.2 ctrl 19 sleep 0.4 ctrl 04 ctrl 06 sleep 0.6 2>/dev/null
got="$(clip_get)"
[ "$got" = "$want4" ] && pass "paste into mousepad exact" \
                    || bad "paste: want '$want4' got '$got'"
wait $P_B 2>/dev/null; wait $P_A 2>/dev/null

note "2c: legacy requestor (property=None convention)"
python3 scripts/helper-driver.py --display $DISP --helper bin/ledgehost-input \
    clip "legacy-テスト" sleep 2.5 2>/dev/null &
P_C=$!
sleep 0.6
got="$(DISPLAY=$DISP "$X" clip-legacy get 2>/dev/null | sed 's/^clip [0-9]* byte(s): //')"
[ "$got" = "legacy-テスト" ] && pass "property=None requestor served" \
                           || bad "legacy requestor: got '$got'"
wait $P_C 2>/dev/null

# --- teardown -----------------------------------------------------------
kill $DPID 2>/dev/null; wait $DPID 2>/dev/null
rm -rf "$SCRATCH" "$PROBECFG" /tmp/lh-rt-rec /tmp/lh-rt-daemon.log \
       /tmp/lh-rt-probe.log /tmp/rt-hclip.txt
echo "== done (fail=$fail)"
exit $fail
