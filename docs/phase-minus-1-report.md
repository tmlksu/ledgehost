# Phase -1 Report — ledgehost

Date: 2026-11-26
Verdict: **GO for Phase 0** (no kill criterion met; see §5)

All findings are against the pinned upstream tag in §1. File references are
`path:line` in that tag's tree.

## 1. Tag pinning

- App Store client in scope: version 0.6.2, released 2026-11-16.
- Pinned tag: `v0.6.2`
  - Target commit: `4e00c805c25645f694c44be4886cdc39d6154542`
    ("Merge pull request #378 from Saffsanity/release-0.6.2",
    2026-11-16 02:39 -0500; verified both by the GitHub API `get_tag`
    call and by a local checkout whose HEAD is exactly this commit)
  - Annotated tag object: `6542a7ac0fe7ee2659321f0ce7c08c382362a009`,
    tagger date 2026-11-16T07:40:21Z, message beginning "Sill 0.6.2:
    Full Screen, Picture in Picture, …"
  - Evidence chain: tag date == App Store release date; the tag is the
    release-0.6.2 merge; public reporting also gives "Version 0.6.2,
    released on November 16, 2026" and lists v0.6.2 as the latest
    GitHub release.
- HEAD is ahead of the pin (commits up to 2026-11-24 at clone time).
  All protocol work must reference v0.6.2, never HEAD. The iPad's
  automatic App Store updates are a standing risk: a client update can
  move the target; watch release tags.

## 2. Client rejection inventory

What the stock client (and the shared protocol code) will refuse, close
on, or silently skip. "Host" below is any machine speaking this protocol.

### 2.1 Framing and size caps (hard closes)

Wire header is 14 bytes, big-endian: kind(1) + timestamp(8, Double) +
isKeyframe(1) + payloadLength(4) (`StreamMessage.swift:108-125`).

| Direction | Cap | Consequence |
|---|---|---|
| host → client, kind 1 (frame) | 32 MiB (`maxFramePayload`) | client ends reading with `.tooBig`, session is lost (`MessageReader.swift:86-90`) |
| host → client, any other kind | 4 MiB (`maxOtherHostPayload`) | same `.tooBig` close |
| client → host, any kind | 1 MiB (`maxClientPayload`) | host closes the connection (`StreamServer.swift:1526ff`) |
| pairing connection, kind 19 | 4096 bytes (`maxPairingPayload`), within 10 s | host refuses/closes (`Door.swift:407`) |

- A message cut short by EOF/error is never delivered; the session is
  treated as lost.
- Clipboard text is capped at 256 KiB of UTF-8 (`Clipboard.swift:39`).

### 2.2 Unknown kinds and fields (soft, by design)

- Unknown kind byte → parsed as `.unknown` (255) and **skipped by the
  reader, not a reason to stop** (`StreamMessage.swift` parseHeader).
  This is the protocol's forward-compatibility rule; additive kinds are
  safe, and a Linux host must obey the same rule in reverse.
- JSON payloads follow "fields added later are optional; no enums on
  the wire; never rename or retype a field" (`Compatibility.swift`
  header). Unknown string values are skipped, not decode failures.

### 2.3 Hello and Compatibility — there is almost no host-side rejection
      of a Linux host in the client, and almost no client rejection
      by the host

- Hello (kind 23) is **device → host**. Every field is optional; `{}`
  decodes; a host "never fails on a thin hello"
  (`Compatibility.swift:110ff`). Fields: `appVersion`, `build`,
  `protocol` (JSON key "protocol"), `device`, `audio`, `offConsoleView`.
- The host's device floor (`DeviceGate.minimumDeviceVersion`) is `"0"`
  in v0.6.2: it admits every device, including one that sends no hello
  at all, and the gate is bypassed entirely at floor 0
  (`DeviceGate.swift`, `StreamServer.gate`). The refusal path exists
  (kind 22 "update", `reconnect:false`, 2 s first-message deadline)
  but is inert in this build.
- `Hello.protocol` is **logged only** in this build; `SillProtocol.current`
  is 1.
