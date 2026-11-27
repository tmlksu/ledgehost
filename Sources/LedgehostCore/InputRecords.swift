import Foundation
import StreamProtocol

// Daemon → input helper record protocol (phase-1-plan.md "IPC
// specifications"): length(4, BE, ≤REC_MAX = maxRecordBytes) + op(1) +
// fields (the C-side spec comment in helpers/ledgehost-input.c mirrors
// this). A wire scroll event's x/y arrive as the op-1 move immediately
// preceding the op-2 record — the helper's move coalescing flushes the
// pending move before the scroll, so clicks land at (x, y) (audit S-E).
// The helper
// maps fractions onto the source rectangle, converts HID usages to X
// keycodes, and tracks held state; this side validates, diffs the
// modifier bitmask, and turns InputEvent cases into op records.

public enum InputRecord {
    public static let opPointer: UInt8 = 1
    public static let opScroll: UInt8 = 2
    public static let opKey: UInt8 = 3
    public static let opText: UInt8 = 4
    public static let opReleaseAll: UInt8 = 5
    public static let opReset: UInt8 = 6
    /// Device text -> host CLIPBOARD selection.
    public static let opClipboard: UInt8 = 7
    /// Subscriber count for foreign-clipboard reports (audit S-B):
    /// the helper skips XConvertSelection fetches and record-1 emits
    /// while it is 0.
    public static let opClipboardWatch: UInt8 = 8
    /// The screen rectangle input fractions map onto (phase 2): the
    /// injector's watched window, or the root rect while a desktop
    /// streams. Pushed on injector/source/geometry changes.
    public static let opSourceRect: UInt8 = 9
    /// Helper -> daemon record op: the CLIPBOARD selection's text
    /// changed under a foreign owner. (stdin ops and stdout records
    /// share the framing, not the op namespace.)
    public static let recordClipboardText: UInt8 = 1

    public static let pointerMove: UInt8 = 0
    public static let pointerLeftDown: UInt8 = 1
    public static let pointerLeftUp: UInt8 = 2
    public static let pointerRightDown: UInt8 = 3
    public static let pointerRightUp: UInt8 = 4

    /// Largest record the helper's stdin buffer can hold: one op byte
    /// plus a maximal clipboard payload. Mirrors LH_REC_MAX in
    /// helpers/ledgehost-ipc.h — keep the two in sync (audit F2/S16).
    public static let maxRecordBytes = IPCLimits.inputRecordMax

    public static func record(op: UInt8, body: Data = Data()) -> Data {
        var d = Data(capacity: 5 + body.count)
        d.appendBE(UInt32(body.count + 1))
        d.append(op)
        d.append(body)
        return d
    }

    /// Fraction -> Int32 milli-fraction. The wire values are
    /// unconstrained JSON Doubles and `Int32(Double)` TRAPS on
    /// overflow/non-finite input (audit S1/F1): callers clamp first,
    /// this conversion bounds against Int32.min/.max so it cannot trap
    /// even if a future caller forgets.
    private static func milli(_ v: Double) -> Int32 {
        guard v.isFinite else { return 0 }
        let m = (v * 1e6).rounded()       // may still be infinite for huge v
        if m <= Double(Int32.min) { return Int32.min }
        if m >= Double(Int32.max) { return Int32.max }
        return Int32(m)                   // in-range: cannot trap
    }

    /// Clamp bounds: pointer fractions are [0,1] by definition (the
    /// helper clamps to the source rect anyway); scroll deltas are frame
    /// fractions — a full-screen scroll per event is already absurd, so
    /// ±4 is generous (audit S2/F6; the helper also caps clicks/record).
    private static let pointerBound = 2.0
    private static let scrollBound = 4.0

    /// A pointer record, or nil when x/y is non-finite — the event is
    /// dropped rather than clamped to something arbitrary.
    public static func pointer(kind: UInt8, x: Double, y: Double) -> Data? {
        guard x.isFinite, y.isFinite else { return nil }
        var b = Data()
        b.append(kind)
        b.appendBE(milli(min(max(x, -pointerBound), pointerBound)))
        b.appendBE(milli(min(max(y, -pointerBound), pointerBound)))
        return record(op: opPointer, body: b)
    }

