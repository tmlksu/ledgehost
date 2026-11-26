# Phase 1 plan — review (Fable)

Reviewed: `docs/phase-1-plan.md` (draft, 2026-11-26), against
`docs/phase-0-plan.md`, `docs/phase-minus-1-report.md`,
`Vendor/StreamProtocol/{StreamMessage,Input,Viewport,Switcher,HostSettings,Pointer,Compatibility,Remote}.swift`,
and `Sources/ledgehostd/main.swift`.

## 1. Verdict

**Proceed with changes** — the architecture and milestone order are sound and
evidence-based, but the plan states at least one design fact that is wrong
(the `usage + 8` keycode claim) and leaves every new IPC contract (the media
pipe, the input pipe, changeSettings semantics) under-specified in ways that
implementation would either get wrong or have to rediscover.

## 2. Required changes

Each item names the failure it prevents.

1. **Replace the `keycode = usage + 8` claim with a real HID→X table.**
   `usage + 8` is the *evdev→X* rule (X keycode = evdev code + 8); evdev codes
   are not HID usages. HID usage 0x04 ('a') → X keycode 12 → evdev 4 → KEY_3:
   the plan as written types "3" for nearly every letter. M3's acceptance test
   (type into an editor) would catch this, but the table — letters, digits,
   arrows/nav cluster, function keys, keypad, media keys, and the modifier
   usages themselves — is design work that belongs in the plan now, not a bug
   found on device. Prevents: M3 shipping an input path that produces wrong
   keys for essentially every key (`phase-1-plan.md` decision 8).

2. **Fully specify the daemon↔media framed protocol.** The diagram says
   "P (sets) / F (AU)" but the record must also carry the capture timestamp
   and the isKeyframe flag the wire header needs (decision 7 requires the
   helper, not the daemon, to know capture wall-clock). Specify: magic +
   version, tag, timestamp (Double), flags, length, a hard length cap
   (≤ `maxFramePayload` 32 MiB, `StreamMessage.swift:123`), and
   *stdout purity* — nothing but framed records may ever reach stdout:
   GStreamer logging belongs on stderr, and the spawned environment must be
   sanitized (`GST_DEBUG`, `GST_PLUGIN_*` unset). A single stray log byte
   permanently desyncs the framer. Prevents: silent stream corruption and a
   bus that can never resynchronize.

3. **The input helper protocol cannot be a raw "line protocol".**
   `InputEvent.text` delivers literal `"\n"`, `"\t"` and `"\u{8}"`
   (`Input.swift:22-24`); a newline-delimited protocol cannot carry them
   unescaped, and an ad-hoc escape scheme invites parse ambiguities. Specify
   length-prefixed or field-escaped records with a strict parser that rejects
   unknown ops. Prevents: protocol desync and lost/transformed typed text.

4. **Specify the modifier state machine.** `InputEvent.key` carries a
   `modifiers` bitmask (`Input.swift:34`); the plan's HID→keycode mapping
   says nothing about how `key(c, down, modifiers: command)` becomes
   Cmd-down → c → Cmd-up. The daemon must diff the modifier bitmask per
   event into synthetic press/release events and track held state. Whether
   the genuine client also sends modifier keys as their own `.key` events is
   unverified (§6), but either way the bitmask path must exist. Prevents:
   every keyboard shortcut silently dropped.

5. **Release all held input state on session loss.** If the connection
   drops mid-drag or mid-keydown, the host desktop keeps a pressed mouse
   button or key forever. The daemon must track per-session held
   buttons/keys/modifiers and emit release events (or a single
   "release all" command to the helper) on `channelInactive`. Prevents:
   stuck drags and phantom key-downs on the host desktop.

6. **Specify pipeline lifecycle, not just startup.** The plan covers
   `selectSource(.desktop)` starting the pipeline but never its stop: no
   watchers (all sessions deselected `.none` or disconnected) must stop the
   encoder, and both helpers must self-terminate on stdin EOF/stdout EPIPE
   so a daemon crash leaves no orphaned GStreamer or XTest process. The
   daemon's own signal path (main.swift:279-284) must reap children.
   Prevents: a headless encoder capturing and burning CPU indefinitely, and
   orphaned helpers holding the display.

