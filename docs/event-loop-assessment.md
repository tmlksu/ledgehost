# Event-loop assessment (batch B3, item 4)

Topology and contention survey. Assessment only — no implementation
was done and none is currently recommended.

## Topology

Almost everything converges on **one single-threaded
`MultiThreadedEventLoopGroup`** (`main.swift`'s `group`,
`numberOfThreads: 1`), the "session loop":

- the accept channel and every session channel — TLS handshakes,
  reads, writes, `ConnectionHandler` protocol work;
- `MediaService`/`MediaPipeline` — helper stdout is a `NIOPipe` on
  this loop, so record framing, Annex-B conversion, and the
  per-watcher message build + `writeAndFlush` all run here;
- `InputService` — input-helper pipes and clipboard text callbacks
  (`loop.execute` hops);
- `WindowTracker`, `PointerTracker` — helper stdout is read on
  `readabilityHandler` GCD queues, but all state changes hop back
  with `loop.execute`;
- timers — pairing-code expiry poll (30 s), per-connection stats
  ticks and deadlines, pipeline debounce/restart delays;
- `registry`, `pairing` (NSLock), `pins` (NSLock) — shared state
  touched here and by the admin path.

Outside the session loop:

- `AdminServer` — its own single-threaded group; crosses into the
  session loop only via `eventLoop.submit` for session-registry work;
- `DispatchQueue("ledgehost.pairing.derive")` — serial PBKDF2
  derivations (added in the pairing fix below);
- `readabilityHandler` queues — helper stderr relays and tracker
  stdout producers; line-buffered, low rate.

## Contention found and fixed (batch B3)

- **PBKDF2 on the serving path** — `rotateLocked()` ran a ~10 s
  600k-round derivation inside `answerProof` on the session loop
  (pairing success, tries-exhausted, TTL timer), and admin
  `code --new` held the pairing `lock` across a derivation, stalling
  pairing answers. Moved to the serial derive queue with atomic swap
  and coalescing; measured zero frame-gap at ~60 au/s through two
  back-to-back derivations. Fixed.
- **Annex-B byte-wise scan** — `AnnexB.split` indexed `Data` per
  byte, ~11 ms per AU: ~65 % of a core (debug) / ~30 % (release) at
  60 fps / 15 Mbps. Rewritten to scan a `withUnsafeBytes` pointer;
  now ~7 % (debug) / ~2 % (release). Fixed.

No other contention was observed in any B3 measurement or in the
daemon logs (no gaps in `au/s`, `frameAge` stayed single-digit ms
during rotations and admin traffic).

## Remaining theoretical contention

- The session loop serializes **all** session I/O plus all media
  delivery. Cost scales with (watchers × bitrate × fps); a stalled
  or slow consumer is handled by backpressure (per-session
  `dropping`/`needsIDR` states), not by extra capacity.
- Helper stderr relays and tracker stdout parse on GCD queues that
  call `Log.stamp()` concurrently with the loop — proven safe
  (Foundation `DateFormatter` is internally mutex-synchronized in
  the shipped libFoundation; documented in `Stores.swift`).
- The pairing `lock` is still taken on the session loop for map
  reads/swaps — nanosecond-scale, fine.

## What separation would look like

- A second `EventLoopGroup` for media pipelines: helper stdout
  pipes, record framing, and conversion move off; per-watcher writes
  must then hop back onto each session's loop (`channel.eventLoop`)
  for delivery — every AU becomes a cross-loop hop.
- Estimated cost: a day of wiring plus subtle lifetime/backpressure
  rework (`watcher.state` transitions, `needsIDR` resume atomicity,
  pipeline↔session teardown ordering). Risk sits exactly in the
  ordering guarantees the current single loop gives for free.

## Recommendation

**Defer.** Post-fix numbers leave large headroom on the serving
loop (~2 % of a core in release at the default 15 Mbps / 60 fps /
single watcher), and both observed contention sources were specific
fixable code paths, not topology limits. Revisit if any of these
triggers appear:

- daemon CPU > ~25 % of a core in release at the default stream, or
  scaling linearly with watcher count past a few watchers;
- `frameAge` / `au/s` gaps in `stats` logs that correlate with
  pairing, admin, or input traffic;
- a second always-on high-rate pipeline (e.g. audio) that would
  share the loop with media.