- In the other direction, the client does **not** validate the host:
  `WindowList.hostVersion` / `WindowList.protocol` are only recorded
  and logged (`StreamClient.swift:4437-4455`). There is **no macOS
  assumption check** on host info anywhere in the connection path:
  no OS-version, model or Mac-ID format validation of the host by the
  client beyond the pairing identity checks in §2.4. `macName` is a
  free-form string the client displays.
- Per-component comparison that does exist:
  - `SillVersion` compares `appVersion` part-by-part (missing part = 0;
    parsing accepts "v0.4.0"/"0.4"/"1.2.3-beta.1"; at most 8 parts of
    1–9 digits, else unparseable → treated as 0). Only the (inert)
    device floor consumes it in v0.6.2.
  - Capability ints in `WindowList` gate **features, not connection**:
    `gestures` ≥1 → client sends kind 28; `clipboard` ≥1 → kind 32;
    `desktopDisplays` ≥2 → kind 47; `keyRepeat`, `locked`,
    `offConsole(View)` change presentation only (`Switcher.swift:50-102`).
    Sending 0 / omitting a flag degrades that feature; nothing closes.
  - `Hello.audio` listing a codec (client offers `["aac-eld"]`) is the
    only way a host may send kind 43 audio; absence = no audio, still
    a valid session.
  - ALPN is a hard gate, at the TLS layer: session `sill/1`, pairing
    `sill-pair/1`; a host offering neither fails the handshake before
    any protocol word (`RemoteTLS.swift:16-27`).

### 2.4 Identity, pairing, TLS (hard, but self-contained)

- TLS 1.3 only, mutual: both sides present a **self-signed P-256**
  certificate; trust is **only** the SPKI SHA-256 pin — names, dates
  and chains are never evaluated (`RemoteTLS.swift` header). Tickets
  and resumption are off.
- Pairing (kind 19/20, ALPN `sill-pair/1`): `PairRequest.v` must be 1,
  any other value is answered `closed` without counting a try.
  Proofs are HMAC-SHA256 over both fingerprints taken **from the TLS
  session, never from a message**; typed-code key is
  PBKDF2-HMAC-SHA256 (600,000 rounds, salt `"sill-pair-v1" ‖ fp_host`)
  over the 12-digit code (Damm check digit) (`Pairing.swift:75-135`).
