# Phase 1 plan review — SWE-2 (design review, read-only)

Reviewed against: `docs/phase-1-plan.md`, `docs/phase-0-plan.md`,
`docs/phase-minus-1-report.md`, `Vendor/StreamProtocol/` (v0.6.2),
`Sources/ledgehostd/`.

## 1. Verdict

**Proceed with changes** — the architecture (out-of-process helpers,
one broadcast pipeline, drop-to-keyframe queues) is sound and grounded
in measured numbers, but the plan is wrong on two wire-contract details
it states as facts (the HID→keycode mapping, "retunes live, no
restart") and silent on several behaviours the genuine client already
enforces (changeSettings answering/whitelist, viewport bounds,
keyframeRequest rate limits, input-modifier delivery).

## 2. Required changes

Each names the failure it prevents.

1. **Fix the keyboard mapping.** Decision 8's "keycode = usage + 8" is
   wrong as stated. On the wire are USB HID usages
   (`Input.swift:32`, `UIKeyboardHIDUsage.rawValue`). X11 keycodes under
   evdev are `evdev code + 8`, and the HID-usage→evdev-code map is a
   table, not an offset: HID 'a' (0x04) → evdev KEY_A (30) → X keycode
   38; `usage + 8` = 12 → '3'. Return, Escape, all letters and all
   modifiers (0xE0–0xE7 → KEY_LEFTCTRL 29 … KEY_RIGHTMETA 126) are
   non-linear too. Required: a HID usage → evdev → X-keycode table
   (the kernel's `hid_keyboard` table, or remap-by-keysym like the
   text path). *Prevents: every typed key producing a different
   character — worse than failing M3, it silently injects wrong
   keystrokes into the user's real session.*

2. **Define how `.key`'s `modifiers` field is applied.** The plan
   never mentions it. It carries UIKeyModifierFlags bits at
   CGEventFlags positions (`Input.swift:33-34`): shift 1<<17, control
   1<<18, alt 1<<19, command 1<<20. If the client does not also send
   separate modifier-down `.key` events (unverified — our WindowList
   has no `keyRepeat`, so the client's KeyTyping is in its older
   mode, `Switcher.swift:63-70`), a Ctrl+C arrives only as
   `.key('c', modifiers: control)`. Required: press/release real
   modifier keycodes from the bitmask around such events, or verify in
   M3 that the client sends modifier events and document that.
   *Prevents: modified shortcuts delivered unmodified, or modifier
   state desync between client and X session.*

3. **Specify both pipe protocols on paper.** The media helper's
   framing must carry per-record: type (sets / AU), keyframe flag,
   capture timestamp (the header's Double seconds), length — and the
   daemon must cap AUs at `maxFramePayload` (32 MiB,
   `StreamMessage.swift:123`) and require helper logs on stderr only.
   The input helper must not get a "line protocol" for text: `.text`
   carries arbitrary Unicode including control characters, so a
   newline in typed text terminates the line early and the remainder
   becomes a new command. Required: length-prefixed or
   escaped/encoded records, a max record size. Also state the Annex B
   flavour the helper emits: `byte-stream` means the daemon still
   scans for start codes inside each AU buffer (fine, but say so —
   the plan's "never scans a raw byte stream" is misleading);
   `stream-format=hev1,alignment=au` puts NALs already
   length-prefixed with sets in `codec_data`. *Prevents: framing
   ambiguity corrupting the AU stream, and command injection through
   typed text into the input helper.*

4. **Cover `selectSource`'s other cases and pipeline lifecycle.**
   `StreamSource` is `none | window(id) | desktop`
   (`Switcher.swift:4-8`). The plan handles only `.desktop`. Required:
   define per-session subscription state — `.desktop` subscribes,
   `.none` unsubscribes (the client sends it when leaving the
   stream), `.window` is logged-and-ignored with the list's `active`
   re-asserted. Also state when the pipeline stops: encoding 60 fps of
   a desktop nobody watches burns the GPU indefinitely. Upstream's
   model is one pipeline; the start/stop trigger is the count of
   subscribed sessions. *Prevents: sessions that unsubscribed still
   receiving frames (or the reverse), and a permanently-running
   encoder on an idle host.*

5. **Rate-limit and coalesce keyframe paths.** The wire comment puts
   the host-side limit at "at most one a second per connection"
   (`StreamMessage.swift:87-93`); the plan only says "keyframeRequest
   forces an IDR". Required: per-connection limit, coalescing of
   concurrent requests/joins into one forced keyframe, and a host-
   initiated IDR when a session enters drop-recovery rather than
   waiting for the client's request (the drop is host-side; the
   client round-trip is avoidable latency). *Prevents: one paired
   client forcing an IDR per frame — a bitrate storm broadcast to
   every session — and slow recovery from host-side drops.*

6. **Make the backpressure contract concrete.** "Bounded queue,
   drop until next keyframe" needs: the bound's unit (bytes and AUs —
   a keyframe can be ~1 MiB, so count bytes), the "behind" signal
   (queue occupancy and/or NIO `isWritable`), that kind 0 parameter
   sets are never dropped (they're tiny and the next keyframe depends
   on them), and that a re-joining session gets the cached sets
   re-sent before its first keyframe. *Prevents: unbounded pending
   writes growing memory and latency, and a session rejoining on a
   keyframe described by parameter sets it never received.*

7. **Implement changeSettings per the contract, not per the plan's
   sketch.** `HostSettingsChange` rules the plan skips: the host
   answers every decodable change with a kind 16 to *that device
   alone*, carrying `answering` = the change's `token`
   (`HostSettings.swift:239-242`); values are whitelisted against
   `SettingsChoices` — maxFPS {60,120}, bitrate {4M,8M,15M,25M,40M},
   captureScale {1,2} (`HostSettings.swift:297-311`) — and the state
   re-sent on change should populate `stream` (`RunningStream`) once
   streaming. Fields we don't implement (virtualDisplay,
   prioritizeSpeed, directWireless, sendAudio) must keep their
   advertised values in the answer — upstream explicitly names the
   silent-drop as the failure mode (`HostSettings.swift:26-28`). Also:
   the catalog advertises `bitrate: 12_000_000`, a non-preset value a
   device can only show read-only as "Custom" — either keep it
   deliberately or advertise a preset; and `persistent: true` in the
   current catalog (`main.swift:207`) is a lie unless M5 actually
   persists changes — set it false otherwise. *Prevents: settings
   toggles that silently revert with no refusal and no log, and
   unanswered tokens the device waits on.*

