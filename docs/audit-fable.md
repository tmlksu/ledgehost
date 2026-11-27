# ledgehost audit — fable

Date: 2026-11-27. Scope: `Sources/ledgehostd`, `Sources/ledgehost-probe`,
`Sources/LedgehostCore`, `Sources/SillLinuxShims`, `Sources/tls-spike`,
`helpers/*.c` (+ generated keymap), `Vendor/StreamProtocol` (our patches
and the integration points; upstream-pristine code only where our patches
or call sites touch it), `scripts/`, `deploy/ledgehost.service`,
`Makefile`, `Package.swift`. Audit only; no code changes in this report.

Findings are marked **[proven]** (read + reproduced, or read +
unambiguous code path) or **[suspected]** (code-read inference; the
measurement that would settle it is named). Effort: S < half a day,
M < ~3 days, L more.

Threat model used: an untrusted LAN client (unpaired — can only reach
the `sill-pair/1` door and the TLS handshake; paired — full session
protocol), untrusted X clients (selection owners, selection requestors,
window content), and untrusted input from a paired client.

---

## 1. Proven findings

### F1 — Paired injector client crashes ledgehostd via `Int32(Double)` trap — **high**
Lens: security (availability). Effort: **S**.

- `Sources/LedgehostCore/InputRecords.swift:41-42` — `pointer()` does
  `Int32((x * 1e6).rounded())`; `:48-49` — `scroll()` does the same for
  `dx`, `dy`. `Int32(Double)` is a trapping conversion: any value that
  does not fit aborts the process (`Swift/IntegerTypes.swift:7900`).
- The wire values are unconstrained JSON Doubles
  (`Vendor/StreamProtocol/Input.swift:15,20` decoded by
  `JSONDecoder` via `Wire.decode`, `Vendor/StreamProtocol/Switcher.swift:236-238`).
  Any finite `|x| ≥ 2148` (x·1e6 > Int32.max) traps; there is no clamp
  anywhere between decode and conversion — `handleInput` only checks
  injector + rate (`Sources/ledgehostd/main.swift:485-489`).
- **Reproduced end to end** (scratch daemon, scratch port, scratch
  XDG_CONFIG_HOME): after pairing, `probe input --script "move 10000 0"`
  produced `input ledgehost-probe: pointer move x10000000y0` followed by
  `Fatal error: Double value cannot be converted to Int32 because the
  result would be greater than Int32.max` — SIGILL, process dead. Any
  paired client that selects `.desktop` becomes the injector, so the
  precondition is just "paired". With `Restart=on-failure` +
  `StartLimitBurst=10` the service can be kept cycling until systemd
  gives up; every retry drops all sessions.
- Same primitive, second target: `.scroll` `dx=3000` → `Int32(3e9)` traps;
  `dy=-3000` likewise. `.text`/`.key` are safe (bounded/string/int).
