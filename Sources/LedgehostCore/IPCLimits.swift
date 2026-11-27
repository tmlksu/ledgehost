import Foundation
import StreamProtocol

/// Cross-process IPC constants — the Swift-side single source. The C-side mirror is helpers/ledgehost-ipc.h: each
/// value names the LH_* macro it must stay equal to, pinned by the
/// LedgehostCoreTests equivalence test. Wire-protocol caps owned by
/// vendored StreamProtocol are referenced, not copied.
public enum IPCLimits {
    // ---- ledgehost-media -> daemon stdout, LHM1 framing ----
    // Header, big endian: magic(4) version(1) tag(1) flags(1)
    // reserved(1) capture timestamp(8, Double seconds) payload len(4).
    /// "LHM1" — LH_MEDIA_MAGIC.
    public static let mediaMagic: [UInt8] = [0x4C, 0x48, 0x4D, 0x31]
    /// LH_MEDIA_VERSION.
    public static let mediaVersion: UInt8 = 1
    /// LH_MEDIA_HEADER_LEN.
    public static let mediaHeaderLength = 20
    /// LH_MEDIA_MAX_PAYLOAD; the stream reuses the wire frame cap.
    public static let mediaMaxPayload = StreamMessage.maxFramePayload

    // ---- daemon -> ledgehost-input stdin, op records ----
    // Record: length(4, BE) + body of that many bytes = op(1) + fields.
    /// LH_INPUT_HEADER_LEN.
    public static let inputHeaderLength = 4
    /// LH_CLIP_MAX. The clipboard text bound is the wire's own cap.
    public static let clipboardTextMax = Clipboard.maxTextBytes
    /// LH_REC_MAX: the largest valid stdin record (op byte + one
    /// maximal clipboard text). A len of 0 or above this is fatal
    /// framing desync on the C side
    public static let inputRecordMax = clipboardTextMax + 1
}
