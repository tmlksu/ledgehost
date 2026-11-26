#!/usr/bin/env python3
# helper-driver.py — drive ledgehost-input's stdin records for the
# real-app headless tests. Usage:
#
#   helper-driver.py [--helper PATH] [--display :NN] [--out FILE]
#       text 'UTF-8 string'      -> op 4 (one .text record)
#       textchars 'string'       -> one op 4 record PER character
#       key USAGE [down]         -> op 3 (usage hex, default down+up)
#       hold USAGE 0|1           -> op 3 explicit direction
#       clip 'UTF-8 string'      -> op 7 (set clipboard)
#       ctrl 'a'                 -> ctrl held + key tap + release
#       sleep SECONDS            -> pause
#       release                  -> op 5 release-all
#
# The helper's stdout (clipboard-changed records) is appended to --out
# (default /dev/null) as "clip N" hex+len lines so callers can poll it.

import os, struct, subprocess, sys, threading, time

helper = "bin/ledgehost-input"
out = "/dev/null"
steps = []
i = 1
while i < len(sys.argv):
    a = sys.argv[i]
    if a == "--helper": helper = sys.argv[i+1]; i += 2
    elif a == "--display": os.environ["DISPLAY"] = sys.argv[i+1]; i += 2
    elif a == "--out": out = sys.argv[i+1]; i += 2
    else: steps.append(a); i += 1

def rec(op, body=b""):
    body = bytes([op]) + body
    return struct.pack(">I", len(body)) + body

def key_body(usage, down):
    return struct.pack(">HB", usage, 1 if down else 0)

records = []
i = 0
while i < len(steps):
    s = steps[i]
    if s == "text":
        records.append(rec(4, steps[i+1].encode())); i += 2
    elif s == "textchars":
        for ch in steps[i+1]:
            records.append(rec(4, ch.encode()))
        i += 2
    elif s == "key":
        u = int(steps[i+1], 16)
        records.append(rec(3, key_body(u, True)))
        records.append(rec(3, key_body(u, False)))
        i += 2
    elif s == "hold":
        records.append(rec(3, key_body(int(steps[i+1], 16), steps[i+2] == "1")))
        i += 3
    elif s == "ctrl":
        u = int(steps[i+1], 16)
        records.append(rec(3, key_body(0xE0, True)))
        records.append(rec(3, key_body(u, True)))
        records.append(rec(3, key_body(u, False)))
        records.append(rec(3, key_body(0xE0, False)))
        i += 2
    elif s == "clip":
        records.append(rec(7, steps[i+1].encode())); i += 2
    elif s == "sleep":
        records.append(("SLEEP", float(steps[i+1]))); i += 2
    elif s == "release":
        records.append(rec(5)); i += 1
    else:
        sys.exit(f"helper-driver: unknown step {s!r}")

proc = subprocess.Popen([helper], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=None)

def drain():
    buf = b""
    with open(out, "a") as f:
        while True:
            chunk = proc.stdout.read(4096)
            if not chunk:
                return
            buf += chunk
            while len(buf) >= 5:
                n = struct.unpack(">I", buf[:4])[0]
                if len(buf) < 4 + n:
                    break
                kind = buf[4]
                f.write(f"record kind={kind} len={n - 1}\n")
                f.flush()
                buf = buf[4 + n:]

t = threading.Thread(target=drain, daemon=True)
t.start()

try:
    for r in records:
        if isinstance(r, tuple):
            time.sleep(r[1])
        else:
            proc.stdin.write(r)
            proc.stdin.flush()
    proc.stdin.close()
    proc.wait(timeout=10)
except BrokenPipeError:
    pass
sys.exit(proc.returncode or 0)
