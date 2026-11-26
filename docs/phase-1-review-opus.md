# Phase 1 plan — adversarial design review (Opus)

Reviewed: `docs/phase-1-plan.md` (draft of 2026-11-26), against
`docs/phase-0-plan.md`, `Vendor/StreamProtocol/{StreamMessage,Input,Viewport,Switcher,Pointer,HostSettings,Compatibility}.swift`
and `Sources/ledgehostd/{main,Stores,Pairing}.swift`. Read-only review;
nothing else was changed.

Grounding labels: **[src]** = read in a named file; **[doc]** = a
measurement or observation recorded in the docs; **[fp]** = my
reasoning from first principles or general knowledge of
X11/GStreamer/NIO, not verified in this repo.

---

## 1. Verdict

**Proceed with changes.** The shape (out-of-process media and input
helpers, one shared pipeline, kind 0/1 conversion in the daemon,
cursor out of the video) is right, but two baked-in decisions are wrong
as written — the HID→X keycode rule (keycode = usage + 8 is not the
evdev convention, so every key would be wrong) and backpressure placed
in a daemon queue that NIO's unbounded outbound buffer will bypass — and
the plan's highest-risk unknown (60 fps capture on the seat display) is
scheduled after the integration work that depends on it.

---

## 2. Required changes

1. **Replace "keycode = usage + 8" with a HID-usage → Linux KEY_* table,
   then +8.** The evdev convention is *X keycode = Linux input keycode +
   8*, and Linux keycodes are not HID usages: HID `0x04` (A) is
   `KEY_A` = 30 → X keycode 38, whereas usage + 8 = 12 (`3` on a US
   layout). `Input.swift` says the client sends USB HID usages
   (UIKeyboardHIDUsage) [src]; the table is the one in the Linux
   kernel's `hid-input.c` (`hid_keyboard[]`) [fp]. *Prevents:* every
   hardware-keyboard key typing the wrong character in M3. Unit-test the
   table (letters, digits, Return/Escape/Backspace/Tab, arrows, F-keys,
   0xE0–0xE7 modifiers) without X.

2. **Put backpressure on the NIO channel, not only in a daemon-side
   queue.** `ConnectionHandler.send` does `context.writeAndFlush` with no
   writability check [src]; NIO's outbound buffer is unbounded, so a
   "bounded per-session queue" in front of it will always look empty
   while frames pile up inside the channel. Specify: a
   `WriteBufferWaterMark` per session channel (bytes, sized to ~2–3
   keyframes, see P3), the drop decision taken on
   `channel.isWritable` / `channelWritabilityChanged`, and the queue
   accounted in **bytes**, not AUs. *Prevents:* a slow Wi-Fi client
   growing daemon memory without bound and the "drop until keyframe"
   policy never triggering.

3. **The drop policy must never drop a kind 0, and must re-send the
   current parameter sets before the IDR it resumes on.** Decision 4
   drops "access units until the next keyframe"; if the sets change
   (resolution change, pipeline restart, bitrate retune that re-emits
   VPS/SPS/PPS) while a session is in the dropping state, the session
   resumes on an IDR it cannot decode. Rule: on resume, enqueue
   `kind 0 (current sets)` then the IDR, atomically. *Prevents:* a
   permanently black/frozen client after any set change under load.

4. **Measure 60 fps capture on the seat display before M2, as a
   gate (call it P1-M0).** Phase 0 measured capture only on the
   remote-desktop dummy display and recorded the seat display as "still
   open" [doc]. Moreover, the recorded 25 fps is suspect as a display
   cap: `ximagesrc` paces itself by its negotiated caps, not by display
   refresh, and when the framerate is left unconstrained its fixate
   picks 25/1 [fp — verify]. Run, on the seat session, `ximagesrc
   use-damage=false show-pointer=false ! video/x-raw,framerate=60/1 !
   vapostproc ! video/x-raw(memory:VAMemory),format=NV12 ! vah265lpenc
   ! fakesink sync=false` (and the `videoconvert` variant) and record
   fps and CPU. *Prevents:* building the helper and integration
   around a pipeline that cannot sustain 60 fps, or misattributing a
   caps default to the display.

