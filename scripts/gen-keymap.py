#!/usr/bin/env python3
# gen-keymap.py - regenerate keymap outputs from helpers/keymap/hid-usage.tsv.
# Outputs:
#   helpers/generated/keymap.h                     (C: hid_usage -> evdev + X keycode)
#   Sources/LedgehostCore/Generated/Keymap.swift   (Swift table + lookup)
import sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def load(tsv):
    rows = []
    for line in open(tsv, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t") if "\t" in line else line.split()
        hid_s, ev_s, name = parts[0], parts[1], parts[2]
        comment = parts[3] if len(parts) > 3 else ""
        rows.append((int(hid_s, 16), int(ev_s), name, comment))
    if len(rows) != len({r[0] for r in rows}):
        sys.exit("duplicate HID usages in " + tsv)
    return rows

def gen_c(rows):
    out = ["/* AUTO-GENERATED from helpers/keymap/hid-usage.tsv - do not edit */",
           "/* Regenerate: make keymap */",
           "#define KEYMAP_MAX_HID 0x%x" % max(r[0] for r in rows),
           "",
           "typedef struct { unsigned char evdev; unsigned char xkc; } KeymapEntry;",
           "/* evdev code 0 = unmapped; xkc = evdev + 8 when evdev != 0 */",
           "static const KeymapEntry keymap_hid_to_evdev[KEYMAP_MAX_HID + 1] = {"]
    ev = {h: e for h, e, _, _ in rows}
    nm = {h: n for h, _, n, _ in rows}
    for h in range(max(r[0] for r in rows) + 1):
        code = ev.get(h, 0)
        comment = " /* 0x%02x %s */" % (h, nm[h]) if h in ev else ""
        out.append("    [%d] = { %d, %d },%s" % (h, code, code + 8 if code else 0, comment))
    out.append("};\n")
    return "\n".join(out)

def gen_swift(rows):
    out = ["// AUTO-GENERATED from helpers/keymap/hid-usage.tsv - do not edit",
           "// Regenerate: make keymap",
           "",
           "/// USB HID keyboard-page (0x07) usage ID -> Linux evdev key code.",
           "/// The X keycode for XTest/XTestFakeKeyEvent is evdev + 8.",
           "public enum Keymap {",
           "    /// Sparse lookup: hidUsage -> evdev key code (0 = unmapped).",
           "    public static let hidToEvdev: [UInt8: UInt16] = ["]
    for h, e, n, c in rows:
        comment = " // %s%s" % (n, " - " + c if c else "")
        out.append("        0x%02x: %d,%s" % (h, e, comment))
    out += ["    ]",
            "",
            "    /// hidUsage -> X11 keycode (evdev + 8), nil when unmapped.",
            "    public static func xKeycode(forHIDUsage usage: UInt8) -> UInt16? {",
            "        guard let ev = hidToEvdev[usage] else { return nil }",
            "        return ev + 8",
            "    }",
            "}"]
    return "\n".join(out) + "\n"

def main():
    args = sys.argv[1:]
    tsv = args[0] if len(args) > 0 else os.path.join(ROOT, "helpers/keymap/hid-usage.tsv")
    dst_c = args[1] if len(args) > 1 else os.path.join(ROOT, "helpers/generated/keymap.h")
    dst_sw = args[2] if len(args) > 2 else os.path.join(ROOT, "Sources/LedgehostCore/Generated/Keymap.swift")
    rows = load(tsv)
    os.makedirs(os.path.dirname(dst_c), exist_ok=True)
    os.makedirs(os.path.dirname(dst_sw), exist_ok=True)
    open(dst_c, "w").write(gen_c(rows))
    open(dst_sw, "w").write(gen_swift(rows))
    print("wrote %s\nwrote %s (%d usages)" % (dst_c, dst_sw, len(rows)))

if __name__ == "__main__":
    main()