8. **Validate viewport and apply the fps/bitrate semantics.** kind 9
   must go through `ViewportBounds.refusal` — upstream documents a
   real host-killing bug where unvalidated viewport doubles reached an
   `Int()` and took down every session (`Viewport.swift:32-37`).
   `wantedFPS` is clamped 24 to the host's limit, and `nil` means 60
   (`Viewport.swift:40-42`); running fps is the max across sessions.
   `settings.bitrate` is **per-60-fps**: the encoder target is
   `bitrate × runningFps / 60` (`HostSettings.swift:67-68`, confirmed
   by `RunningStream.mbps` at line 106-107). The plan's "runs at the
   catalog's bitrate and the client's wanted fps" omits the scaling.
   *Prevents: a crash vector the upstream already burned once, and a
   2× bitrate error at 120 fps.*

9. **Release all injected state on disconnect.** The input helper (or
   the daemon's bookkeeping) must track pressed keys/buttons and
   release them when the injecting session ends, the helper exits, or
   the daemon shuts down. *Prevents: a stuck Shift/Ctrl/pressed mouse
   button left on the user's real session after a client drops
   mid-gesture — invisible locally, effectively a hung input device.*

10. **Clamp and cap input before it reaches XTest.** Clamp x,y to
    [0,1] of the streamed rectangle (out-of-range fractions currently
    map onto *other monitors* or negative coordinates via XTest);
    bound |dx|,|dy|; cap `.text` length and event rate (the 1 MiB
    `maxClientPayload` cap allows a legal ~1 MiB text event that would
    occupy the helper remap-typing for minutes); drop unknown HID
    usages. Handle `.text`'s special cases: `"\n"`, `"\t"`, `"\u{8}"`
    are delivered as the matching *keys*, not remap-typed
    (`Input.swift:22-24`). *Prevents: clicks landing off the captured
    display, scroll storms, and an input queue a single message can
    monopolise.*

11. **Handle helper death.** Reap children; on media-helper EOF/crash,
    mark the stream dead and tell sessions — ideally kind 22
    `goodbye` with `reconnect:true`, at minimum a clean close rather
    than a frozen picture and keyframeRequests into the void; decide a
    respawn policy. *Prevents: zombie processes and clients frozen on
    the last frame with no error surface.*

## 3. Security check

- **[must-fix] Input protocol framing.** `.text` is arbitrary Unicode;
  a line protocol lets one typed newline inject extra helper commands
  (see change 3). Same class as classic injection; our own pipe, but
  trivially avoided now.
- **[must-fix] Stuck-input cleanup.** Change 9 — a disconnected client
  must not leave the seat session with held modifiers or buttons.
- **[should-fix] Input clamping.** Paired devices are trusted, but a
  malformed fraction is a footgun any client version could produce;
  clamp at the daemon before mapping to pixels (change 10).
- **[should-fix] keyframeRequest / IDR rate limit.** Per-connection
  1/s plus coalescing (change 5). A paired client is trusted but a
  buggy one shouldn't be able to force bitrate spikes for all sessions.
- **[should-fix] Cap client→host work.** 1 MiB kind 8 payloads are
  legal (`maxClientPayload`); cap text length and events-per-second at
  the input layer (change 10). The media helper's frames: bound to
  `maxFramePayload` when parsing its stdout (change 3).
- **[note] Injection is the product.** Any paired device can type into
  terminals on the real session — that is the feature, and pairing is
  the entire trust boundary. Worth one line in the plan so it's a
  decision, not an accident: upstream deliberately lets a paired
  session type into the lock screen to unlock it
  (`Switcher.swift:200-209`); XTest inherits that behaviour for free.
- **[note] Helper spawn hygiene.** Exec by absolute path, no shell,
  close inherited FDs beyond the three pipes (don't leak TLS sockets
  or the identity file handle into helpers), helper logging on stderr
  so stdout framing can't be corrupted by a stray `printf`.
- **[note] X authority.** Both helpers act as whatever DISPLAY/
  XAUTHORITY the daemon was started with (`phase-0-plan.md:229-235`
  already showed SSH sees a different display). Injection into the
  wrong display is an admin footgun; packaging as a seat user-service
  is deferred — at least log which display input targets at startup.

## 4. Performance check

- **[should-fix] Drop-policy convergence is unspecified.** "Behind" and
  the rejoin hysteresis aren't defined (change 6). Without a stable
  rule a marginal link oscillates drop↔keyframe every GOP — a session
  that shows a picture one second in four while never converging. The
  client's own stats (kind 12) give the measurement to tune against.
- **[should-fix] Timestamp honesty needs one verification.** Decision 7
  stamps capture wall-clock derived from buffer PTS + pipeline start
  wall-clock. That's the honest number — `frameAgeMs` then includes
  capture→encode→network (`Viewport.swift:109`). But it assumes buffer
  PTS tracks real capture instants through pauses and retunes; verify
  in M2 that per-frame PTS spacing matches wall-clock, or stamp with
  `CLOCK_REALTIME` at the source pad.
- **[should-fix] "Retunes live, no pipeline restart" is unproven for
  fps.** `vah265lpenc`'s bitrate property is plausibly writable live,
  but the client's wanted fps lives in the negotiated caps
  (`ximagesrc` framerate) — changing it is a caps renegotiation, i.e.
  at minimum a flush or a brief restart. Either verify live caps
  change works on the seat session in M5, or plan for a restart with
  the standard rejoin path (sets + forced keyframe, already built).
- **[note] Conversion cost already hedged.** BGRA→NV12 at
  2266x1488/60 is ~200 Mpix/s of `videoconvert`; the plan's own risk
  entry covers measuring it with `vapostproc` as fallback — right
  instinct, keep it.
- **[note] Encode headroom was measured on a cheap source.** The ~90
  fps figure (`phase-0-plan.md:215-227`) is `videotestsrc`; the real
  desktop is heavier but also mostly static — fine, just don't quote
  90 fps as the desktop number.
- **[note] Bus cost is trivial.** ~25 KB average AUs at 60 fps copied
  per session through one NIO loop (~1.5 MB/s) is nothing; the 340
  MB/s capture number never crosses the daemon. No concern.
- **[note] Idle-desktop waste.** No frame-skip for a static screen;
  encoder runs at 60 fps forever. Not a 60-fps risk, a power one —
  see optional improvements.

## 5. Optional improvements

- Send kind 22 `goodbye` (`reconnect:true`) on daemon shutdown and on
  media-helper death — better client recovery UX than a dead socket.
- `ximagesrc use-damage=true` (or damage-region dedup) to stop pushing
  identical frames on a static desktop — saves encode GPU, bandwidth,
  and client decode power; keep the tick for keepalive.
- Advertise a preset bitrate (15M `balanced`) instead of custom 12M so
  the value is pickable from the client; keep `persistent:false`.
- Populate `HostSettingsState.link` (`LinkReport`, `HostSettings.swift
  :146-179`) when a session is dropping — the client can then offer
  the lower-quality suggestion UI upstream built.
- Kind 26 `macPointer` is a cheap, independent win later: poll
  `XQueryPointer` on the 30 ms tick and send to non-driving sessions —
  fixes the plan's own flagged trade-off (host-side mouse invisible).
- Sandbox the helpers when packaged (systemd `Protect*`, restrict to
  X11/VA-API access) — they only need stdio + DISPLAY + the render
  node.

## 6. Assumptions to verify empirically

- **`vah265lpenc` honours `GstForceKeyUnit`.** The whole KEYFRAME
  command — and therefore M4's ~1 s recovery — rests on this; Phase 0
  verified forced IDR as an offline encode criterion
  (`phase-0-plan.md:51-52`) but not an on-demand event on a running
  pipeline. If unsupported, the only recovery is the 1 s GOP.
- **Modifier delivery by the genuine client.** Whether `.key` events
  for modifiers arrive separately, or only the `modifiers` bitmask —
  decides whether change 2 is a code path or a non-issue. Watch with
  logging in M3.
- **What arrives as `.key` vs `.text`.** Our list has no `keyRepeat`,
  so the client "types a hardware keyboard's characters through
  iPadOS's text system" and "sends them as keys only to a host that
  says so" (`Switcher.swift:63-70`). Whether arrows/function keys land
  as `.key` under that mode needs observation on the real client.
- **Client behaviour on mid-GOP drops** — freeze vs artefacts vs
  immediate keyframeRequest; the plan itself flags this for M4.
- **Seat-display capture rate** — only the 25 Hz-capped remote display
  was measured (`phase-0-plan.md:229-235`); plan flags it too.
- **Client pointer rendering with no kind 14/26** — does it draw its
  own pointer at all when `cursorShape` never arrives, or nothing?
  (Viewport's `localCursor` comment says the client draws its own,
  `Viewport.swift:15-17`; the genuine build's actual behaviour is
  unobserved.)
- **Parameter-set expectations** — whether the client caches kind 0
  per session or needs it re-sent per IDR, and whether the decoder
  accepts AUs that exclude AUD/SEI exactly as the plan strips them.
- **selectSource timing** — whether the client sends `.desktop`
  automatically on connect or only after the user taps, and whether
  viewport precedes it (Phase 0 observed the kinds flowing but not
  the order).
- **Bitrate/fps retune on a live pipeline** — property-write bitrate
  acceptance and any fps path on `vah265lpenc` (see performance §4).
