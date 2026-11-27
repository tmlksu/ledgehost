# Phase 2 — per-window stream sources

The upstream feature where the client picks ONE window instead of the
whole desktop: `selectSource .window(id)`, frames at the window's own
size, input coordinates relative to it. Phase 1 shipped desktop-only.

## Window enumeration (`xquery windows`, `xquery watch`)

The daemon stays free of Xlib: enumeration lives in `xquery`, which
gains two modes:

- `xquery windows` — one-shot dump.
- `xquery watch` — long-running; prints an initial snapshot, then a
  fresh snapshot whenever window state changes, debounced ~100 ms.

Snapshot = one `win <xid-hex> <x> <y> <w> <h> <title>` line per listed
window, ended by a `.` line. Titles are single-line-cleaned (controls
replaced). The daemon keeps a `WindowTracker` (a `Process` + pipe on
the event loop, respawned ~1 s after death) holding the latest
snapshot keyed by xid; `onChange` pushes a new `WindowList` to every
session.

Sources in the C tool: `_NET_CLIENT_LIST` on the root (order stable —
mapping order), `_NET_WM_NAME` fallback `WM_NAME` for the title,
`XGetGeometry` for the rect. Watching = `SubstructureNotifyMask |
PropertyChangeMask` on the root plus `PropertyChangeMask |
StructureNotifyMask` on each listed window; any relevant event batch
re-emits the snapshot (create/destroy/map/configure/title all covered
by resnapshotting rather than delta tracking).

### Filter rules (listed if ALL hold)

- in `_NET_CLIENT_LIST`
- `map_state == IsViewable` (iconified/unmapped windows cannot be
  captured; they leave the list, and a watched window that iconifies
  is treated like a destroyed one)
- width > 0 and height > 0
- `_NET_WM_WINDOW_TYPE` absent or != `_NET_WM_WINDOW_TYPE_DESKTOP`
  (the desktop itself is excluded)
- `_NET_WM_STATE_SKIP_TASKBAR`/`SKIP_PAGER` are NOT filtered — panels,
  docks and utility windows are real capturable content.

### Id mapping

`WindowInfo.id = UInt32(xid)` — the X resource id is stable for the
life of the window and unique while it lives; the client echoes it
unchanged in `.window(id)` and the daemon looks it up in the current
snapshot. No secondary id space to keep in sync. `appName` =
WM_CLASS's class part, `bundleID` = `"instance.class"` — best-effort
X11 stand-ins for the macOS fields; `width/height` = pixel geometry
(X11 has no point/pixel split).

## Capture

`ledgehost-media --xid <decimal|0xhex>` selects
`ximagesrc name=src xid=N use-damage=false show-pointer=false` (the
desktop keeps the current startx/endy form). The window's own size
sets the negotiated frame size — no rect args needed.

- **Resize**: the watched window's ConfigureNotify changes the
  snapshot; the pipeline owning that xid restarts through the existing
  debounced `restart()` path (`MediaPipeline`, 3 s global debounce).
  Position-only changes need no restart — xid capture follows the
  window server-side.
- **Destroy/unmap while watched**: the xid drops out of the snapshot;
  every session watching it is moved to the same state `selectSource
  .none` produces today (watching stops, watcher reset), the pipeline
  loses its watchers and stops on the normal 5 s rule, and the pushed
  list no longer contains the window. The client re-asserts from the
  new list — it never hangs on a dead stream.

## Compositor truth (measured 2026-11-27)

xfwm4 runs on the target session but does NOT own `_NET_WM_CM_S0` — its compositor is
off. Measured anyway: a managed 400×300 red window placed at (600,475)
was covered on the right half by a raised override-redirect blue
window (visible in a root capture), then `ximagesrc xid=<red>` +
pngenc was taken — the frame is the window's OWN contents (pure red,
occluder absent). This server preserves window contents for xid
capture (backing store / server-side redirection — mechanism
unidentified, but `xprop -root _NET_WM_CM_S0` confirms no
_NET_WM_CM_S0 owner). Conclusion: **occlusion does not show through on
this host**; on a server without preserved contents it is a documented
limitation of this generation — no compositing workaround is built.

## Pipeline-per-source model

`MediaService` becomes a small manager keyed by `CaptureSource`
(`.desktop` | `.window(UInt32)`): one `MediaPipeline` (supervisor +
reader + sets cache + runningInfo + backoff + restart debounce) per
distinct source, spawned lazily on first watcher and stopped on the
existing 5 s no-watchers rule — independently per source. Sessions
watching the SAME source share its pipeline; each session keeps its
own `Watcher` resume state, watermark and drop accounting exactly as
today — fan-out just routes each pipeline's frames to the sessions on
its source. Forced IDRs stay global-coalesced per pipeline;
`setBitrate`/fps restarts apply to all running pipelines.
`goodbye` on give-up stays per-source: only that source's watchers
are told (the desktop pipeline giving up still reaches every watcher
because in practice it is the only pipeline that can give up under
today's client).

`runningInfo` for kind 16 `stream` reports the session's own source's
pipeline.

## Input mapping

Wire coordinates are fractions of the streamed frame. For a window
source they are relative to the window: the input helper gains op 9
`source-rect` (x, y, w, h as big-endian int32 pixels) setting the
`src_*` mapping rectangle — today fixed to the root window at startup.
The daemon pushes the rect (a) at helper start (same re-push pattern
as op 8's subscriber count), (b) when the injector's watched source
changes, and (c) when that watched window's geometry changes — the
`WindowTracker` already sees ConfigureNotify, so the mapping is
refreshed on the events we track rather than continuously followed.
Injector arbitration generalizes: the most recent source select
(desktop OR window) becomes the injector, so a window-watching client
types into its window's coordinates. Desktop behavior is unchanged:
rect = root.

## Refusals and probes

`selectSource .window(id)` with an id absent from the current snapshot:
sampled log + resend the current list (same pattern as the existing
`.window` refusal). A stale id mid-stream is the destroy path above.

Probe: `windows` mode prints the pushed list (id/title/geometry);
`record --window <id>` sends `selectSource .window(id)` instead of
`.desktop`; `input` gains a `select window <id>` script step so input
proofs drive a window session.

## Proof plan (target X session, headless)

solidwin-style titled scratch windows (distinctive size + color) plus
the bar fixture; probe lists them; per-window record → decoded frame
size == window size and content matches; resize mid-stream → frames at
the new size; close while watched → stream ends cleanly and the list
drops it; pointer (0.5,0.5) on a window source lands at the window's
desktop center (xquery ptr readback).