- Why it matters: this is the exact bug class upstream already shipped
  and fixed on the viewport path (their own comment at
  `Vendor/StreamProtocol/Viewport.swift:34-37` cites their security
  scan's finding 4 — "a side of 1e300 … reached an Int, which traps,
  and the host died with every device's session"). The input path has
  the identical unchecked conversion and nobody reapplied the lesson.
- Fix sketch: clamp at the translator — in `InputTranslator.translate`,
  reject non-finite values and clamp x,y to e.g. [-2, 2] and |d| to a
  sane scroll budget before `*1e6` (or use `Int32(clamping:)`-style
  bounds). Belt-and-braces: use `Int32(exactly:) ?? continue` inside
  `InputRecord.pointer/scroll` so a future caller cannot reintroduce
  the trap. Regression test mirroring the upstream viewport test.

### F2 — op-7 clipboard record overflows the input helper's 64 KB stdin buffer → IPC desync → input injection from a *non-injector* session — **high**
Lens: security (protocol integrity). Effort: **M**.

- Daemon side: `handleClipboard` accepts `.set(text)` for any
  `text.utf8.count ≤ Clipboard.maxTextBytes` = **256 KiB**
  (`Sources/ledgehostd/main.swift:497-516`,
  `Vendor/StreamProtocol/Clipboard.swift:39`) and calls
  `input.setClipboard(text)` → `InputRecord.clipboard`
  (`Sources/LedgehostCore/InputRecords.swift:68-70`), which emits
  `len(4) = utf8count + 1` with **no size bound**.
- Helper side: stdin records are read into `unsigned char buf[64*1024]`
  and any `len > sizeof buf - 4` (65 532) is "handled" by *clamping*
  `len = sizeof buf - 4` and continuing
  (`helpers/ledgehost-input.c:587,617-619`).
- Consequence, by inspection of the framing: a 256 KiB device clipboard
  text arrives as one record with `len ≈ 262 145`. The helper logs
  "bad record len", clamps to 65 532, consumes the first 64 KiB as an
  op-7, then keeps parsing: **bytes 65 536… of the attacker-chosen
  clipboard text are interpreted as further length-prefixed op
  records**. The paired sender controls every byte, so it can embed
  well-formed op-1/2/3/4/7 records (arbitrary key presses, pointer
  actions, scroll, clipboard writes).
- Crucially this path bypasses input arbitration: `handleClipboard`
  has no `registry.injector === self` check (correct for kind 32), so a
  paired session that is *not* the injector gains the same input
  injection the injector is supposed to exclusively hold (decision 10:
  "one serialized input stream"). It also permanently desyncs the stream
  for honest >64 KiB clipboards until the buffer fills and resets.
- Why it matters: a background paired device can inject keystrokes
  while a foreground session believes it holds exclusive input. The
  desync also wedges the helper for any large legitimate clipboard.
- Fix sketch: make the two ends agree — bound
  `InputRecord.clipboard`/`op_clipboard` to the helper's stdin capacity
  (or enlarge the helper buffer to `CLIP_MAX + 16`); and fix the helper
  to *skip* `len` bytes on an oversized record (or terminate) instead
  of clamping `len` to the buffer size — the clamp is what turns a
  size bug into a parse-into-attacker-bytes bug. Also drop op-7 in the
  daemon when the record would exceed the negotiated IPC max.

### F3 — Unauthenticated pairing door: unbounded concurrent TLS handshakes on one event loop — **medium-high**
Lens: security (availability). Effort: **M**.

- The whole daemon — TLS handshakes for every connection, sessions,
  helper pipes — runs on `MultiThreadedEventLoopGroup(numberOfThreads: 1)`
  (`Sources/ledgehostd/main.swift:103`). NIOSSL performs handshake crypto
  on the event loop. Any LAN client may open `sill-pair/1` connections
  (ALPN is offered unconditionally, `:703`), each costing P-256
  verification work (~ms each) plus NIOSSL state, and each is held for
  up to 30 s (`:279-283`). There is no cap on concurrent connections,
  no per-IP rate limit, and no cap on simultaneous handshakes — only
  `backlog: 8` for the accept queue (`:707`).
- A modest connect flood saturates the single loop (all session work —
  including frame fan-out — queues behind handshakes) and/or exhausts
  the fd table (systemd default soft limit, no `LimitNOFILE=` in
  `deploy/ledgehost.service`), denying service to legitimate clients
  without ever pairing.
- Fix sketch: cap concurrent unauthenticated channels (e.g. ≤ 16
  pairing-state conns, refuse extras early — check counts in
  `channelActive`), shorten the pairing deadline for connections that
  have sent nothing (30 s is generous once the debug-build comment's
  rationale is revisited), and add a simple token bucket on new TCP
  connections per source address. Longer term, a second event loop for
  the TLS handshake stage or `NIOSSLHandler` offload bounds blast
  radius.

### F4 — Pairing credentials never expire, and the QR secret is persisted in the journal — **medium**
Lens: security (pairing flow). Effort: **S**.

- `PairingManager` rotates the code and the 16-byte QR secret only on
  a successful pair, on the fifth failed proof, or on daemon restart
  (`Sources/ledgehostd/Pairing.swift:31-47,96-99`). There is no
  time-based expiry: a code printed once stays valid indefinitely
  while no pairing attempt happens — which on a headless service can
  be weeks.
- The full pairing link — including `s=<QR secret>` — is printed to
  the unbuffered log at every rotation (`Pairing.swift:44-46`), so it
  lands in the persistent user journal. Anything that can later read
  that log (or photograph the output) holds a no-attempt-limit
  credential until the next rotation event.
- The 5-try cap is per *code*, not per attacker: an unpaired LAN
  attacker burns the five tries to force rotation and immediately gets
  five tries on the next code — a sustained pairing DoS (legit code
  keeps changing under the user) plus steady journal spam of new
  credentials.
- Fix sketch: rotate on a timer (e.g. every 10 min while unpaired) and
  expire a code after first use window regardless of tries; stop
  printing the QR secret to the journal (print only when a verbose
  flag is set, or print the code alone); consider per-source-IP
  failure throttling so a flooding client cannot force rotation.

### F5 — Per-event logging before arbitration/rate checks: paired client floods the journal — **medium**
Lens: security (resource abuse) + performance. Effort: **S**.

- `handleInput` prints a line for *every* kind-8 event **before** the
  injector and rate-limit checks (`Sources/ledgehostd/main.swift:471-489`).
  Any paired session (not just the injector) can drive unlimited
  journal lines; `setvbuf(_IONBF)` (`main.swift:15`) makes each line a
  write() syscall. Same pattern: `clientStats` (`:389-391`), viewport
  refusals (`:533`), clipboard refusals are silent (good) but
  `handleSelectSource`/`handleChangeSettings` log each call.
- Why it matters: sustained multi-hundred-line/s journal writes cost
  CPU on the single event loop and grow the journal; the rate limiter
  (`:486`) only throttles injection, not logging.
- Fix sketch: log input events only for the injector (or aggregate —
  "N events/s" once per second); rate-limit refusal logging.

### F6 — One scroll record → up to ~51 600 XTest button events; accumulator is unbounded — **medium**
Lens: security (paired-client DoS) + correctness. Effort: **S**.

- `op_scroll` drains the accumulated milli-fraction in clicks of
  `1 000 000/24` each, looping per click
  (`helpers/ledgehost-input.c:288-300`). The daemon forwards the raw
  Int32 milli-fraction (`InputRecords.swift:46-51`), so a single
  in-range `dx ≈ 2000` (2.0e9 milli-fractions, just under the F1 trap)
  yields ~48 000 `hold_btn` pairs — from one record, while the rate
  limiter counts *records* (240/s), not clicks. The helper grinds in
  its input loop and floods the X server; input latency collapses.
- Fix sketch: clamp |delta| at the translator (e.g. ≤ 1.0 of a frame —
  a whole-screen scroll per event is already absurd) and cap clicks
  emitted per record in the helper (carry the remainder, as it already
  does, but bound per-iteration work).

### F7 — Media helper: one-byte stack overwrite past `buf[256]` when stdin read returns 256 — **low-medium**
Lens: security (memory safety, trusted-writer). Effort: **S**.

- `char buf[256]; ssize_t n = read(fd, buf, sizeof buf); … buf[n] = 0;`
  (`helpers/ledgehost-media.c:199-205`). When a read fills the buffer,
  `buf[256] = 0` writes one byte past the array. Today only the daemon
  writes ≤ ~25-byte commands, so reachability needs a daemon-side bug —
  but it is a genuine off-by-one UB in a setuid-adjacent-adjacent
  (well, same-UID X-capable) helper.
- Fix sketch: `read(fd, buf, sizeof buf - 1)`. Also worth noting the
  line parser drops a command split across reads (`:211`
  "unterminated tail: ignore") — harmless with today's one-command-
  per-write daemon, fragile as a contract.

### F8 — Helper record-length clamp turns bad framing into desync — **low-medium**
Lens: security/robustness (compounds F2). Effort: **S**.

- `helpers/ledgehost-input.c:618`: `len == 0 || len > sizeof buf - 4`
  → logs and sets `len = sizeof buf - 4`, then waits for 64 KiB before
  consuming. A malformed length stalls all subsequent records until the
  buffer happens to fill (`:644` resets only when full). Should skip
  the announced `len` (bounded) or close the channel — the daemon
  restarts the helper on protocol violation anyway (media does via
  `MediaRecordError`; the input path should match).
- Companion nit: `pending_move` coalescing is applied *before* the rate
  check and is flushed out of order relative to subsequent records — a
  move recorded before a key record is applied when the key record is
  parsed, not where it sat in the stream (`:623-630`). Harmless for
  pointer correctness, worth knowing.

### F9 — Signed left-shift UB in the input helper's byte assembly — **low**
Lens: security/hygiene. Effort: **S**.

- `p[1] << 24` where `p` is `const unsigned char *`: `p[1]` promotes to
  `int`; 255 << 24 overflows int — technically UB (same pattern at
  `helpers/ledgehost-input.c:269-270,291-292,617`). Every current
  compiler produces the intended bits; UBSan flags it; trivially fixed
  by casting to `uint32_t` first.

### F10 — RNG-failure fallbacks produce known credentials — **low**
Lens: security (defense in depth). Effort: **S**.

- `code = PairingCode.generate() ?? "000000000000"`
  (`Sources/ledgehostd/Pairing.swift:37`): if generation fails, the
  pairing code is a fixed public string — and it is a *valid* code
  under the Damm check, so `codeKey` derives a real key any attacker
  knows. `_ = SillRandom.fill(&secret)` (`:40`) likewise leaves an
  all-zero QR secret on failure. Both are unreachable while
  `SystemRandomNumberGenerator` works (it cannot fail on Linux
  getrandom), but the fail-open shape is backwards: fail closed
  (abort pairing, log) rather than pair on a known secret.

### F11 — Helper binary search path trusts `./bin` under the daemon's cwd — **low**
Lens: security (local file-plant). Effort: **S**.

- `MediaService.helperURL()` tries
  `FileManager.default.currentDirectoryPath + "/bin/ledgehost-media"`
  (`Sources/ledgehostd/MediaService.swift:114-127`); `InputService`
  similar (`Sources/ledgehostd/InputService.swift:35-43`). Under the
  systemd unit cwd is controlled, but run from a writable directory
  the daemon will exec `./bin/ledgehost-*` — code execution as the
  user. Cheap fix: under the service, only probe the executable's own
  directory (and optionally an absolute deployed path); drop the cwd
  fallback in production or gate it behind a dev flag.

### F12 — `awaitingHello` has no deadline — **low**
Lens: security (state hygiene). Effort: **S**.

- Paired clients that complete the `sill/1` handshake then never send
  Hello hold a connection slot forever (`Sources/ledgehostd/main.swift:355-371`
  — the only deadline is the pairing one). Paired-only, so impact is
  limited to a buggy/malicious already-trusted device; still, a 60 s
  first-message deadline is one scheduled task.

### F13 — Non-atomic probe identity/pin stores — **low**
Lens: security (store consistency, probe side). Effort: **S**.

- `Sources/ledgehost-probe/main.swift:112,270` — `JSONEncoder().encode().write(to:)`
  then chmod, for both `identity.json` and `host.json`. A crash
  mid-write corrupts the device key or host pin (fails closed — the
  pin just mismatches — but forces re-pairing). The daemon's
  `atomicWrite` (`Sources/ledgehostd/Stores.swift:43-57`) is the right
  shape and could be shared.

### F14 — SignedMacInfo interop verified; TLS/pin flow sound — no finding, noted for completeness
Lens: security. The verification callback only establishes "P-256
peer" + SPKI pin (`Sources/ledgehostd/main.swift:711-718`, matching the
spike design `Sources/tls-spike/main.swift:135-142`); ALPN+pin gate is
post-handshake (`main.swift:267-295`); TLS 1.3 only (`:700-701`);
P-256-only cert enforcement via `spki.count == 91` + OID prefix
(`:68-77`); fingerprint always from the TLS session, never a message.
`SignedMacInfo.signing` in the patch signs the exact JSON bytes
(`Vendor/StreamProtocol/Remote.swift:99-105`) — same contract as
upstream. PBKDF2 shim is a correct RFC 2898 implementation
(`Sources/SillLinuxShims/Shims.swift:15-37`), constant-time HMAC
compare via swift-crypto (`Vendor/StreamProtocol/Pairing.swift:152-159`).
Identity + pins: dir 0700, files 0600, atomic temp+fsync+rename
(`Sources/ledgehostd/Stores.swift:37-57`), corrupt identity is a loud
failure not a silent regen (`:104-106`) — all good.