5. **Specify the ximagesrc properties explicitly, including
   `show-pointer=false`.** `ximagesrc`'s `show-pointer` defaults to
   true [fp]; Decision 5 ("cursor OUT of the video") silently fails
   otherwise and the client then shows two pointers. Also pin
   `use-damage=false` (what Phase 0 measured [doc]) and explicit
   framerate caps.

6. **Define the source rectangle once and use it for both capture and
   input mapping.** `ximagesrc` with no `xid`/`startx..endy` captures
   the whole root window, which spans every monitor [fp]. "The
   display's own resolution" must be a concrete rectangle (the primary
   RandR output's CRTC, or the root window if single-head), passed to
   both helpers, and input fractions mapped as
   `x_px = rect.x + clamp(x,0,1) × (rect.w − 1)`. Detect RandR changes
   (resolution or layout) and restart the pipeline with new sets.
   *Prevents:* clicks landing offset or on the wrong monitor, and a
   pipeline that errors out on an xrandr change.

7. **Release all held input on every session end and helper restart.**
   With XTest, a `key down`/`leftDown` whose `up` never arrives
   (connection drop, client backgrounded, daemon crash) leaves a stuck
   key — and the X server's autorepeat will repeat it indefinitely [fp].
   The input helper must track held keycodes/buttons per originating
   session and release them on `RESET <session>` / EOF on stdin / exit.
   *Prevents:* a runaway repeating key or a stuck drag on the host after
   a Wi-Fi blip.

8. **Make the daemon→helper pipes non-blocking, bounded, and
   SIGPIPE-safe.** The daemon runs one event-loop thread for everything
   (`MultiThreadedEventLoopGroup(numberOfThreads: 1)` [src]); a
   blocking write to a full input-helper stdin (a client flooding kind 8;
   the cap is 1 MiB per message [src]) stalls every session's video.
   Also ignore SIGPIPE in the daemon (`signal(SIGPIPE, SIG_IGN)`; none is
   set today [src]) — writing to a dead helper's stdin otherwise kills
   the daemon and every session with it. Use `NIOPipeBootstrap` (or
   equivalent) for both directions on the event loop. *Prevents:*
   whole-host stalls and daemon death on a helper crash.

9. **Define the line protocol's encoding so text cannot break framing.**
   `InputEvent.text` is arbitrary Unicode and explicitly includes `"\n"`
   [src]. A naive line protocol lets a text payload end one command and
   begin another. Either length-prefix (`TEXT <nbytes>\n<bytes>`) or
   percent/hex-escape the payload; the helper rejects anything else.
   *Prevents:* framing desync and command forgery between the daemon
   and the helper.

10. **Fold keyframe-on-join and keyframeRequest (kind 44) into M2.**
    Decision 3 already requires a forced keyframe on join for M2's
    picture to appear promptly, and it is the same stdin `KEYFRAME`
    command. The client sends kind 44 whenever its display layer is
    interrupted [src]; testing M2 on the real client without honouring
    it produces confusing freezes. Keep M4 for reconnect/soak/stats.
    Implement upstream's host rule "at most one a second per
    connection" [src] **and** coalesce globally (one IDR per ~250 ms
    across all sessions). *Prevents:* M2 acceptance being judged on a
    picture that only appears at the next GOP boundary, and one client
    driving the shared encoder into back-to-back IDRs.

