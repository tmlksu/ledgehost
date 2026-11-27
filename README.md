# ledgehost

A Linux (X11) host that speaks a wire protocol compatible with an
existing iPad remote-streaming client, so the stock client can connect
to a Linux desktop (developed and verified on Xfce / xfwm4).

## Status

Implemented and running:

- Mutual-TLS sessions with SPKI pinning, pairing (rotating code and
  link-based proofs), live pin revocation, connection deadlines and
  per-source throttles
- Desktop capture → HEVC (VA-API / msdk) → wire, with per-session
  backpressure (watermark drop + IDR rejoin) and live fps/bitrate
  settings
- Per-window stream sources: live window list, `ximagesrc xid=`
  capture, resize/destroy handling
- Input: pointer, scroll, keys and Unicode text (including IME-heavy
  scripts such as Japanese via keymap remap), modifier tracking,
  held-state release
- Clipboard sync (kind 32) with ICCCM requestor interop
- Host pointer position (kind 26): watching sessions get the pointer
  as a fraction of their source's frame, on change only, suppressed
  for the session currently driving it
- Remote access: a second listener plus a signed kind-18 MacInfo that
  advertises one configured address (e.g. a VPN/WARP route)

Not implemented: audio, virtual displays, pairing "ask" approval UI
(code pairing is the approval).

## Requirements

- Linux with an X11 session and a VA-API-capable encoder (tested on an
  Alder Lake-N iGPU with `msdkh265enc`; `vah265lpenc` is the measured
  fallback)
- A Swift 6 toolchain
- A C toolchain plus GStreamer, GLib and X11 development headers (the
  Makefile documents the include/link layout it uses)

## Build and test

    swift build -c release      # daemon + probe
    make helpers                # C helpers (media, input, xquery, bar) into bin/
    make install-debug          # also copy helpers next to .build/debug products

    swift test                  # unit tests
    scripts/loopback-e2e.sh     # loopback pairing/session regression
    scripts/real-app-roundtrip.sh <display>   # real-app input/clipboard round-trip

The daemon finds its helpers next to its own binary — keep the four
artifacts in one directory.

## Install as a service

`ledgehostd` ships as a systemd **user** service. Install, display
selection, remote-access configuration and day-to-day commands are
documented in `docs/packaging.md`.

## Documents

- `docs/packaging.md` — installing and running the systemd user service
- `docs/explainer.md` — illustrated overview: design, connection flow, wire protocol, development phases (Japanese, diagrams)
- `docs/phase-minus-1-report.md` — desk research report (upstream tag pin, rejection inventory, Linux build audit, Go/No-Go)
- `docs/phase-0-plan.md` — Phase 0 plan: protocol core (vendored wire module, pairing, TLS, catalog)
- `docs/phase-1-plan.md` — Phase 1 plan: the minimal streaming slice (media, input, backpressure, settings) with its engineering log
- `docs/phase-2-plan.md` — Phase 2 plan: per-window stream sources
- `docs/remote-access-plan.md` — remote access: configured vpn address, second listener, signed MacInfo

`Vendor/` contains the pinned upstream wire-protocol module with its
own license; see `Vendor/VENDORED.md`.

## Name and affiliation

`ledgehost` is a neutral codename chosen for this project. It is not
affiliated with the upstream client project.

## License

Apache-2.0 (see `LICENSE`). Vendored upstream code under `Vendor/`
keeps its own license (Apache-2.0) and notices.