---

## 2. Suspected findings

### Security

**S-A — Shared `DateFormatter` across threads (suspected data race).**
`Log.stamp()`'s static `DateFormatter` (`Sources/ledgehostd/Stores.swift:13-20`)
is called from the event loop *and* from Foundation `readabilityHandler`
blocks, which run on `DispatchQueue.global()` — both helpers' stderr
relays (`Sources/ledgehostd/MediaService.swift:161-167`,
`Sources/ledgehostd/InputService.swift:113-119`) plus the pairing lock.
`DateFormatter` is not documented thread-safe and corelib-foundation
instances mutate internal caches — concurrent calls risk a crash or
garbled stamps under load. Fix: a per-call RFC date format via
`ISO8601`-style cached `DateComponents`+`String(format:)`, a lock, or
per-thread formatter. Effort **S**.

**S-B — Unthrottled clipboard fetch on foreign owner changes.**
Every CLIPBOARD owner change triggers `XConvertSelection` +
`XGetWindowProperty` up to 256 KiB and an `emit_record`
(`helpers/ledgehost-input.c:425-477`) — with no rate limit and
**regardless of whether any session is subscribed** (the helper watches
whenever it runs, i.e. whenever anyone watches the desktop). A hostile
or simply busy X client flipping the selection forces repeated
quarter-megabyte reads + pipe writes; and the daemon reads clipboard
contents into memory even with zero subscribers. Fix: only install the
watch/fetch while `clipboardSubscribed` sessions exist (plumb a count
down to the helper, or start/stop the watch via a new op), and/or
throttle emits to ~1/s. Effort **M**.

