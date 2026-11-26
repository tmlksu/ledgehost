import Foundation
import StreamProtocol

// Daemon → input helper record protocol (phase-1-plan.md "IPC
// specifications"): length(4, BE, ≤64KiB) + op(1) + fields. The helper
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

    public static let pointerMove: UInt8 = 0
    public static let pointerLeftDown: UInt8 = 1
    public static let pointerLeftUp: UInt8 = 2
    public static let pointerRightDown: UInt8 = 3
    public static let pointerRightUp: UInt8 = 4

    public static func record(op: UInt8, body: Data = Data()) -> Data {
        var d = Data(capacity: 5 + body.count)
        d.appendBE(UInt32(body.count + 1))
        d.append(op)
        d.append(body)
        return d
    }

    public static func pointer(kind: UInt8, x: Double, y: Double) -> Data {
        var b = Data()
        b.append(kind)
        b.appendBE(Int32((x * 1e6).rounded()))
        b.appendBE(Int32((y * 1e6).rounded()))
        return record(op: opPointer, body: b)
    }

    public static func scroll(dx: Double, dy: Double) -> Data {
        var b = Data()
        b.appendBE(Int32((dx * 1e6).rounded()))
        b.appendBE(Int32((dy * 1e6).rounded()))
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
            return [InputRecord.pointer(kind: kind, x: x, y: y)]
        case .scroll(_, _, let dx, let dy):
            return [InputRecord.scroll(dx: dx, dy: dy)]
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