- After pairing the client saves: Mac ID (16 Crockford chars, derived
  as `MacID.make(fingerprint)` — a record whose Mac ID is not its
  key's is discarded as damaged/forged, `SavedMacs.swift:108-110`),
  the SPKI pin, and a 32-byte recognition key used for the Bonjour
  TXT tag `r` (a hint, never authentication).
- Bonjour: service type `_sill._tcp`; TXT `p` describes the home door
  (absent = plain TCP, "0" = TLS open, "1"/anything else = TLS,
  paired only) and is read **before dialing** (`Pairing.swift`
  HomeDoorTXT). A Linux host must advertise the truth here or the
  client dials the wrong door.
- A first `WindowList` that does not decode (JSON) cancels the
  connection (`StreamClient.swift:2596`); the catalog order a client
  expects is kind 2 (list), then 16 (host settings), then 18
  (MacInfo) when present.

## 3. StreamProtocol on Linux Swift — build verdict

Toolchain installed for this check: Swift 6.0.3 (official
ubuntu24.04 tarball) on Ubuntu 24.04 x86_64 — installs and runs fine
on this VM.

Experiment 1 — stock package, `swift build --target StreamProtocol`:
fails at the first hurdle, `DesktopDisplays.swift:1: no such module
'CoreGraphics'`. (The package manifest also declares
`platforms: [.macOS(.v14), .iOS(.v17)]`, which SwiftPM on Linux
ignores for building, but the other targets — host, menu bar — are
macOS-only and out of scope.)

Experiment 2 — scratch copy with Apple-only imports guarded by
`#if canImport(...)`, no other changes: **17 of 21 files compile
clean**. Only 4 files produce errors, all of them confined:

| File | Lines | Apple dependencies | Linux replacement |
|---|---|---|---|
| (17 files) | ~2,600 | Foundation only (DesktopDisplays uses only CGRect/CGPoint, which Linux Foundation provides) | none — compile as-is once the CoreGraphics import is guarded |
| Pairing.swift | 307 | CryptoKit (HMAC/SHA256/SymmetricKey), CommonCrypto PBKDF2, SecRandomCopyBytes, one NWTXTRecord overload | swift-crypto (API-identical for HMAC/SHA/P256); PBKDF2-HMAC-SHA256 implemented over HMAC (~30 lines, test vectors exist in upstream docs); SecRandom → SystemRandomNumberGenerator / swift-crypto; drop the NWTXTRecord overload (a `[String:String]` version already exists in the same file) |
| Remote.swift | 240 | SecKey only in `SignedMacInfo.signing`; verification is CryptoKit P256 | swift-crypto P256 (same x963 / DER signature forms); move signing behind the host identity type |
| RemoteIdentity.swift | 214 | SecKey/SecCertificate for key generation, external representation, signing; the certificate itself is already hand-built DER in this file | swift-crypto P256 key (raw/x963 representations map 1:1); keep the hand-built DER certificate code; SPKI fingerprint is already hand-computed SHA-256 of a hand-built DER SPKI |
| RemoteTLS.swift | 165 | Network.framework (NWProtocolTLS/NWConnection/sec_protocol_*) + Security | **Replace wholesale** with SwiftNIO + NIOSSL: TLS 1.3, mutual cert, custom verify callback extracting the peer SPKI fingerprint, ALPN `sill/1` / `sill-pair/1`, tickets/resumption off. This file is a builder, not wire logic, so replacing it does not touch byte compatibility |

Replacement mapping (from the independent review):

| Apple | Linux |
|---|---|
| CryptoKit | swift-crypto |
| Security.framework cert/key handling | swift-crypto + the file's own DER code (swift-certificates if needed) |
| Network.framework TLS/TCP | SwiftNIO + NIOSSL (BoringSSL) |
| CommonCrypto PBKDF2 | own PBKDF2 over swift-crypto HMAC |
| Bonjour (NWListener/NWBrowser) | Avahi (C API or avahi-publish), service `_sill._tcp` |
| SecRandomCopyBytes | system CSPRNG |

Verdict: **Linux Swift reuse is viable.** The wire-critical logic
(framing, Compatibility, PairingProof, RecognitionTag, SPKI
fingerprint, hand-built certificate DER) is either portable as-is or
maps 1:1 onto swift-crypto, so byte-identity is structurally
achievable — the review's main reason for choosing Swift.
Estimated shim work is concentrated in RemoteTLS (a rewrite) and
RemoteIdentity (a port), not spread across the module.

## 4. Remote Access (kind 18–22) — dependency verdict

**No dependency on upstream-operated infrastructure or keys.**

- `SignedMacInfo` (kind 18) is signed with the **host's own**
  self-generated identity key (`Remote.swift:80-98`); the client
  verifies it against the key carried in the message itself, then
  additionally requires the signer's fingerprint to equal the pin
  saved at pairing and `issuedAt` to be newer than the last one seen
  (`StreamClient+Remote.swift:817-843`, `SavedMacs.refreshed`).
  No upstream signature, server, or account is involved anywhere.
- `MacInfo.addresses` are plain host strings with a free-form `via`
  label ("Tailscale", "Wi-Fi", "Router", … are display strings, not
  protocol requirements); kinds are the strings "vpn" / "lan" /
  "internet". A Linux host can advertise any address it is reachable
  at (for example a LAN address reachable through the user's existing
  VPN setup) without upstream involvement.
- Kinds 19–22 (pair request/result, pairing-wanted, goodbye) are the
  pairing/session machinery itself, also fully self-contained (§2.4).

Scope note: implementing kind 18 is therefore *possible*, but Phase 0
stays LAN-only by plan; Remote Access addressing is a later phase,
not a Phase -1 blocker.

## 5. Kill criteria — attestation check

Searched the whole v0.6.2 tree (`Sources/`, `iOSClient/`) for
App Attest, DeviceCheck, iCloud/CloudKit identity, and any
server-issued credential in the pairing / Hello / TLS paths:

- **No App Attest, no DeviceCheck, no iCloud key, no account, no
  upstream server anywhere in the connection path.** (Zero hits for
  `AppAttest` / `DCAppAttest` / `DeviceCheck` / `CloudKit`.)
- Both identities are self-generated P-256 key pairs: the device's
  lives in the iOS Keychain (`DeviceIdentity.swift`), the host's in
  the macOS Keychain or a file store (`HostIdentity.swift`,
  `KeychainIdentityStore.swift`) — keychain use is *local storage
  only*, on both sides, and a Linux host can store its key in a file
  with equivalent semantics (the upstream CLI host already has a
  non-keychain store path).
- Trust is established solely by the pairing proofs bound to the TLS
  fingerprints (§2.4). Nothing in Hello is signed or attested; the
  host floor that could refuse a device is 0/inert (§2.3).

**Kill criterion NOT met → GO for Phase 0.**

## 6. Phase 0 task split (concretising the review)

### 0-A — Media feasibility (no protocol; target hardware only)

1. Capture the Xfce desktop at 2266×1488 (the target iPad mini's
   resolution) via XComposite / dmabuf path; measure sustained fps.
2. VA-API HEVC encode via the current GStreamer `va` plugin
   (`vah265lpenc`, Low-Power entry point): confirm with `vainfo`
   `VAEntrypointEncSliceLP` and its RC modes on Alder Lake-N.
3. Criteria: 60 fps sustained; encode latency < 10 ms/frame; CPU
   < 50%; no B-frames, Main profile 8-bit 4:2:0; forced IDR works.
4. Wrap output in MP4 and confirm an iPad plays it (decode sanity).
5. Annex B → length-prefixed NAL repack + parameter-set extraction
   prototype (the protocol's kind 0/1 payload forms, §2.1).
6. In parallel: the `xrandr --fb` + `--setmonitor` virtual-monitor
   hypothesis under xfwm4 (maximise/fullscreen semantics, pointer
   containment).

### 0-B — Handshake (real iPad + this code)

Modules M1–M3 from the review, in order:

1. M1: vendor StreamProtocol at v0.6.2; apply the §3 shims
   (guard CoreGraphics import; swift-crypto; own PBKDF2; drop the
   NWTXTRecord overload); golden-fixture tests from upstream's
   `Tests/checks` (protocol, pairing vectors) must pass on Linux.
2. M2: identity — generate/persist a P-256 identity (file store),
   build the self-signed certificate with the ported DER code,
   Avahi advertisement of `_sill._tcp` with truthful TXT `p`/`r`.
3. M3/TLS: SwiftNIO + NIOSSL server offering ALPN `sill/1` and
   `sill-pair/1`, TLS 1.3, SPKI-pin verify callback; pairing
   exchange (kind 19/20) with the 12-digit code; Hello (kind 23)
   read; WindowList with a single Desktop entry (kind 2), then
   kind 16.
4. Criteria: the host appears in the iPad's list; pairing completes;
   **after a host restart it reconnects without re-pairing**
   (identity persistence); no Compatibility refusal; the reference
   client (headless, from the shared client logic) passes the same
   exchange for automated regression.
5. Oracle use: capture golden transcripts from the real Mac host +
   source-built client on the home Mac, and diff the Linux host's
   bytes against them before any iPad test.

### Out of Phase 0

Window-unit streaming/virtual monitor (Phase 2, after 0-A item 6
reads out), audio (kind 43), menus (AT-SPI), clipboard polish.

## 7. Repository and privacy

- Codename: **ledgehost**. Remote: a private GitHub repository under
  the owner's account, created by the owner on 2026-11-26.
- Commits use the owner's GitHub noreply address
  (`<id>+<login>@users.noreply.github.com`) as the author email, so
  no personal email address enters history.
- `scripts/check-forbidden-strings.sh` must pass before every push;
  it assembles its patterns from fragments so it does not contain
  the literals it searches for.
- This report, the README and the checker were pushed to the private
  repository on 2026-11-26 (commit `caf40af`), authored with the
  noreply address above; the forbidden-string check passed before
  the push.