**S-C — Clipboard relay forwards the raw client payload.** On `.set`,
the original JSON (up to 1 MiB, arbitrary extra fields) is relayed
verbatim to other subscribers (`Sources/ledgehostd/main.swift:514-516`)
instead of re-encoding `Clipboard(text:)`. Rate-capped at 4/s per
connection, so ~4 MB/s amplification worst case — minor, but re-encode
for hygiene. Effort **S**.

**S-D — `deviceSetText` echo suppression is a single global.** Two
devices racing the same text, or a local copy matching the just-set
device text, suppress the wrong echo (`Sources/ledgehostd/main.swift:147,512`).
Functional edge only. Effort **S** (key it per-connection or drop it —
the helper already suppresses its own text).

**S-E — Scroll events drop their target coordinates.** The wire's
`.scroll(x, y, dx, dy)` scrolls *at (x,y)*; the translator discards
x,y (`Sources/LedgehostCore/InputRecords.swift:174-175`), so scrolling
lands wherever the pointer last was — wrong window if the client
expected coordinates to be honored. Effort **S** (emit an op-1 move
before the scroll clicks, or extend op-2 with coords).

**S-F — Text typing ignores keymap levels ≥ 2 (AltGr layer).**
`type_char` finds the keysym at any level 0-3 but only presses shift
for `level == 1` (`helpers/ledgehost-input.c:218-236`): characters on
AltGr levels (e.g. `@`, `{}`, `€` on many layouts) are typed as the
key's *level-0* glyph — silent wrong text for non-US layouts. Fix:
track the level → needed modifier map (ISO_Level3_Shift for level 2/3)
or fall back to the scratch path when `level > 1`. Effort **S**.