    /// A scroll record, or nil on non-finite deltas. Deltas are clamped
    /// to ±scrollBound frame fractions before conversion.
    public static func scroll(dx: Double, dy: Double) -> Data? {
        guard dx.isFinite, dy.isFinite else { return nil }
        var b = Data()
        b.appendBE(milli(min(max(dx, -scrollBound), scrollBound)))
        b.appendBE(milli(min(max(dy, -scrollBound), scrollBound)))
        return record(op: opScroll, body: b)
    }

    public static func key(usage: UInt16, down: Bool) -> Data {
        var b = Data()
        b.appendBE(usage)
        b.append(down ? 1 : 0)
        return record(op: opKey, body: b)
    }

    public static func text(_ s: String) -> Data {
        record(op: opText, body: Data(s.utf8.prefix(4096 * 4)))
    }

    public static let releaseAll = record(op: opReleaseAll)
    public static let reset = record(op: opReset)

    /// A device's clipboard text: the helper validates UTF-8 length.
    public static func clipboard(_ text: String) -> Data {
        record(op: opClipboard, body: Data(text.utf8))
    }

    /// op 8: how many sessions subscribe to foreign-clipboard reports.
    public static func clipboardWatch(_ count: Int) -> Data {
        record(op: opClipboardWatch, body: Data([UInt8(min(max(count, 0), 255))]))
    }

    /// op 9: the pixel rectangle fractions map onto — x/y can be
    /// negative (a window parked partly off-screen); w/h must be > 0.
    public static func sourceRect(x: Int, y: Int, width: Int, height: Int) -> Data {
        var b = Data(capacity: 16)
        b.appendBE(Int32(x)); b.appendBE(Int32(y))
        b.appendBE(Int32(width)); b.appendBE(Int32(height))
        return record(op: opSourceRect, body: b)
    }

    /// Helper -> daemon stdout framing as a FramedReader layout
    /// (audit Fable R-2): len(4, BE, body incl op) + body. len 0 is
    /// malformed; len above the cap trips the reader's oversized
    /// violation — both mean framing desync. The `Int` header is the
    /// declared body length, unused by callers.
    public static func outputReader(policy: FramedReader<Int>.Policy = .fatal)
        -> FramedReader<Int> {
        FramedReader(headerLength: IPCLimits.inputHeaderLength,
                     maxPayload: IPCLimits.inputRecordMax, policy: policy) { d in
            let len = Int(d.readBE(UInt32.self, at: 0))
            guard len >= 1 else { throw FrameViolation.invalidHeader }
            return (len, len)
        }
    }

    /// Bytes the next helper -> daemon record needs (header + body),
    /// or nil if the buffer does not hold a full record header yet.
    public static func outputRecordLength(_ d: Data) -> Int? {
        guard d.count >= 4 else { return nil }
        let len = Int(d.readBE(UInt32.self, at: 0))
        guard len >= 1, len <= maxRecordBytes else { return -1 }
        return 4 + len
    }

    /// Parse one helper -> daemon record; nil on bad framing.
    public static func parseOutput(_ d: Data) -> (op: UInt8, body: Data)? {
        guard d.count >= 5 else { return nil }
        let len = Int(d.readBE(UInt32.self, at: 0))
        guard len >= 1, len == d.count - 4 else { return nil }
        return (d[4], d.subdata(in: 5..<d.count))
    }
}

/// InputEvent → op records. Holds the modifier state across events so
/// the `modifiers` bitmask arrives at the helper as ordinary op-3
/// records sequenced around the key op (decision 8). Left-handed
/// usages are used for bitmask-driven modifiers.
public struct InputTranslator {
    /// CGEventFlags positions (Input.swift): shift 1<<17, control
    /// 1<<18, option 1<<19, command 1<<20 → their HID usages.
    public static let modifierBits: [(bit: UInt64, usage: UInt16)] = [
        (1 << 17, 0xE1),   // shift   → LEFTSHIFT
        (1 << 18, 0xE0),   // control → LEFTCTRL
        (1 << 19, 0xE2),   // option  → LEFTALT
        (1 << 20, 0xE3),   // command → LEFTMETA
    ]

    /// Modifier usages currently held, by this translator's account.
    private var held: Set<UInt16> = []