7. **Implement changeSettings per the contract, not "re-sends kind 16".**
   `HostSettings.swift:181-184, 241-242`: the reply to a `HostSettingsChange`
   is a kind 16 sent *to that device alone* with `answering` set to the
   change's `token`, after validating each field against `SettingsChoices`
   (maxFPS ∈ {60,120}, bitrate ∈ QualityPreset values, captureScale ∈ {1,2}).
   The daemon also advertises `captureScale`, `prioritizeSpeed` and
   `virtualDisplay` as non-nil (main.swift:207-208), so the client may send
   changes for them; M5 covers only bitrate/fps. Define the per-field policy
   (apply, clamp, or hold-and-answer) and populate `stream`
   (`RunningStream`) once the pipeline runs. Prevents: the client showing a
   control it changed springing back with no explanation, and a protocol
   violation the genuine client's settings ledger will read as a refusal.

8. **Quantify the backpressure contract.** "Bounded per-session queue" needs
   numbers: a bound in AUs or bytes small enough that a healthy session adds
   <1 frame of latency, a watermark that enters drop-until-keyframe mode,
   and — on entering that mode — a *host-initiated* force-IDR rather than
   waiting for the client's keyframeRequest, which upstream's
   KeyframeRecovery only resends after 4 s of missing keyframes
   (`StreamMessage.swift:91-93`). Also enforce the upstream rate cap
   (≤1 keyframeRequest honoured per connection per second) and coalesce
   forced IDRs globally. Prevents: multi-second freezes on the first TCP
   stall and an encoder keyframe storm under join/request bursts.

9. **Keep the media pipe off the session event loop.** ledgehostd runs a
   single-threaded `MultiThreadedEventLoopGroup` (main.swift:236); a blocking
   read of the helper's stdout on that loop stalls every TLS session —
   including a pairing exchange and the pong path that feeds the client's
   RTT/liveness measurements. Specify a dedicated reader thread or a NIO
   pipe channel that drains the pipe unconditionally (the bus drops, the
   pipe never backs up), with channel writes marshalled back onto each
   channel's event loop. Prevents: a media stall taking the whole daemon's
   responsiveness with it.

10. **Clamp and rate-limit at the input-mapping layer.** Input x/y fractions
    are `0…1` "by convention" (`Input.swift:3-5`) but arrive as Doubles;
    upstream itself was killed by a `1e300` reaching a size conversion
    (`Viewport.swift:32-36`). Clamp fractions to [0,1], cap `text` event
    length, accumulate scroll deltas so sub-click fractions aren't dropped
    and large ones emit multiple wheel clicks, and coalesce consecutive
    `pointer(move)` events to the latest — hover move floods are the input
    path's equivalent of the frame queue. Prevents: coordinate overflow into
    XTest, a multi-megabyte text event typing for minutes, and move-event
    queue lag.