**S-G — systemd unit posture is good, not maximal.**
`deploy/ledgehost.service` has NoNewPrivileges, UMask=0077,
RestrictAddressFamilies, LockPersonality, ProtectSystem=strict +
ReadWritePaths — solid for a user unit. Gaps worth considering:
`CapabilityBoundingSet=` (empty — the daemon needs no caps),
`AmbientCapabilities=`, `ProtectKernelTunables=yes`,
`ProtectKernelModules=yes`, `ProtectControlGroups=yes`,
`RestrictRealtime=yes`, `ProtectHome=read-only` (config dir is already
whitelisted writable; `XAUTHORITY` file only needs read),
`PrivateIPC=yes`, `MemoryMax=`/`TasksMax=` for resource bounding.
Each line is cheap; none are blockers. Effort **S**.

**S-H — X-selection trust notes (no action needed beyond awareness).**
`serve_selection` answers TIMESTAMP with `0`
(`helpers/ledgehost-input.c:395-399`) — spec-wise should be the
ownership timestamp; pedantic requestors may reject. `got_selection_text`
trusts the SelectionNotify event's `property` field — a forged
XSendEvent can point it at any property on our window, but a local X
client can already just *set* the selection, so no new capability is
granted. Large selections via INCR aren't implemented — a client
answering with INCR yields truncated content (functional gap, not
memory-unsafe: `after > 0` → dropped/logged, `:470-471`).

