# Phase 0 Plan — ledgehost

Status: reviewed by Opus on 2026-11-26 — verdict "proceed, with changes".

Progress (2026-11-26):
- M1 done: pristine import + Linux patch series; the vendored module
  builds on Linux and the golden tests pass 11/11 (upstream pairing
  vectors incl. the 600,000-round code key, RFC 7914 PBKDF2 vectors,
  certificate and SignedMacInfo round trips).
- M0.5 spike built (`Sources/tls-spike`) and loopback-verified with
  openssl s_client: P-256 client cert accepted and its fingerprint
  logged; the post-handshake ALPN gate passes sill-pair/1 and closes
  sill/1 (no pin registered) and no-ALPN connections; an RSA client
  certificate fails the handshake. SPKI parity confirmed three ways:
  BoringSSL's SPKI bytes and openssl's SPKI bytes hash to the same
  fingerprint the vendored layout produces (91 bytes).
  Remaining for M0.5: the same checks against the real device client
  on the LAN, plus Avahi discovery (needs the target machine at home
  and the user present).
All 10 required changes from that review are incorporated below.
Background and diagrams: `explainer.md`. Phase -1 evidence:
`phase-minus-1-report.md`.

## 0-A — Media feasibility (target box, parallel with 0-B)

1. Read-only checks: `vainfo` (HEVC Main, `VAEntrypointEncSliceLP`, RC
   modes), installed iHD driver package (free vs non-free), HuC firmware
   loaded in `dmesg`, GStreamer `va` plugin present (`vah265lpenc`, not
   the legacy `vaapi` plugin).
2. Real encode (non-invasive): `videotestsrc` 300 buffers at 1920x1080
   through `vah265lpenc` to a file; `ffprobe` it; check each RC mode
   planned; play the file on the iPad.
3. Capture cost: time `ximagesrc use-damage=false` at 2266x1488 into
   the encoder; record CPU. (Capture, not encode, is the suspected
   bottleneck on this CPU class.)
4. Criteria: 60 fps sustained at target resolution, encode latency
   < 10 ms/frame, CPU < 50%, no B-frames / Main 8-bit, forced IDR.
5. Virtual-monitor hypothesis (`xrandr --fb` + `--setmonitor` under
   xfwm4) only with: `xrandr --verbose` saved, displays.xml backed up,
   an SSH-driven session, a pre-armed auto-revert script, and the user
   present. Never open the desktop's Display settings during the test.

## 0-B — Handshake

### M1 — Vendoring (serial first step)

- Import the pristine v0.6.2 StreamProtocol tree as ONE commit,
  byte-identical; record tag + commit SHA in `Vendor/VENDORED.md`.
- All Linux edits go in a separate commit / patch series on top.
  A CI check verifies: vendor tree == pristine + patches, and fails
  on any upstream file not accounted for (new/renamed/deleted).
- Shims live in a separate target (`SillLinuxShims`: PBKDF2, randomness),
  outside the vendored directory. Patched upstream files only gain
  import guards plus, where unavoidable, an `#else` import.
- `RemoteTLS.swift` stays byte-identical and is excluded via the
  target's `exclude:` — it is replaced by the NIO module in M3.
- Each patched file carries an Apache-2.0 §4(b) modification notice.
- Call-site diffs should be near zero (swift-crypto mirrors CryptoKit);
  a growing patch is a warning sign. Expected real diffs: the PBKDF2
  call, SecRandomCopyBytes, the NWTXTRecord overload, and the
  SecKey/SecCertificate paths in RemoteIdentity/Remote.
- PBKDF2: first check whether the pinned swift-crypto version ships
  PBKDF2 (`_CryptoExtras`, `KDF.Insecure.PBKDF2`); use it if present
  (a local implementation then serves as test oracle, or vice versa).
  Either way: password = upstream's normalisation copied verbatim
  (all 12 digits, ASCII, no NUL); salt = "sill-pair-v1" bytes + the
  RAW 32-byte fingerprint; dkLen and the big-endian block index must
  match; tests = RFC 7914 §11 vectors + upstream vectors (600k-round
  vector marked slow). Derive once per displayed code and cache;
  verify proofs with the constant-time HMAC check, never `==`;
  code digits generated without modulo bias; attempt limit per code
  with rotation; never log code, derived key, proofs or recognition key.
