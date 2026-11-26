import Foundation
import StreamProtocol

// Annex B → wire conversion (phase-1-plan.md decision 2). One AU in,
// split by start code; VPS/SPS/PPS go to the sets side (kind 0), AUD and
// filler/EOS/EOB are dropped, everything else is re-emitted as hvcC-style
// 4-byte length-prefixed NALs for kind 1.

public struct AnnexBNAL {
    public let type: UInt8            // (header >> 1) & 0x3f
    public let bytes: Data            // NAL unit, start code NOT included
}

/// Split one Annex B buffer into NAL units. Only scans within this
/// buffer — callers must pass exactly one AU (h265parse alignment=au
/// guarantees that upstream).
public enum AnnexB {
    /// NAL types the wire puts in kind 0, not in frames.
    public static let parameterSetTypes: Set<UInt8> = [32, 33, 34]   // VPS SPS PPS
    /// NAL types dropped entirely on conversion.
    public static let droppedTypes: Set<UInt8> = [35, 36, 37, 38]    // AUD EOS EOB FD(filler)

    public static func split(_ data: Data) -> [AnnexBNAL] {
        // Locate every start code (00 00 01 or 00 00 00 01).
        var starts: [(offset: Int, length: Int)] = []
        var i = data.startIndex
        let end = data.endIndex
        while i + 2 < end {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                starts.append((i, 3))
                i += 3
            } else if i + 3 < end && data[i] == 0 && data[i + 1] == 0
                        && data[i + 2] == 0 && data[i + 3] == 1 {
                starts.append((i, 4))
                i += 4
            } else {
                i += 1
            }
        }
        var nals: [AnnexBNAL] = []
        for (idx, s) in starts.enumerated() {
            let begin = s.offset + s.length
            let last = idx + 1 < starts.count ? starts[idx + 1].offset : end
            // Trim trailing zero bytes that belong to the next start
            // code's leading zeros (already counted in its offset only
            // when they form 00 00 00 01; for 3-byte codes they pad the
            // previous NAL and decoders accept them stripped).
            var bodyEnd = last
            while bodyEnd > begin && data[bodyEnd - 1] == 0 { bodyEnd -= 1 }
            guard bodyEnd > begin else { continue }
            let nal = data.subdata(in: begin..<bodyEnd)
            nals.append(AnnexBNAL(type: (nal[nal.startIndex] >> 1) & 0x3f, bytes: nal))
        }
        return nals
    }

    /// Wrap raw NAL bytes in a 4-byte Annex B start code.
    public static func startCoded(_ nal: Data) -> Data {
        var d = Data(capacity: nal.count + 4)
        d.append(contentsOf: [0, 0, 0, 1])
        d.append(nal)
        return d
    }
}

public struct ConvertedAU {
    /// Raw NAL bytes (no start code) of VPS/SPS/PPS found inside the AU.
    /// Empty when the AU carried none.
    public let parameterSets: [Data]
    /// Kind 1 payload: remaining NALs, each 4-byte-BE-length-prefixed.
    public let frame: Data
    /// True when the AU carried an IDR slice (types 19/20).
    public let isIDR: Bool
}

public enum AnnexBConverter {
    public static func convert(_ au: Data) -> ConvertedAU {
        var sets: [Data] = []
        var frame = Data()
        var isIDR = false
        for nal in AnnexB.split(au) {
            if AnnexB.parameterSetTypes.contains(nal.type) {
                sets.append(nal.bytes)
            } else if AnnexB.droppedTypes.contains(nal.type) {
                continue
            } else {
                frame.appendBE(UInt32(nal.bytes.count))
                frame.append(nal.bytes)
                if nal.type == 19 || nal.type == 20 { isIDR = true }
            }
        }
        return ConvertedAU(parameterSets: sets, frame: frame, isIDR: isIDR)
    }

    /// A sets record's payload (Annex B, concatenated) → kind 0 body via
    /// ParameterSets.encoded(). Returns nil when no parameter NALs found.
    public static func parameterSetsPayload(_ annexB: Data) -> Data? {
        let sets = AnnexB.split(annexB)
            .filter { AnnexB.parameterSetTypes.contains($0.type) }
            .map { $0.bytes }
        guard !sets.isEmpty else { return nil }
        return ParameterSets(nalUnitHeaderLength: 4, sets: sets).encoded()
    }
}

/// hvcC-style length-prefixed AU → Annex B, for the probe's record mode
/// and the unit tests' decode-through-ffprobe path.
public enum WireReassemble {
    /// Split a kind-1 payload back into raw NALs. Returns nil on a
    /// truncated or overrun length — the stream is corrupt.
    public static func splitLengthPrefixed(_ payload: Data) -> [Data]? {
        var out: [Data] = []
        var i = payload.startIndex
        while i < payload.endIndex {
            guard i + 4 <= payload.endIndex else { return nil }
            let len = Int(payload.readBE(UInt32.self, at: i - payload.startIndex))
            i += 4
            guard len > 0, i + len <= payload.endIndex else { return nil }
            out.append(payload.subdata(in: i..<(i + len)))
            i += len
        }
        return out
    }

    /// Build a decodable elementary stream: parameter sets once, then
    /// every frame's NALs re-prefixed with start codes.
    public static func elementaryStream(parameterSets: [Data], frames: [Data]) -> Data {
        var out = Data()
        for s in parameterSets { out.append(AnnexB.startCoded(s)) }
        for f in frames {
            guard let nals = splitLengthPrefixed(f) else { continue }
            for n in nals { out.append(AnnexB.startCoded(n)) }
        }
        return out
    }
}