**S-I — `pins.reload()` failure mode is safe, but silent.** A
transient read/parse failure keeps the last pin set
(`Sources/ledgehostd/Stores.swift:179-185`) — fail-open in the safe
direction for availability (a corrupt file does not unpair everyone)
but a failed reload also means a fresh revoke might be missed one
cycle. No change needed; noting the tradeoff was deliberate-looking.

**S-J — Pairing attempt counter is shared between `code` and `qr`.**
Failures on either method decrement the same `triesLeft`
(`Sources/ledgehostd/Pairing.swift:67-99`): an attacker who can't touch
the QR secret can still force code rotation (see F4). Intended or not,
worth a comment or separate budgets.

### Refactoring

Ordered roughly by value:

**R-1 — `Sources/ledgehostd/main.swift` is a 737-line top-level script.**
Global mutable state (`settings`, `registry`, `deviceSetText`,
`injectorStorage`), free functions, and the 450-line
`ConnectionHandler` coexist in one file doing TLS config, discovery,
session routing, media fan-out, clipboard relay, input arbitration and
shutdown. Split into `Daemon`/`Session`/`Gate` types with the wiring
explicit — this is where the F1/F2/F5 fixes will land anyway, so the
split pays for itself in reviewability. Effort **L**, benefit high.

**R-2 — Four hand-rolled length-prefixed parsers, one spec.** The
daemon's client parser (`main.swift:305-320`), `MediaRecordReader`
(`Sources/LedgehostCore/MediaRecords.swift:47-77`),
`InputOutputHandler`'s buffer loop (`Sources/ledgehostd/InputService.swift:185-205`)
and the probe's `Collector` (`Sources/ledgehost-probe/main.swift:160-171`)
each implement incremental framing with subtly different cap/error
rules (probe has **no** payload cap — a malicious or buggy peer grows
its buffer unboundedly, `main.swift:163-165`). Extract one
`FramedReader` parameterized by (header layout, cap, error policy) and
unit-test the edges F2/F8 exercise. Effort **M**, benefit high.

**R-3 — Daemon↔helper and daemon↔probe duplication.** Probe
re-implements config-dir lookup (`probe/main.swift:81-89` vs
`Stores.swift:27-35`), the P-256 SPKI head + fingerprint (`:126-131,197-206`
vs `main.swift:68-77`), the SEC1-PEM key bridging (`:138-141` vs
`:691-694`), and non-atomic stores. A shared `LedgehostClientCore`
(identity + TLS context factory + framing) removes ~150 lines and keeps
the pin rules identical by construction. Effort **M**.

**R-4 — Dead code.** `Keymap.xKeycode` (generated but never called —
`Sources/LedgehostCore/Generated/Keymap.swift:147-150`),
`MediaService.watermark` (`MediaService.swift:64`, call site uses the
NIO option directly at `main.swift:429`), `SillRandom`
(`Stores.swift:190-204`, byte-identical to `SillLinuxShims.Random` —
delete ours, use the shim), the `quit` flag in the input helper that is
never set (`helpers/ledgehost-input.c:593,645`), the unused `hostBox`
parameter in the probe's `makeClientContext`, and — a policy call —
~1.3k lines of vendored-but-unreferenced types (Audio, MacMenu,
Pointer, Gesture, TextScale, DesktopDisplays, ScrollDirection) compiled
into every binary; keeping them is defensible for protocol
completeness, but a comment in Package.swift saying so would close the
question. Effort **S**.