11. **Name the ximagesrc properties decision 5 depends on.** ximagesrc's
    `show-pointer` defaults to true — "the cursor stays OUT of the video" is
    not the default behaviour; the plan must say `show-pointer=false` (and
    pin `use-damage` and the source-side `framerate` while it's there).
    Prevents: decision 5 silently violated on first bring-up, with the host
    cursor burned into every frame the client also draws its pointer over.

## 3. Security check

The trust model is sound and unchanged from Phase 0: only a pinned device
speaks past the gate, and input injection is exactly the feature being built.
Findings are about the new surface Phase 1 adds.

1. **must-fix — IPC integrity on both helper pipes.** Any byte on the media
   helper's stdout that isn't a framed record (GStreamer diagnostic, a
   plugin warning) desyncs the video feed permanently; any malformed line on
   the input pipe could inject unintended XTest ops. Stdout purity +
   env sanitization (required change 2), strict rejection of malformed
   records (3), and treating a bad media header as fatal for that helper.
2. **must-fix — held-input release on session loss** (required change 5).
   Stuck keys are a correctness bug; a stuck modifier or button on the
   user's real desktop is a security-relevant one (e.g., a held Shift or a
   dragged window the user can't drop).
3. **must-fix — input value clamping** (required change 10). Untrusted JSON
   reaches XTest; upstream's own postmortem shows the value class that
   kills.
4. **should-fix — gate injection on stream state.** Only inject input from a
   session that has selected the desktop, and define arbitration if two
   pinned devices are connected (upstream shares one source; a second
   device's keystrokes shouldn't land blind on a desktop it isn't watching).
5. **should-fix — lock/blank-screen policy.** The plan never says what
   happens when the seat session is locked or DPMS-blanked: injected
   keystrokes land in the unlock dialog (upstream deliberately permits
   typing the password for paired sessions — `Switcher.swift:201-207` — but
   also marks `WindowList.locked` so the client understands what it sees).
   Minimum: document the behaviour; better: detect XScreenSaver state and
   set `locked` in the list. Also confirm what ximagesrc captures while the
   screen is blanked (§6).
6. **should-fix — helper spawn hygiene.** Spawn helpers by absolute path
   (no PATH lookup), with a fixed argument list and sanitized environment
   carrying only what they need (DISPLAY, XAUTHORITY, plus a clean GST env).
   Helpers must exit on stdin EOF — a daemon killed -9 must not leave a
   capturing pipeline running.
7. **note — logging.** Extend Phase 0's "never log secrets" rule: typed
   `text` payloads and key events must never hit the journal — the daemon
   would otherwise be a keystroke logger on its own input path.
8. **note — daemon user.** Helpers inherit the daemon's X authority; the
   daemon must run as the session user, never root — as root, XTest still
   injects and capture still reads the screen, and the only thing gained is
   blast radius.
9. **note — pairing assumptions unchanged.** Nothing in Phase 1 weakens the
   pin model; the 1 MiB client payload cap already enforced in `drain()`
   (main.swift:138) bounds every new inbound kind. A crafted
   `selectSource(.window(id))` (no windows are ever listed) must be refused
   gracefully rather than trapped.

## 4. Performance check

The measured foundations hold: ~90 fps encoder headroom, zero reordering,
~340 MB/s capture path at 3% CPU (phase-0-plan.md, 0-A results). The risks
are in what the plan adds around them.

1. **must-fix — blocking pipe reads on the single event loop** (required
   change 9). This is the one architectural point that can break every
   session at once.
2. **should-fix — unquantified queue bound** (required change 8). Too deep a
   bound accumulates latency before drops begin; the "until next keyframe"
   rule needs the host-side IDR trigger or recovery is bounded by the
   client's 4 s KeyframeRecovery timer, not the 1 s GOP.
3. **should-fix — the "1 s GOP" is asserted, not specified.** Decision 4
   leans on it but the plan never says `key-int-max`/keyframe period must be
   set to `fps`. Specify it, and specify `config-interval` handling for
   parameter sets: whether VPS/SPS/PPS repeat per IDR or appear once, the
   daemon must seed its kind 0 cache from the first AU and re-send kind 0 on
   byte-level change — "whenever the sets change" is already the contract
   (`phase-1-plan.md` wire section); make the dedup rule explicit.
4. **should-fix — fps retune probably can't be a property write.** M5 claims
   "property writes, no pipeline restart"; a framerate change is a caps
   renegotiation through ximagesrc, and upstream's own rule is that the
   pipeline *restarts* when the max wanted fps changes (`Viewport.swift:20-22`).
   Allow a restart for rate changes (clients tolerate it: cached param sets
   + forced IDR on resume) and keep live property writes for bitrate only.
5. **note — timestamp honesty is the safe direction.** Stamping capture
   time (decision 7) rather than encode completion inflates `frameAgeMs`
   by ~encode latency (~10 ms) — it over-reports age, never hides it.
   Watch PTS→wall-clock mapping at pipeline start (preroll jitter lands in
   every frame's age).
6. **note — videoconvert cost is correctly flagged**, with vapostproc as
   the fallback; also worth one line: vah265lpenc may accept BGRA-adjacent
   formats that skip conversion entirely — check `gst-inspect` caps before
   assuming the convert step is needed.
7. **note — bitrate semantics.** `StreamSettings.bitrate` is *per 60 fps*;
   a 120 fps stream gets twice the bits (`HostSettings.swift:67-68`). If M5
   ever honours a higher wanted fps, the encoder target must scale with it.
8. **note — the tick already exists** (10 s, main.swift:180-183), keeping
   the device radio out of power save; nothing needed there.

## 5. Optional improvements

- Populate `HostSettingsState.stream` (`RunningStream`) once the pipeline
  runs, and consider `link` (`LinkReport` "behind"/"stalled",
  `HostSettings.swift:147-157`) while a session is in drop mode — it's the
  upstream-native way to tell the device its link can't keep up.
- Send `goodbye` (kind 22) before host-initiated session closes — the wire's
  compatibility rule is that a reason is always sent (`Compatibility.swift:11-12`).
- Give M4 an explicit second-client case: mid-stream join gets cached kind 0
  + forced IDR, and two sessions' queues drop independently.
- Give M4 an end-to-end latency criterion (e.g., median `frameAgeMs` under a
  threshold on the LAN), not just "ClientStats logged" — the numbers exist;
  a bar for them makes regression visible.
- Probe "record" mode (M1): also record header flags/timestamps so
  reassembly can check isKeyframe marking and monotonic timestamps, not just
  decode success.
- Helper restart policy: on a media-helper crash, mark sessions' picture
  dead, respawn, and let join-recovery do its job — worth one sentence in the
  plan even if implementation is "log and exit the pipeline".

## 6. Assumptions to verify empirically

Claims about the genuine client (or the target machine) the plan asserts but
has not tested:

1. The client draws a usable pointer with **no** kind 14 (cursor shape) and
   no kind 26 (host pointer position) ever sent — the plan flags this
   itself; `Viewport.localCursor` exists but upstream always keeps the Mac
   cursor out and streams the shape (`Viewport.swift:15-17`). What the
   client shows when it receives neither is unmeasured.
2. Mid-GOP drop behaviour (plan's own risk list): freeze, artefacts, or
   immediate keyframeRequest — to be observed in M4.
3. The seat display's capture path: Phase 0 measured only a 25 Hz-capped
   dummy remote display; capture fps and XAUTHORITY access on the real seat
   session are still unproven (phase-0-plan.md:233-235). M2 is where this is
   decided.
4. vah265lpenc specifics the design depends on: FORCE_KEY_UNIT forcing an
   IDR on demand, live `bitrate` property changes taking effect mid-stream,
   and where VPS/SPS/PPS actually land under the chosen `config-interval`.
5. Client `.key` semantics: whether it sends modifier presses as their own
   key events, relies on the `modifiers` bitmask, or both; and which events
   it sends at all when `WindowList.keyRepeat` is nil (it should type
   characters via `.text` — `Switcher.swift:63-69` — but arrows/shortcuts
   are unverified).
6. Whether the client sends `selectSource(.none)` on backgrounding or panel
   close — determines whether the pipeline ever gets an explicit "stop
   watching" signal or must infer it from disconnects.
7. Client behaviour when the host streams below the wanted fps in the
   viewport (kind 9) — tolerated quietly, or triggers requests the plan
   doesn't model.
8. Client tolerance for non-parameter-set NALs (AUD, SEI) left in kind 1
   AUs — the converter keeps them; upstream asserts only that parameter
   sets are excluded.
9. What the client displays while the host streams a locked or blanked
   screen — interacts with security finding 5.
10. Whether a second simultaneous session is even reachable with the genuine
    client (the broadcast/drop machinery is designed for it; the observed
    client so far has been a single iPad making one short-lived + one real
    session per connect — phase-0-plan.md:246-247).