11. **State the encoder configuration: rate control, VBV, GOP,
    bitrate scaling.** The plan names a "1 s GOP" (Decision 4) but not
    where it is set, and no rate-control mode or buffer size. Required:
    `b-frames=0`, `key-int-max` (see P2), `rate-control=cbr` (or VBR
    with a cap) and a small `cpb-size` (≈ 1–2 frames' worth) so frame
    sizes — and hence send time — are bounded. Bitrate on the wire is
    **per 60 fps** (`StreamSettings.bitrate`: "a 120 fps stream gets
    twice as much"; `RunningStream.mbps` = per-60 × fps / 60 [src]);
    the helper target must be scaled accordingly. *Prevents:* M5
    applying the catalog's 12 Mbps at the wrong scale and latency
    spikes from unbounded IDR sizes.

12. **Debounce pipeline teardown.** Phase 0 recorded that the client
    opens "one short-lived session immediately replaced by the real one
    at connect time" [doc]. Starting the VA pipeline on the first
    selectSource and stopping it when that session closes wastes a
    start/stop per connect and can race the second session's start.
    Keep the pipeline alive for N s (e.g. 5) after the last watcher
    leaves. *Prevents:* connect-time flapping and slow first picture.

13. **Specify behaviour for `selectSource` ≠ `.desktop` and for
    pipeline failure.** `.none` and `.window(id)` will arrive (the
    client decides [src]). Specify: `.none` stops sending video to
    that session and re-sends WindowList with `active: .none`;
    `.window` is answered as `.desktop` (or `.none`) consistently.
    If the helper cannot start (no DISPLAY/XAUTHORITY, VA init fails)
    or dies repeatedly, restart with backoff, and after N failures
    send `Goodbye` (kind 22) with a human message rather than an
    indefinite black panel. Populate `HostSettingsState.stream`
    (`RunningStream`) once the pipeline runs — it is `nil` today [src]
    and is "what actually runs" per the contract [src].

14. **Validate every client message the phase starts acting on.** Apply
    `ViewportBounds.refusal` to kind 9 and hold `fps` to 24…maxFPS
    (upstream rule in `Viewport.swift` [src]); clamp input fractions to
    [0,1]; range-check `hidUsage`; accept `changeSettings` only for
    `SettingsChoices` values and answer with `answering: token` [src].
    *Prevents:* the upstream finding-4 class of trap (huge numbers
    reaching Int conversions) re-appearing in new code.

---

## 3. Security check

| # | Finding | Rating |
|---|---|---|
| S1 | **Pairing now grants full keyboard/mouse control of the X session**, including typing into the screen locker (a paired device can unlock the desktop by typing the password, as upstream does for a locked Mac [src: `LockedMac.detail`]). The plan should say this explicitly: a pin is equivalent to the logged-in user's session, and the pin store must be protected as such (it is in the user config dir; ensure `0600`/`0700` on `paired.json` and its dir). | should-fix |
| S2 | **No live revocation.** Pins are checked only at the TLS gate (`pins.isPinned` in `userInboundEventTriggered` [src]); `PinStore.remove` has no callers and no way to close an existing session [src]. Phase 0 unpaired by restarting the daemon [doc], which closed everything. Once sessions inject input, any future unpair path (CLI, file watch) must close that fingerprint's live sessions and release its held input (R7). Add the hook now so it isn't forgotten. | should-fix |
| S3 | **Input helper boundary.** Required changes 8 and 9 (non-blocking, bounded, unambiguous framing). In addition, the helper must re-validate (defense in depth): fractions in [0,1], keycodes within the X server's min/max keycode, text length cap per command, and a per-second event cap. Cap text: a 1 MiB kind 8 [src] typed via keymap remapping would occupy the helper (and the user's keyboard map) for minutes. | must-fix (8, 9); should-fix (rest) |
| S4 | **Keep the network-facing daemon off the X server.** Decision 6 has the daemon take DISPLAY from its environment. State that the daemon never opens an X connection itself — only helpers do — so a parsing bug in the TLS-facing process cannot directly keylog or inject. Pass DISPLAY/XAUTHORITY only to the helpers' environment. | should-fix |
| S5 | **Helper spawning.** Spawn helpers by absolute path (next to the daemon's executable), never by PATH lookup; give them a minimal environment (DISPLAY, XAUTHORITY, and only the GST_/LIBVA_ variables you mean to pass). Helpers should `prctl(PR_SET_PDEATHSIG, SIGTERM)` and exit on stdin EOF: today's SIGTERM handler calls `exit(0)` after only terminating avahi [src], which would orphan both helpers (an orphaned input helper with held keys is the bad case). | should-fix |
| S6 | **Media pipe is a parser too.** The daemon must validate the helper's frame headers: known type byte, length ≤ `StreamMessage.maxFramePayload` (32 MiB [src]), sane timestamp; on any violation, kill and restart the helper rather than allocate. A GStreamer bug or plugin crash should not OOM the daemon. | should-fix |
| S7 | **Log injection.** `Hello.device` is logged raw today [src] although the contract says "the host cleans it (SafeText.label)" [src]; Phase 1 adds `ClientStats.device` at 1 Hz. Pass both through `SafeText.label` before logging. | should-fix |
| S8 | **Listener scope.** The daemon binds `0.0.0.0` [src] and the phase is "LAN only" by intent. With input injection live, a host on an untrusted network (or with a public interface) exposes the pairing door everywhere. Either bind to LAN interfaces or document a firewall rule; at minimum, log the interfaces it listens on. | note |
| S9 | **Keymap remapping is global state.** The text "temporary-remap" trick changes the server-wide keyboard map; a helper crash mid-remap leaves a spare keycode remapped. Restore on startup (reset the scratch keycode(s) to NoSymbol) and on exit. | should-fix |
| S10 | **keyframeRequest as an amplifier.** A single paired client sending kind 44 at its permitted rate forces IDRs on the shared encoder for everyone (R10). Global coalescing bounds it. | should-fix (covered by R10) |

---

## 4. Performance check

| # | Finding | Rating |
|---|---|---|
| P1 | **Seat-display capture rate unverified; 25 fps possibly a caps default, not the display** (R4). Highest-risk item in the phase. | must-fix |
| P2 | **1 s GOP is costly at this resolution and is the wrong recovery mechanism.** At 12 Mbps / 60 fps the average frame is ~25 KB; a 2266×1488 IDR is typically an order of magnitude larger [fp]. An IDR every second creates a periodic bitrate spike (latency jitter on Wi-Fi) and periodic quality "breathing" under CBR. Upstream's own comment that "a still window never sends [a keyframe] by itself" [src: kind 44] suggests a long or infinite GOP with keyframes on demand. Recommend: long GOP (e.g. 5–10 s or infinite) + forced IDR on join, on kind 44, and when any session enters the dropping state (coalesced). Then drop recovery is bounded by one RTT plus an encode, not by the GOP. | should-fix |
| P3 | **Drop-policy convergence.** After "drop until next keyframe", the next thing sent is the largest frame of the GOP. If the per-session byte bound is smaller than ~2 IDRs, a marginal link re-enters dropping on the IDR itself and never converges. Size the high-water mark in bytes ≥ 2× a measured IDR (measure in M1 from recorded output), and log enter/leave-dropping per session with counts so M4 can show convergence. | should-fix |
| P4 | **CPU colour conversion at 2266×1488×60.** That is ~202 Mpixel/s; single-threaded `videoconvert` BGRx→NV12 on Alder Lake-N cores is unlikely to keep up [fp — unmeasured]. Make `vapostproc` (GPU) the primary path and `videoconvert n-threads=N` the fallback, measured in P1-M0. | should-fix |
| P5 | **Memory bandwidth.** XShmGetImage copies 13.5 MB per frame — ~810 MB/s at 60 fps (Phase 0 saw ~340 MB/s at 25 fps [doc]), plus the conversion read and VA upload. Feasible on paper, but on a likely single-channel memory system it competes with the desktop itself. Record total system CPU and fps with a busy desktop (browser scrolling video) in P1-M0, not just an idle one. `use-damage=true` would cut copies but was not the measured configuration. | note |
| P6 | **Pipeline latency settings unspecified.** Specify: a `queue leaky=downstream max-size-buffers=1` before the encoder (drop *raw* frames when encode lags — harmless — and never drop encoded AUs in the helper), `appsink sync=false` (or fdsink), no `h265parse` reordering latency (`alignment=au` straight from the encoder). Raise the stdout pipe buffer (`F_SETPIPE_SZ`, ~1 MiB) so a 300 KB IDR is not 5+ read wakeups. | should-fix |
| P7 | **Timestamp honesty.** `ClientStats.frameAgeMs` is defined as "host encode timestamp → received on the device (clocks assumed synced)" [src]; the plan stamps *capture* time from buffer PTS + a start wall-clock (Decision 7). Capture time is the more honest choice, but say so in the plan and log, because frameAge will then include capture+convert+encode. "PTS + start wall-clock" drifts from CLOCK_REALTIME if NTP slews or steps during a long stream; re-anchor periodically or sample `clock_gettime(CLOCK_REALTIME)` at capture. The host must be NTP-synced (verify `timedatectl` in M4), or frameAge is meaningless. Have the helper log its own capture→AU-out latency per second so the budget can be decomposed. | should-fix |
| P8 | **No latency budget.** Add numeric targets so M4 can pass/fail: e.g. capture→AU-out ≤ 20 ms p50, frameAge p50 ≤ 50 ms / max ≤ 120 ms on the LAN, sustained client fps ≥ 58 at 60. (Targets are a proposal [fp]; the point is to have them.) | should-fix |
| P9 | **Fan-out copies.** Build each kind 0/1 message once as a `ByteBuffer` and write the same buffer to every session (NIO buffers share storage). Today's `send` serializes the `StreamMessage` twice (once to size the buffer, once to write) [src] — fine for the catalog, wasteful per frame. | should-fix |
| P10 | **Single event-loop thread.** TLS encryption for all sessions, pipe reads and input forwarding share one thread [src]. At 12 Mbps × a few clients this is fine [fp], but it is why R8 (no blocking writes) is mandatory. | note |
| P11 | **Live fps retune is not a property write.** `Viewport.fps` says upstream "restarts the pipeline when that changes" [src]. In GStreamer, changing the capture rate means changing caps (capsfilter/`videorate`) and renegotiation, not an encoder property [fp]; `bitrate` on the VA encoders may be mutable in PLAYING but must be verified. M5 should say "bitrate: live property if mutable, else restart; fps: pipeline restart (with keyframe and fresh sets)", and treat avoiding restarts as an optimisation. | should-fix |
| P12 | **Keymap remapping cost.** Each `XChangeKeyboardMapping` broadcasts MappingNotify to every X client, which refetches the keymap [fp]. Without `WindowList.keyRepeat` (nil today [src]), the client sends hardware-keyboard characters as `.text` (Switcher.swift's `keyRepeat` comment [src]) — so remapping would be the *main* typing path. Use a fast path: look up the char's keysym in the current map (with Shift level) and only remap for characters absent from the layout. | should-fix |

---

## 5. Optional improvements

- Send one static `cursorShape` (kind 14, a default arrow) on
  selectSource. `CursorShapeBlob` is 16 bytes + a PNG [src]; it may be
  the difference between "no pointer at all" and "an arrow" for
  trackpad/mouse users on the iPad (see A4), at near-zero cost.
- Consider `h265parse ! video/x-h265,stream-format=hvc1,alignment=au`:
  NALs are already length-prefixed and the sets arrive in `codec_data`
  (hvcC), which shrinks the converter to an hvcC parser. The Annex B
  route is fine too; pick one and test it with recorded output (M1).
- Strip AUD (type 35) and filler NALs in the converter; keep SEI only
  if a test shows the client needs it.
- Advertise `keyRepeat = 1` (Switcher.swift's KeyRepeat [src]) once
  key injection is solid: hardware keys then arrive as `.key` events,
  repeat is the X server's, and the remap path is reserved for the
  software keyboard. Depends on R7.
- Map scroll deltas with an accumulator (fraction × rect height /
  pixels-per-notch → integer wheel clicks, buttons 4/5 and 6/7,
  natural-scroll sign per `Input.swift` [src]). Drop the
  "virtual smooth-scroll" idea for scrollGesture: XTest cannot emit
  XI2 smooth-scroll valuators [fp]; uinput can, later.
- Decide and document what UIKeyModifierFlags Command maps to
  (Super vs Control); on a Linux desktop, Control is usually what an
  iPad user expects for ⌘C/⌘V.
- Record M1's captured AUs as fixtures in `Tests/` so the converter
  stays tested against real `vah265lpenc` output.

---

## 6. Assumptions to verify empirically (genuine client 0.6.2)

| # | Assumption in the plan (or implied by it) | How to check |
|---|---|---|
| A1 | The client decodes AUs whose pictures `vah265lpenc` labels "B" (low-delay B, zero reordering [doc]) in its display layer, not just in Safari's MP4 player [doc]. The live path (VideoToolbox sample buffers from kind 0/1) is not the same as MP4 playback. | M2 first picture. |
| A2 | Forced keyframes from `vah265lpenc` are IDR (not CRA) and honoured promptly via a force-key-unit event; the client's keyframe gate accepts what arrives. | Helper test in M1: send KEYFRAME, check NAL types of the next AU. |
| A3 | Kind 0 is expected with `isKeyframe = 1` and only when sets change; the client tolerates kind 0 re-sent before every IDR (the safe variant of R3). | M2/M4. |
| A4 | The client draws its own pointer with **no** kind 14 ever received. `Viewport.localCursor` says "the client draws its own pointer… streams its shape separately" [src]; whether it draws a default without a shape is not stated. | M3, with a trackpad/mouse attached to the iPad. |
| A5 | Which keyboard input arrives as `.key` vs `.text` with `keyRepeat` nil: Switcher.swift implies hardware characters come as `.text` [src]; arrows, Escape, ⌘-shortcuts presumably as `.key`. Also whether modifiers arrive as their own 0xE0–0xE7 key events, as flags only, or both (risk of double-press). | Log raw kind 8 in M3 before injecting anything. |
| A6 | The client's reaction to dropped AUs mid-GOP (the plan already lists this as open) — specifically whether it sends kind 44 on corruption it detects itself or only on display-layer failure [src: "its display layer failed, or iOS stopped it"]. If only the latter, host-side IDR on enter-dropping (P2) is needed. | M4, by deliberately throttling one session. |
| A7 | The header timestamp is used only for stats, not for presentation scheduling. If the client paces display by it, host clock skew or the capture-vs-encode choice (P7) changes latency, not just the reported number. | M4: skew the host clock by +200 ms and watch whether frames are delayed or only frameAge changes. |
| A8 | The client displays the HEVC conformance-window crop (2266 wide), not the coded size (CTU-padded, e.g. 2272) — otherwise input fractions are off and a padding strip shows. | M1 ffprobe of recorded stream (coded vs display width); M3 click at the far right edge. |
| A9 | The client sends selectSource on every session even though the catalog already says `active: .desktop` (Phase 0's catalog [src]); the plan lists selectSource as observed, but confirm it arrives for the *second* (real) session of the connect pair [doc], since the pipeline start hangs on it. | M2 logs. |
| A10 | `Viewport.fps` from the iPad Air is 60 (non-ProMotion) or nil; the clamp 24…maxFPS holds. | M5 logs. |
| A11 | 60 fps capture on the seat display (R4/P1) — the only unmeasured media prerequisite. | P1-M0. |