**R-5 — Two divergent helper-supervision implementations.**
`MediaService` (366 lines) and `InputService` (206 lines) each
implement spawn-with-minimal-env, socketpair plumbing for
NIOPipeBootstrap, stderr relay, termination→restart with
`[1,2,5,10,30]` backoff — with *different* give-up policies (media
abandons watchers after 5 fails; input restarts forever silently) and
different stop-grace behavior (media terminates immediately; input
gives 2 s for held-key release). Extract `HelperSupervisor`
(paths, env, pipe channels, stderr relay, backoff) and express the
policy differences as parameters. The socketpair dance in particular
(`MediaService.swift:174-215` vs `InputService.swift:78-112`) is
duplicated almost line for line. Effort **M**.

**R-6 — IPC constants scattered across four places.** 64 KiB stdin
buffer (helper), 256 KiB `CLIP_MAX` (helper + `Clipboard.maxTextBytes`),
1 MiB `maxClientPayload` (vendored), 32 MiB `maxPayload` (LHM1),
256 KiB `outputRecordLength` — none cross-referenced. F2 is the
observable consequence. Put the whole IPC spec in one header/one Swift
file with static asserts where the languages can't share. Effort **S**.

**R-7 — Inconsistent refusal policy.** Some undecodable payloads are
logged (`selectSource`, `viewport`, `changeSettings`), clipboard
refusals are silent, unknown session kinds log, malformed helper
records restart the helper while malformed input records only log.
A short policy table (drop/log/close per surface) would make the next
reviewer confident the mix is intended. Effort **S**.

**R-8 — Testability seams.** The testable units already exist and are
good (`InputTranslator`, `InputRateLimiter`, `MediaRecordReader`,
`AnnexB`). The untestable parts are `ConnectionHandler`'s global-state
coupling and `Process` spawning inside services — inject a
spawn-helper closure + clock (fpsSource is already a closure, a good
precedent) so session-level tests can run without X/GStreamer.
Effort **M**, benefit: regression tests for F1/F2 live naturally.

**R-9 — `handleChangeSettings` string-sniffing.**
`applied.contains(where: { $0.hasPrefix("maxFPS") })`
(`Sources/ledgehostd/main.swift:590`) decides whether to restart the
pipeline by matching log strings it just built — track the boolean
directly. Also `setBitrate` is called twice-derived: once at `:587`
inside `if applied` and once at `:588` via the whitelist re-check —
collapse. Effort **S**.

### Performance

Measured where cheap; flagged as suspected otherwise.

**P-1 — Per-frame copies and a per-byte scan in the hot path (suspected
medium).** Each access unit crosses: `ByteBuffer`→`Data` copy in
`HelperOutputHandler` (`MediaService.swift:351-353`), `buffer.append`
+ per-record `subdata` copy in `MediaRecordReader.feed`
(`MediaRecords.swift:48-72`), byte-at-a-time `data[i]` scanning plus
per-NAL `subdata` in `AnnexB.split` (`AnnexB.swift:23-55`), reassembly
into `frame` (`:87-88`), `message.serialized()` copy
(`main.swift:155-158`), then `writeBytes` into the channel buffer —
~4-5 full copies of every frame plus a Swift-indexed byte scan
(~30K indexed accesses per 30 KB AU × 60/s ≈ 1.8M/s, each with Data
bounds/briding overhead). Fix: scan via `withUnsafeBytes` once, emit
NALs as slices into a shared `ByteBuffer`, and write header+payload
without the intermediate `Data`. At 15 Mb/s this is ~10 MB/s of
memcpy — not fatal on an N150 but pure waste; expected visible win on
the capture→socket leg of the latency budget. Effort **M**.

**P-2 — `type_char` does a synchronous `XGetKeyboardMapping` round-trip
per character** (`helpers/ledgehost-input.c:218`), plus a full keymap
scan per char, plus `XSync` per scratch remap and the forced ≥30 ms
pacing for off-layout chars (`:246-254`). Real cost: a 100-char
non-ASCII `.text` takes ≥ 3 s just in pacing, plus one X round-trip
per char (the probe/driver tests observed multi-second bursts).
Fix: cache the keymap once, invalidate on `MappingNotify`, reserve 2-3
scratch keycodes to pipeline remaps. Effort **M**.