    public init() {}

    /// Modifier ops bringing `held` to `mods`, skipping `except` (the
    /// event's own key when it is itself a modifier).
    private mutating func syncModifiers(to mods: UInt64, except: UInt16) -> [Data] {
        var out: [Data] = []
        for (bit, usage) in Self.modifierBits {
            guard usage != except else { continue }
            let want = mods & bit != 0
            if held.contains(usage) != want {
                out.append(InputRecord.key(usage: usage, down: want))
                if want { held.insert(usage) } else { held.remove(usage) }
            }
        }
        return out
    }

    /// A .key event: modifier ops around the key op itself. Unknown
    /// usages are dropped (nil), including out-of-range modifier bits.
    public mutating func key(usage: UInt16, down: Bool, modifiers: UInt64) -> [Data]? {
        guard Keymap.hidToEvdev[UInt8(truncatingIfNeeded: usage)] != nil, usage <= 0xFF
        else { return nil }
        var out = syncModifiers(to: modifiers, except: usage)
        out.append(InputRecord.key(usage: usage, down: down))
        if Self.modifierBits.contains(where: { $0.usage == usage }) {
            if down { held.insert(usage) } else { held.remove(usage) }
        }
        return out
    }

    /// A .text event: the control characters are keys (Input.swift);
    /// everything else is one text record.
    public mutating func text(_ s: String) -> [Data] {
        var out: [Data] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { out.append(InputRecord.text(literal)); literal = "" }
        }
        for ch in s {
            switch ch {
            case "\n": flush(); out.append(InputRecord.key(usage: 0x28, down: true))
                               out.append(InputRecord.key(usage: 0x28, down: false))
            case "\t": flush(); out.append(InputRecord.key(usage: 0x2B, down: true))
                               out.append(InputRecord.key(usage: 0x2B, down: false))
            case "\u{8}": flush(); out.append(InputRecord.key(usage: 0x2A, down: true))
                                 out.append(InputRecord.key(usage: 0x2A, down: false))
            default: literal.append(ch)
            }
        }
        flush()
        return out
    }

    /// The whole event, or nil for cases this host does not inject
    /// (scrollGesture boundaries — no XTest equivalent).
    public mutating func translate(_ ev: InputEvent) -> [Data]? {
        switch ev {
        case .pointer(let action, let x, let y):
            let kind: UInt8
            switch action {
            case .move: kind = InputRecord.pointerMove
            case .leftDown: kind = InputRecord.pointerLeftDown
            case .leftUp: kind = InputRecord.pointerLeftUp
            case .rightDown: kind = InputRecord.pointerRightDown
            case .rightUp: kind = InputRecord.pointerRightUp
            }
            return InputRecord.pointer(kind: kind, x: x, y: y).map { [$0] }
        case .scroll(let x, let y, let dx, let dy):
            // The wire semantics are "scroll AT (x, y)": emit a pointer
            // move ahead of the clicks so they land at the event's
            // coordinates instead of wherever the pointer happens to be
            // (audit Fable S-E). The helper coalesces plain moves but
            // flushes a pending move before the scroll record, so the
            // ordering is preserved through its buffer.
            var out: [Data] = []
            if let move = InputRecord.pointer(kind: InputRecord.pointerMove, x: x, y: y) {
                out.append(move)
            }
            if let scroll = InputRecord.scroll(dx: dx, dy: dy) {
                out.append(scroll)
            }
            return out.isEmpty ? nil : out
        case .text(let s):
            let out = text(s)
            return out.isEmpty ? nil : out
        case .key(let usage, let down, let modifiers):
            return key(usage: usage, down: down, modifiers: modifiers)
        case .scrollGesture:
            return nil
        }
    }
}

/// Per-session input rate limiter (decision 10): 240 events/s, burst
/// equal to one second's budget.
public struct InputRateLimiter {
    private var tokens: Double = 240
    private var last: Double?

    public init() {}

    public mutating func allow(now: Double) -> Bool {
        let elapsed = last.map { now - $0 } ?? 0
        last = now
        tokens = min(tokens + elapsed * 240, 240)
        if tokens < 1 { return false }
        tokens -= 1
        return true
    }
}