- ECDSA traps: certificate `signatureValue` uses DER representation;
  SignedMacInfo uses the encoding the upstream P-256 verify path
  expects; match upstream's message-vs-digest semantics
  (`signature(for:)`, do not pre-hash). Cross-check with upstream's
  own verify code as a test.
- Golden tests: upstream `Tests/checks` protocol + pairing vectors
  green on Linux before M2 starts.

### M0.5 — TLS + discovery spike (new; before M2)

Throwaway P-256 key + a certificate built by the vendored DER code
signed via swift-crypto; a NIOSSL server accepting any P-256 client
cert and logging offered/negotiated ALPN, client cert fingerprint,
cipher suite, first frame header; advertisement via the
`avahi-publish-service` subprocess. This retires the two riskiest
unknowns against the real iPad before building M2/M3 on top:
BoringSSL handshake + hand-built cert acceptance, and discovery.

### M2 — Identity

- P-256 key via swift-crypto; identity file written atomically
  (temp + fsync + rename), directory 0700, file 0600, honouring
  `$XDG_CONFIG_HOME`. A corrupted identity file must fail loudly,
  never silently regenerate (that would break every pin).
- SPKI parity test: vendored hand-built SPKI fingerprint must equal
  SHA-256 of BoringSSL's `toSPKIBytes()` for both our key and a peer
  key. A mismatch breaks every proof.
- Avahi via the subprocess for Phase 0 (C shim later; it needs
  entry-group collision and daemon-restart handling). TXT `p`/`r`
  encodings and the `r` derivation are taken from upstream source,
  with test vectors — do not assume `p=1`.

### M3 — Session

- SwiftNIO + NIOSSL: TLS 1.3 minimum, client certificate required,
  tickets/resumption disabled where the API exposes it.
- Verification shape (NIOSSL's callback does not receive the ALPN):
  the callback accepts only well-formed P-256 certificates; after
  `handshakeCompleted`, read the peer certificate from the handler,
  compute its fingerprint, then gate: `sill/1` + unpinned → close;
  `sill-pair/1` → pairing state machine; missing/other ALPN → close.
  Application decoders are installed only after this gate (this also
  covers the resumption bypass, since a resumed session still passes
  the post-handshake gate). Fallback if the device visibly behaves
  differently from upstream's in-handshake refusal: a ClientHello-
  sniffing handler that installs a per-connection pin-checking
  callback. The unpair-then-reconnect device test decides.
- Pairing: one kind 19 (≤4096 B), verify proof_D, reply kind 20
  (proof_M, Mac ID, recognition key), close. Host identity loading:
  cert via `NIOSSLCertificate(bytes:format:.der)`, key converted to
  PKCS#8/SEC1 for `NIOSSLPrivateKey`.
- Session: read Hello (kind 23); send WindowList (kind 2, single
  Desktop entry), then HostSettings (kind 16); keepalive behaviour
  (tick/ping kinds, client idle timeout, what the client sends after
  the first list) is an explicit open question to inventory from
  upstream source before M3, and to observe on the device test.
- Reference client: headless Linux CLI over the vendored module +
  NIO, running the same exchange for regression without a device.

### Negative tests (reference client, no device needed)

Wrong code; tampered proof_D; non-P-256 or missing client cert
(handshake must fail); unpinned key on `sill/1` closed with no
application data read; pairing payload > 4096 B and device→host
> 1 MiB rejected; unknown kinds skipped; unpair-then-reconnect
rejected (resumption coverage).

### Device criteria (measurable)

- Host appears in the iPad's list; independently confirmed with
  `avahi-browse -rt _sill._tcp` from a second machine; firewall
  allows UDP 5353 and the TCP port.
- Pairing completes; the client shows the Desktop entry, no error banner.
- Host fingerprint unchanged after a host restart; device reconnects
  without re-pairing. Repeated after the iPad app is killed and
  restarted, and after the host's IP address changes.
- Session stays up idle for 10 minutes.
- Unpair on the host: record exactly what the client shows (decides
  the TLS gate fallback question above).
- A second simultaneous pairing attempt is handled cleanly.

## Out of Phase 0

Streaming/capture integration (Phase 1), window-unit streaming and
the virtual monitor as a feature, audio, menus, clipboard polish.