**P-3 — Full-screen `ximagesrc` grab every tick.** The pipeline uses
`use-damage=false` + `videoconvert` (CPU BGRx→NV12) at up to 120 fps
(`helpers/ledgehost-media.c:340-347`): every frame is a full
XShmGetImage + software swizzle on the N150 — the largest steady CPU
cost in the system (the plan measured it sustainable, per the P1-M0
gate note in the file header). Fix sketch: try `use-damage=true` for
idle-desktop savings, and re-benchmark `vapostproc` (the documented
"gpu" fallback) on the production driver — if it works, conversion
moves off the CPU entirely. Effort **M**, expected benefit high at
idle/low-motion.

**P-4 — Backpressure shape is sound; two edges.** Byte-accounted drop
at 4 MiB high-water + `needsIDR` resume via kind 0 + forced IDR
(`main.swift:251-264,174-195`) plus `queue leaky=downstream
max-size-buffers=1` in the helper is a coherent design. Two soft
spots: (a) the media helper *blocks* on stdout writes
(`ledgehost-media.c:68-81`) — a stalled daemon stalls the pipeline
main loop including stdin command reads; bounded in practice by the
daemon's own drops, noted for completeness; (b) `deliver()` does
`writeAndFlush` per watcher per frame — batch via `write` + one flush
after the fan-out loop. Effort **S**.

**P-5 — Idle and steady-state costs.** Confirmed cheap: no helpers run
without a watcher; the clipboard watch only runs inside the input
helper; XFixes path uses blocking `select` with no timeout
(`ledgehost-input.c:605-608`) → zero idle wakeups (the 0.5 s poll only
runs when XFixes is absent — correct fallback). `pins.reload()` does a
full file read+JSON decode every 2 s forever (`main.swift:679-680`)
— trivial but a stat-mtime guard makes it ~free. `Process.run()` for
helper (re)starts happens on the single event loop — a few ms stall
per spawn; acceptable. Per-connection 10 s `tick` is required by the
protocol (keep Wi-Fi awake), fine.

**P-6 — PBKDF2 derivation cost.** 600k HMAC-SHA256 rounds per pairing
code rotation: measured ~10 s of CPU in this debug build on this
machine (observed during the F1 reproduction: code printed ~10 s after
identity lines), ~0.1-0.3 s optimized on the N150 target. It runs once
per rotation, on the single event loop, inside `PairingManager`'s
lock — a burst of failed proofs forces repeated derivations (5 fails
→ rotate → derive) — bounded by F3's connection throttling anyway.
Not a finding against the design (the comment shows it was chosen
deliberately); noted as the cost line item.

---

## 3. What was measured / reproduced

- F1 reproduced end-to-end: paired probe → `move 10000 0` → daemon
  SIGILL (`Int32` trap), scratch port + scratch config, no live service
  touched. The primitive was also isolated in `swift(1)`.
- Pairing debug-build key-derivation delay measured incidentally (~10 s
  from identity log to pairing code) — matches the source comment's
  "~11 s debug" estimate.
- Everything else is code-read; each suspected item names the check
  that would settle it.

## 4. Top 5 across all lenses

1. **F1 (security, high):** one JSON number ≥ 2148 in an input event
   crashes the daemon — `Int32(Double)` trap; proven end-to-end.
2. **F2 (security, high):** >64 KiB op-7 clipboard record desyncs the
   input helper's stream into attacker-controlled op records — input
   injection without injector arbitration.
3. **F3 (security, medium-high):** unbounded unauthenticated TLS
   handshakes + 30 s pairing connections on a single event loop — LAN
   DoS by handshake flood or fd exhaustion.
4. **F6 + F5 (security, medium):** one scroll record → ~51k XTest
   clicks, and per-event logging before arbitration — paired-client
   resource exhaustion on two axes; both need a clamp, not a redesign.
5. **F4 (security, medium):** pairing code and QR secret never expire
   and the QR secret is written to the persistent journal — the
   pairing window is open-ended by default.
