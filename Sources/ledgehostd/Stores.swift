import Foundation
import Crypto
import StreamProtocol
import LedgehostCore
import SillLinuxShims
#if canImport(Glibc)
import Glibc
#endif

// Log and the identity/pin stores moved to LedgehostCore's Stores.swift
// so the R-8 unit tests can reach them.

/// Bounded per-message logging (audit S6/F5): at most `budget` lines
/// per `seconds` window; held lines are counted so the next emitted
/// line can report "(+N held)" — floods stay visible in aggregate
/// without filling the journal.
struct LogSampler {
    private var windowStart = 0.0
    private var used = 0
    private var held = 0

    /// Returns the number of lines held since the last emission when
    /// this line may print, or nil when it should be held.
    mutating func emit(every seconds: Double = 1, budget: Int = 8) -> Int? {
        let now = Date().timeIntervalSince1970
        if now - windowStart >= seconds { windowStart = now; used = 0 }
        if used >= budget { held += 1; return nil }
        used += 1
        defer { held = 0 }
        return held
    }
}
