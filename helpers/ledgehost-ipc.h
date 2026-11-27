/* ledgehost-ipc.h — the C-side single source for every constant the
 * helpers and the daemon share The Swift-side
 * mirror is Sources/LedgehostCore/IPCLimits.swift: each value below
 * names the Swift constant it must stay equal to, and the
 * LedgehostCoreTests equivalence test pins the numbers.
 *
 * Two format families:
 *  - LHM1 records on ledgehost-media's stdout (helper -> daemon).
 *  - op records on ledgehost-input's stdin (daemon -> helper) and the
 *    clipboard/held-state reports on its stdout (helper -> daemon).
 */
#ifndef LEDGEHOST_IPC_H
#define LEDGEHOST_IPC_H

/* ---- ledgehost-media -> daemon, LHM1 framing ---- */
/* Header, big endian: magic(4) version(1) tag(1) flags(1) reserved(1)
 * capture timestamp(8, Double seconds) payload length(4). */
#define LH_MEDIA_MAGIC       "LHM1"      /* IPCLimits.mediaMagic */
#define LH_MEDIA_VERSION     1           /* IPCLimits.mediaVersion */
#define LH_MEDIA_TAG_AU      1           /* MediaTag.accessUnit */
#define LH_MEDIA_TAG_SETS    2           /* MediaTag.parameterSets */
#define LH_MEDIA_HEADER_LEN  20          /* IPCLimits.mediaHeaderLength */
#define LH_MEDIA_MAX_PAYLOAD (32u << 20) /* IPCLimits.mediaMaxPayload ==
                                            StreamMessage.maxFramePayload */

/* ---- daemon -> ledgehost-input stdin, op records ---- */
/* Record: length(4, BE) + body of that many bytes = op(1) + fields.
 * The op table itself is documented in ledgehost-input.c's spec
 * comment and named by InputRecord.op* in InputRecords.swift —
 * currently ops 1-8, with op 8 carrying the clipboard-subscriber
 * count */
#define LH_INPUT_HEADER_LEN  4           /* IPCLimits.inputHeaderLength */

/* Clipboard text bound: == IPCLimits.clipboardTextMax ==
 * Clipboard.maxTextBytes (the wire cap, Vendor/StreamProtocol). */
#define LH_CLIP_MAX          (256 * 1024)

/* Largest valid stdin record: one op byte + LH_CLIP_MAX text bytes.
 * == IPCLimits.inputRecordMax == InputRecord.maxRecordBytes. A record
 * announcing len 0 or len > LH_REC_MAX is unrecoverable framing desync:
 * the helper exits and the daemon restarts it (clamping the announced
 * length would reinterpret attacker-controlled text bytes as further
 * op records). */
#define LH_REC_MAX           (LH_CLIP_MAX + 1)

#endif /* LEDGEHOST_IPC_H */
