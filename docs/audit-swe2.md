# ledgehost code audit — SWE-2

Scope: `Sources/ledgehostd`, `Sources/ledgehost-probe`, `Sources/LedgehostCore`,
`Sources/SillLinuxShims`, `helpers/*.c`, `Vendor/StreamProtocol` (patches +
integration points only), `scripts/`, `deploy/ledgehost.service`, `Makefile`.
Commit audited: `8ac0481` (main). Audit only — no code changes.

Findings are marked **[proven]** (demonstrated or directly verified in code)
or **[suspected]** (static analysis, plausible but unmeasured/unreproduced).

---

## SECURITY

Threat model: (a) unpaired LAN client — TLS 1.3 only, any P-256 self-signed
cert completes the handshake, then the ALPN gate (`sill-pair/1` open,
`sill/1` requires a stored pin); (b) paired client — full input injection +
clipboard + stream control, by design; (c) untrusted X apps — clipboard
content and selection protocol peers.

### S1 — [proven] Paired client crashes the daemon with one kind-8 message (non-finite Double → `Int()` trap)

`handleInput` logs every decoded `InputEvent` *before* the injector/rate
checks — so **any paired session** (no need to be the injector) reaches:

- `main.swift:475` — `.pointer`: `Int(x*1000)`, `Int(y*1000)`
- `main.swift:477` — `.scroll`: `Int(dx*1000)`, `Int(dy*1000)`

A JSON double like `1e308` decodes fine (verified: `JSONDecoder` accepts
`{"x":1e308}`; `1e999` is rejected, `1e308` is not). `Int(1e308*1000)` =
`Int(inf)` **traps** ("Double value cannot be converted to Int because it is
either infinite or NaN") — verified live: the trap fires in a standalone
Swift program on this toolchain.

Even if the log lines are removed, the same trap exists in the translator
for the injector session:

- `InputRecords.swift:41-42` — `Int32((x*1e6).rounded())`, `Int32((y*1e6).rounded())`
- `InputRecords.swift:48-49` — `Int32((dx*1e6).rounded())`, `Int32((dy*1e6).rounded())`

Impact: remote DoS — daemon aborts; `Restart=on-failure` revives it, but the
attacker can re-crash after each `selectSource`. Also note `Int(x)` traps on
*finite* overflow too (e.g. `Int(1e20*1000)`), so clamping to finite is not
enough — the conversion itself must be range-guarded.

Severity: **high** (trivially triggered, single message, kills the daemon;
only a paired client, but pairing is the trust boundary this host ships).

Fix sketch: sanitize doubles at the decode boundary — in `handleInput`,
`guard x.isFinite, y.isFinite, abs(x) < 1e15 …` before logging; in
`InputRecord.pointer`/`scroll`, clamp `x*1e6` to `Int32` range (or
`Int32(clamping:)`-equivalent guard) before converting. The vendored code
already solves this pattern — `ViewportBounds.whole`/`number`
(`Vendor/StreamProtocol/Viewport.swift:75-95`) use `Int(exactly:)` with a
fallback. Add a regression test decoding `1e308` payloads.

Effort: **S**.

### S2 — [proven] Scroll accumulator has no magnitude bound: one scroll event = ~50,000 X button clicks

`helpers/ledgehost-input.c:288-301` — `scroll_acc_y += <int32 from wire>`,
then `while (scroll_acc_y >= per) { hold_btn(Button4…); … }`. A single op-2
record can carry `dy = 2^31-1` → ~51,000 click pairs enqueued as XTest
requests in one loop — the helper stalls for tens of seconds and the desktop
scrolls catastrophically. The daemon rate limiter bounds events/s, not
per-event magnitude.

Severity: **medium** (paired injector only; self-limited to helper stall +
wild scroll; no memory unsafety).

Fix sketch: clamp each delta to a sane range (e.g. ±4 frame-fractions →
`max(±4e6, dx)`) in the helper, or cap `|scroll_acc|` and drop the excess.

Effort: **S**.

### S3 — [proven] Clipboard fetch wedges permanently on a non-answering owner

`helpers/ledgehost-input.c:413-421` — `fetch_clipboard_text` sets
`conv_pending = 1`; it is cleared only in `got_selection_text`
(`:434-477`) on a `SelectionNotify`. If the owner never replies (crashed
owner, odd client that swallows the request), no notify ever arrives:
`conv_pending` stays 1 forever, every later owner change only sets
`conv_recheck`, and `owner_moved()` re-queries but `fetch_clipboard_text`
still returns early. Host→device clipboard is dead until the helper
restarts.

Severity: **medium** (real-world X apps occasionally refuse/ignore
conversion; silent total loss of one sync direction).

Fix sketch: arm a timeout (e.g. `conv_deadline = now + 2 s`) when sending
`XConvertSelection`; on expiry clear `conv_pending` and process
`conv_recheck`.

Effort: **S**.

### S4 — [proven] 1-byte stack overwrite in media-helper stdin handler

`helpers/ledgehost-media.c:199-205` — `char buf[256]`,
`ssize_t n = read(fd, buf, sizeof buf)` (n ≤ 256), then `buf[n] = 0` —
when `n == 256` this writes one NUL byte past the array. Sender is the
daemon (trusted), value is NUL, and `-fstack-protector-strong` would abort
rather than be exploitable — but it is a real defect.

Severity: **low** → fix trivially: `read(fd, buf, sizeof buf - 1)` or
`char buf[257]`.

Effort: **S**.

### S5 — [proven] No timeouts or rate limits on unauthenticated connection phases

- TLS handshake has no deadline — an unpaired client can hold a connection
  in `awaitingGate` indefinitely; each connection costs a full TLS 1.3
  handshake (CPU on an N150) plus channel state. Connections are unbounded
  (`backlog: 8` only sizes the accept queue). `main.swift:267-296`.
- `awaitingHello` has no deadline for *pinned* clients — a paired (or
  stolen-key) client can park unlimited sessions, each ~1 MiB of input
  buffer headroom + a 10 s tick task.

Severity: **low-medium** (LAN-only, slow resource burn; the pin gate keeps
the attack surface small).

Fix sketch: schedule a handshake/hello deadline (10–30 s) in
`channelActive`; consider a max-connection count.

Effort: **S**.

### S6 — [proven] Per-connection log flooding from paired clients

`handleInput` prints one line per kind-8 message **before** any rate check
(`main.swift:473-484`); `clientStats` prints per message (`:388-390`);
`keyframeRequest`/`viewport`/`clipboard` also log. A paired client at line
rate fills the journal (disk) and burns event-loop CPU on formatting —
independent of the 240/s *injection* limiter, which only guards XTest.

Severity: **low-medium**.

Fix sketch: rate-limit log lines per kind per session (e.g. first N lines
then 1/s summary), or demote hot paths to a sampling counter.

Effort: **S**.

### S7 — [suspected] Viewport/settings churn can thrash the encoder pipeline

`handleViewport` (`main.swift:536-543`) calls `media.restart()` whenever a
client's wanted fps changes; `handleChangeSettings` (`:590-592`) likewise
on maxFPS changes. There is no per-session rate limit on kind 9/17: a
client alternating 24↔30 fps in every message forces continuous
pipeline teardown/respawn (each ~300 ms + gst init), starving the stream.

Severity: **low-medium** (paired client, self-inflicted quality loss — but
it also degrades *other* sessions' picture).

Fix sketch: debounce restarts (e.g. at most one per few seconds globally;
`restart()` already schedules on the loop — add a last-restart stamp).

Effort: **S**.

### S8 — [proven] Clipboard relay forwards `image` payloads verbatim, against generation-1 rules

`handleClipboard` relays the *raw* payload to other subscribers
(`main.swift:514-516`). `Clipboard` has an `image: Data?` field
(`Vendor/StreamProtocol/Clipboard.swift:24-25`): a device sending
`{"image":"<up to ~750 KB base64>"}` + no text is treated as a
**subscribe** (`ClipboardPolicy.fromDevice` → `.subscribe`), and the
verbatim payload — including the image — is fanned out to every other
subscriber. The generation contract says a host sends `image` only to a
connection that opted in (`Clipboard.swift:11-16`); generation-1 peers
should drop it.

Severity: **low** (paired-to-paired bandwidth abuse + contract violation;
images are ignored by this-generation receivers anyway).

Fix sketch: on `.set`, re-encode via `ClipboardPolicy.payload(text:)` and
relay *that*, not the received bytes.

Effort: **S**.

### S9 — [proven] Echo-suppression token never cleared on mismatch

`main.swift:117-122` — `deviceSetText` is set on every device `.set` but
only cleared when the helper reports *identical* text. A foreign copy of
any *other* content leaves the stale value in place: if a later foreign
copy happens to equal it, that copy is wrongly suppressed. Also, after
several device sets, only the last is remembered — earlier ones can echo
back.

Severity: **low** (missed sync in an edge case).

Fix sketch: clear `deviceSetText` on the first non-matching report, or keep
a small set of recently-set texts.

Effort: **S**.

### S10 — [proven] `PairingCode.generate() ?? "000000000000"` fallback

`Sources/ledgehostd/Pairing.swift:37` — if RNG fails, the code becomes a
*known constant* which passes the Damm check (interim stays 0) — five
guesses then pair a device. `SillRandom.fill`/`SillLinuxShims.Random.fill`
currently always return `true` (`Stores.swift:191-203`,
`Shims.swift:46-56`), so this is dead code today — but it is a trap for any
future entropy-source change.

Severity: **low**.

Fix sketch: treat a nil generate as fatal (`preconditionFailure`) rather
than substituting a constant.

Effort: **S**.

### S11 — [proven] Pairing link (16-byte QR secret) and code are written to the journal

`Pairing.swift:43-46` logs `pairing: link sill://pair?…&s=<secret>…` and
the 12-digit code at every rotation. The secret is the full credential for
the QR path. Anyone who can read the user journal (the service's own
user, any app running as that user) gets a live pairing credential until
it rotates. Also attacker-triggerable
rotation → log growth.

Severity: **low** (journal is user-private; rotation bounds exposure).

Fix sketch: log the link only when actually needed, or redact `s=` (the
code must be shown to the user somehow — the journal is the current UI).

Effort: **S**.

### S12 — [proven] `PinStore.reload()` silently keeps stale pins on read/parse failure

`Stores.swift:179-185` — any error reading/decoding `paired.json` keeps the
in-memory copy. A corrupted file (or an attacker who can only corrupt, not
write) silently disables *revocation*: removed pins stay accepted, since
reload is the unpair path's mechanism. Fail-stale is reasonable for reads,
but the failure is invisible — no log line at all.

Severity: **low**.

Fix sketch: log once when reload fails.

Effort: **S**.

### S13 — [proven] `atomicWrite` does not fsync the containing directory

`Stores.swift:43-57` — file is written, fsynced, renamed — but the
directory entry itself is never synced; a power cut at the wrong moment
can lose the rename. Identity loss is loud-fail (good design choice), but
a *new pin* could silently vanish across a crash.

Severity: **low**. Effort: **S** (open+fsync dir fd after rename).

### S14 — [proven] systemd unit: hardening gaps worth noting

`deploy/ledgehost.service` — good posture (UMask 0077, NoNewPrivileges,
ProtectSystem=strict + ReadWritePaths, RestrictAddressFamilies). Gaps,
all constrained by the unit needing real user + X access:

- `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`,
  `ProtectClock`, `ProtectHostname` are all available and free of the
  documented breakage — currently absent.
- `SystemCallFilter=` would be high-value (the daemon needs a fairly small
  syscall surface) but requires real testing on this GStreamer stack —
  flagged as candidate, not defect.
- `RestrictAddressFamilies` correctly keeps AF_NETLINK (udev/GStreamer).

Severity: **low**. Effort: **S** for the free directives, **M** for
SystemCallFilter.

### S15 — [proven] `--env`/`--port` values are interpolated into the unit unvalidated

`scripts/install-service.sh:85-94` — `echo "Environment=$e"` writes
attacker-supplied (or accident-supplied) newlines into `site.conf`; a
`--env` value containing `\nExecStartPost=/bin/foo` injects a unit line.
Self-inflicted (the user runs the script as themselves), but a validation
pass costs little.

Severity: **low**. Effort: **S** (reject `\n`, `=`-less, whitespace-first values).

### S16 — [proven] Helper stdin framing desync is resynced silently, not fatally

`helpers/ledgehost-input.c:617-619` — a bad `len` is logged and clamped to
buffer size, then the stream resumes mid-record: the helper treats bytes
that are almost certainly garbage as a 64 KiB record. Not exploitable
(daemon is the only writer), but it converts a detectable protocol bug
into silent misbehavior; contrast with the media path, where a bad header
kills the helper (`MediaService.feed` → restart).

Severity: **low**. Effort: **S** (exit on bad len; the daemon restarts it).

### S17 — [proven] `emit_record` ignores partial writes

`helpers/ledgehost-input.c:371-372` — `(void)!write(1, hdr, 5)` — a
short write (signal interruption mid-write) corrupts the output stream;
the daemon then sees a framing violation. Rare; honest fix is a `write_all`
loop like the media helper has (`ledgehost-media.c:68-81`).

Severity: **low**. Effort: **S**.

### S18 — [proven] Sub-byte protocol nits on the X selection path

- `serve_selection` answers `TIMESTAMP` with `Time t = 0`
  (`ledgehost-input.c:395-399`) — wrong value; serve the time at which
  ownership was taken (`XSetSelectionOwner` timestamp). Clients that
  compare timestamps can mis-order.
- `XConvertSelection`/`XSetSelectionOwner` use `CurrentTime`
  (`:419`, `:549`) — ICCCM-correctness is loose here; strict owners may
  refuse. Worked against GTK/VTE in testing, so cosmetic-to-low.

Severity: **low**. Effort: **S**.

### S19 — [proven] Injection surface notes (by design, documented)

A paired injector session can drive arbitrary XTest input on the whole X
display — that *is* the product — but two details are worth recording:

- Arbitration is "most recent .desktop selector injects"
  (`main.swift:419-425`): any paired device can seize injection from
  another paired device by re-selecting. Per decision 10; noted, not a bug.
- `watcher = MediaService.Watcher()` reset on re-selection
  (`main.swift:428`) also resets `rateLimiter` and `lastKeyframeRequest` —
  the 240/s daemon-side limit is bypassable by re-selecting; the helper's
  own 240/s bucket (`ledgehost-input.c:557-567`) still caps the X side,
  so the net effect is nil. Cosmetic.

Severity: **low/informational**. Effort: —.

### What is *not* a finding (verified clean)

- TLS: 1.3-only, custom verification callback checks P-256 SPKI shape
  (`main.swift:68-77`); ALPN gate runs before any app decode; `sill/1`
  requires a stored pin (`:285-291`); live revocation poll every 2 s
  (`:679-688`). Probe verifies the saved pin post-handshake
  (`ledgehost-probe/main.swift:340-342`).
- Pairing: PBKDF2 derived once per rotation, not per attempt (no DoS
  amplification); proofs verified in constant time; fingerprint taken from
  TLS, never the message; 5 tries → new random code; malformed proofs and
  `v != 1` don't consume tries; `maxPairingPayload` = 4096 and the pairing
  connection gets exactly one message + 30 s deadline.
- Input: daemon validates usage ≤ 0xFF against the keymap before the
  helper; helper re-validates (`xkc` range + table bound). Pointer coords
  clamped to [0,1]. Held state released on session end/helper exit.
- Helper stdout protocol: `MediaRecordReader` enforces magic/version/
  tag/length/timestamp-window strictly; violations restart the helper.
- Stores: 0700 dir, 0600 files, atomic rename, corrupt identity is a loud
  failure, never regenerated.
- No secrets or clipboard/text content are logged anywhere (sizes only);
  `LH_CLIP_DEBUG` logs atom names + sizes only.

---

## REFACTORING

Ordered by value.

### R1 — `main.swift` is a 737-line god file — split it

Everything lives in one file: TLS bootstrap, `ConnectionHandler` (~460
lines, 8 message families), `SessionRegistry`, clipboard fan-out, the
server bootstrap, and signal handling. The handler mixes wire parsing,
session lifecycle, input, clipboard, settings, and media wiring.

Proposal: `ConnectionHandler.swift` (handler + state machine),
`TlsBootstrap.swift` (context + callback + bind), `Catalog.swift`
(`sendCatalog`/`sendWindowList`/`settingsState`), `ClipboardRelay.swift`
(`handleClipboard` + `onClipboard` wiring). `main.swift` keeps only
wiring + the event loop.

Effort: **M**. Benefit: the biggest single readability win; the input and
clipboard handlers are already cleanly separable — they only touch the
registry and one service each.

### R2 — Duplicated helper-spawn/pipe/socketpair dance between MediaService and InputService

`MediaService.attachPipes` (`:174-215`) and `InputService.start`
(`:78-112`) implement the same `NIOPipeBootstrap` + `socketpair` +
`dup(fd)` plumbing twice, with slightly different shapes (one pipes
stdout, the other both directions). The same "spawn with minimal env +
stderr relay + termination handler" code is duplicated too.

Proposal: a `HelperPipe`/`spawnHelper` utility in `LedgehostCore` (or a
new `HelperService` base): path resolution, env construction, pipes,
stderr relay, termination → failure callback.

Effort: **M**. Benefit: kills the largest duplication; also unifies the
restart-backoff which is currently copy-pasted (see R3).

### R3 — Duplicated restart backoff in both services

Identical `restarts`/`lastRestart`/`[1,2,5,10,30]` logic in
`MediaService.helperFailed` (`:241-254`) and `InputService.failed`
(`:149-158`). Extract a `RestartBackoff` struct (attempts, last-attempt,
next delay, reset-on-success).

Effort: **S**. Benefit: single place to tune; less drift.

### R4 — Duplicated TLS/SPKI/config code between daemon and probe

`p256SPKIHead` + `peerFingerprint` (`main.swift:68-77` vs
`ledgehost-probe/main.swift:126-129,197-206`), the EC-private-key→PEM
serialization (`main.swift:691-694` vs probe `:138-141`), and
`configDirectory`/`probeConfigDirectory` (`Stores.swift:27-35` vs probe
`:81-89`) are copy-pasted. Move `peerFingerprint`/SPKI-head and the PEM
helper into `LedgehostCore` (or StreamProtocol's shim layer); share
`configDirectory` (probe's is identical minus the app name).

Effort: **S-M**. Benefit: one implementation of the fingerprint check —
the security-critical part — not two that can drift apart.

### R5 — `SillRandom` duplicates `SillLinuxShims.Random`

`Stores.swift:191-203` reimplements `Random.fill` byte-for-byte; the
comment even says "the same system source". `ledgehostd` can just import
`SillLinuxShims` (it's already a transitive dep via StreamProtocol) or the
shim can be made public API and used directly.

Effort: **S**.

### R6 — `send(context:)` vs `send(kind:)` — two copies of the same serializer

`main.swift:322-340`: the two functions serialize the same `StreamMessage`
twice (one uses `context.channel.allocator`, the other `channel.allocator`)
— identical bodies. Collapse to one taking a `Channel`; the context variant
just forwards `context.channel`.

Effort: **S**.

### R7 — `MediaService.Watcher` is doing three jobs

`MediaService.swift:28-36` — `Watcher` holds media resume state
(`state`/`droppedAUs`), per-session input state (`translator`,
`rateLimiter`), and fps preference (`wantedFPS`). It lives in MediaService
but is owned by the connection. Split: media resume fields stay; input
fields move to the `ConnectionHandler` (or a dedicated `InputGate`).

Effort: **S-M**. Benefit: `Watcher` stops leaking input concepts into the
media service.

### R8 — Dead code and stale comments

- `helpers/ledgehost-input.c:592,645` — `int quit = 0` is set nowhere;
  `if (quit) break;` is dead.
- `helpers/ledgehost-media.c:59,386,392` — `pipe_clock` fetched, unref'd,
  never used (was probably for a pts→wall conversion that became
  `rt0 + pts − pts0`).
- `Sources/ledgehostd/MediaService.swift:64` — `static let watermark` is
  unused (the option is set inline at `main.swift:429-431`).
- `Makefile:5` — comment says `make helpers` builds "ledgehost-media into
  bin/" — it builds four binaries.
- `Sources/ledgehostd/main.swift:428` comment says `// .needsIDR` —
  accurate but cryptic.

Effort: **S** each.

### R9 — `ledgehost-probe/main.swift` is a 557-line single file with 5 modes

Each mode (`pair`, `connect`, `record`, `input`, `clipboard`) is a
self-contained block in one `if/else` chain. Splitting by mode would help
navigation, but as a *test tool* this is acceptable — low priority.

Effort: **M**, benefit low.

### R10 — Testability gaps

- `handleInput`'s crash on non-finite doubles (S1) is untestable today:
  `ConnectionHandler` is glued to NIO `ChannelHandlerContext` + the
  registry. Extracting `translate`/rate-check into the already-pure
  `InputTranslator`/`InputRateLimiter` would let unit tests cover it.
  The double-sanitization fix (S1) should land in `InputTranslator` or a
  pure `sanitize` step precisely so it is testable.
- `PinStore`/`HostIdentity`/`atomicWrite` have no unit tests (atomicity,
  permissions, corrupt-file loud-fail).
- The C helpers have no unit tests at all; the e2e scripts
  (`real-app-roundtrip.sh`, `loopback-e2e.sh`) are the coverage.
  A header-level `utf8_at`/`rate_ok` test would be cheap insurance.

Effort: **M**. Benefit: the S1 crash class becomes a `swift test` line.

### R11 — `handleSets` + `handleAU` redo work per AU

`MediaService.swift:293-305` — on every AU that carries in-band sets, the
daemon rebuilds the ParameterSets payload (`ParameterSets(...).encoded()`)
and compares it against `setsPayload`. The helper already emits a sets
record on change; the AU-side re-encode is belt-and-suspenders. Fine to
keep for robustness, but the conversion path runs twice per IDR AU.

Effort: **S**. Benefit low — keep if felt necessary, else trust the
helper's sets record.

---

## PERFORMANCE

Production target: Intel N150, 60 fps, 1600×1200 capture.

### P1 — [proven] Helper CPU is ~12% of one core at 60 fps capture+encode

Measured live on :21 (`bin/ledgehost-media --source x11 --fps 60`,
stdin held, 8 s window): **~12% CPU** (jiffies delta), RSS ~113 MB,
`capture→au-out` −0.5..−3.4 ms, 60 au/s. The 60 fps path is well within
N150 budget. Encoding is on the iGPU (msdk); the CPU cost is mostly
ximagesrc → videoconvert → write.

### P2 — [proven] Latency budget post-B-frame-fix is healthy

`capture→au-out` ≈ 0–3 ms helper-side (was ~−50 ms with B-frames);
probe-measured `frameAge p50 ≈ 10 ms` end-to-end. The pending-move
coalescing, per-session water-mark drop policy, and 250 ms forced-IDR
coalescing are all present and correct.

### P3 — [suspected] Per-AU copies on the fan-out path

`MediaService.feed` → `MediaRecordReader.feed` (Data append + subdata
copy) → `AnnexBConverter.convert` (new `frame` Data) →
`StreamMessage.serialized()` (new Data) → `ByteBuffer.writeBytes`
(copy into buffer) → per-session `readSlice` (zero-copy share, good).
~3 full AU copies per frame at ~31 KB avg — ~6 MB/s of memcpy at 60 fps —
negligible on N150 but trivially reducible (feed ByteBuffer slices through
to `writeAndFlush` instead of Data).

Severity: **informational**. Effort: **S** to halve.

### P4 — [proven] 2 Hz `pins.reload()` + stats tick + per-second helper stats — idle cost is small

`pins.reload()` (`main.swift:679-688`) reads+JSON-decodes `paired.json`
every 2 s unconditionally (sub-second syscall + tiny JSON — fine but
nonzero); helpers only run while watchers exist (5 s debounce), and the
input helper's event loop is `select()`-driven — idle cost is a couple of
wakeups/s total. Reasonable; the pin reload could instead stat-mtime-check
before decoding.

Effort: **S** (skip the JSON decode when mtime unchanged).

### P5 — [proven] 30 ms Unicode pacing is the dominant per-char typing cost

`ledgehost-input.c:246-254` — ≥30 ms between a press and the next scratch
remap. For a run of k unmapped chars: ~(k−1)·30 ms of `nanosleep`, during
which the helper's select loop is blocked (ops queue up). 10 Japanese
chars ≈ +270 ms; a 4096-char text of unmapped chars ≈ 2 minutes (and the
helper can't process a `release`/exit promptly mid-string).
`XGetKeyboardMapping` per char adds a round-trip per char (~50–100 µs —
irrelevant next to 30 ms).

Fix sketch if it becomes a problem: reduce to the measured ~15 ms floor
with margin (e.g. 18–20 ms), or batch: remap once per unique char and
reuse it (the map lives until the next remap anyway — a cache of
`keysym→kc` would let repeated chars skip both the remap and the wait).

Effort: **M**. Suspected worth doing — only matters for heavy IME users.

### P6 — [proven] Backpressure and queue policy are correctly bounded

Per-session write water mark `max(4 MiB, 2×IDR)` (`MediaService.swift:62`),
`.dropping`/`.needsIDR` resume path with kind-0-then-IDR atomicity
(`main.swift:171-195`), 10 s tick polling the water mark (`:365-371`),
leaky pre-encoder queue `max-size-buffers=1`, `appsink max-buffers=8`.
Memory per stalled session is bounded to ~water mark; global helper stdout
is drained on the single event loop. Verified design; the stall probe
(`--stall`) exercised it in P1-M4.

### P7 — [suspected] `scan_sets` runs a full byte scan of every AU

`ledgehost-media.c:115-135` — O(AU) scan for `00 00 01` codes on every
frame to detect sets changes (~30 KB × 60/s = 2 MB/s — cheap). But it's
redundant work when the encoder never changes sets mid-stream (only on
IDR/keyframe). Could skip unless `keyframe` flag set. Tiny win.

Effort: **S**.

### P8 — [proven] `pins.reload()` unconditionally — same as P4; also `XGetSelectionOwner` poll when XFixes missing

The 0.5 s clipboard poll fallback (`ledgehost-input.c:593-598`) is an
extra X round-trip 2×/s when XFixes is absent — negligible, and XFixes is
present on :21.

---

## TOP 5 (across all lenses)

1. **S1** — paired client → one-message daemon crash via `Int(1e308*1000)`
  in `handleInput`'s log path (before injector check) and again in
  `InputRecord.pointer`/`scroll`. Fix is a finite/range guard, effort S.
2. **S3** — `conv_pending` has no timeout: one non-answering clipboard
  owner wedges host→device clipboard for the helper's lifetime.
3. **S2** — unbounded scroll accumulator: one scroll event → ~50k X clicks.
4. **R1/R2** — `main.swift` god-file + the duplicated helper-spawn/
  backoff code between MediaService and InputService; the two highest-
  value refactors.
5. **S5** — no handshake/hello deadlines or connection cap: unpaired
  LAN client can hold unbounded half-open TLS connections (bounded
  resource burn on N150).
