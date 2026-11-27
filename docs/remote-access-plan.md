# Remote access plan — one configured WARP address, one remote door

Upstream model (vendored `Vendor/StreamProtocol/Remote.swift`, kinds 18–22)
narrowed to this deployment: the host advertises **one** configured
`"vpn"` address that devices reach through the user's WARP/Zero Trust
route (a /32 to the host's LAN address, configured outside this repo),
and runs a second listener — the "remote door" — serving the identical
session gates as the home door.

## Configuration (all OFF by default)

Environment, read once at daemon start (`RemoteConfig` in
LedgehostCore so the parsing/validation is unit-testable). Anything
invalid is a loud startup failure (`exit 2`), never a silent fallback.

| Var | Meaning |
|---|---|
| `LH_REMOTE_PORT` | Remote door's listen port. **Unset = remote access fully disabled** — no second listener, MacInfo unchanged. |
| `LH_REMOTE_ADDRESS` | Host string devices dial, verbatim in `MacInfo.addresses[0].host` — bare host only, no port (one colon → rejected as `host:port`); required when the port is set. |
| `LH_REMOTE_DIAL_PORT` | Optional: the port devices actually dial, for forwarded-port setups. Defaults to `LH_REMOTE_PORT`. |
| `LH_REMOTE_VIA` | `MacAddress.via` display string; default `"VPN"`. |

`remotePort` in MacInfo = the **dial** port (vendored: "the configured
remote port… pairing uses it" — the device's dial target).
`MacAddress.port` stays nil — the vendored semantics say nil means
"use `MacInfo.remotePort`", which is exactly the dial port, so a
per-address port is never needed in this deployment.

No real address is hardcoded anywhere; tests use 192.0.2.0/24
(documentation range) or loopback.

## Kind 18 — always sent, signed (unchanged shape)

The daemon already sends a signed `SignedMacInfo` after hello
(`Catalog.swift`) with `remoteAccess: false, addresses: []` — kept.
Configured builds change only the MacInfo fields:

```
remoteAccess: true
remotePort:   LH_REMOTE_DIAL_PORT ?? LH_REMOTE_PORT
internet:     false
addresses:    [ { host: LH_REMOTE_ADDRESS, port: nil,
                  kind: "vpn", via: LH_REMOTE_VIA } ]
issuedAt:     now   macID/name/privateKey from HostIdentity
```

Signed via the vendored `SignedMacInfo.signing(_:with:)` (P-256/SHA-256
DER over the exact JSON bytes — the F14-verified path). A device
verifies signature + pin + freshness (`verified()`); a stale issuedAt
is the client's rejection, not ours.

Decision: kind 18 is sent on **every** session, configured or not
(the vendored comment allows both; sending keeps one code path and the
signature doubles as an identity attestation).

## The remote door

Second `ServerBootstrap` bind on `0.0.0.0:LH_REMOTE_PORT` with the
**same** pipeline as home: per-source `ConnThrottle` (one shared
instance — a source's budget is global across doors), TLS 1.3 +
SPKI-pin callback, the same `ConnectionHandler`, the same deadlines,
pairing-door caps, pin checks, revocation sweep. Sessions are full
sessions: catalog, kind 18, window list, media, input, clipboard.
Bonjour (`avahi-publish-service`) stays on the home port only —
the remote address is explicit configuration, not discovery.

Nothing in the session code knows which door it is on; where behavior
must differ, it already does by construction, not by a door flag.

## Pairing on the remote door

`sill-pair/1` code pairing works identically (shared `PairingManager`,
code stays the host-side journal secret). **The `ask`/`cancel`
methods stay `closed` at both doors** — the host has no approval UI,
code pairing *is* the approval (kind 19). Same for kind 21
`pairingWanted` arriving on a session connection: there is no UI to
show a code; it is sampled-logged and ignored, as today.

## Liveness parity

`pins.reload()` revocation, clipboard watch counts, injector
arbitration, and the media/input services are all registry-global —
a remote-door session is indistinguishable once inside, by design.

## Proofs

Scratch daemon + scratch pins + documentation-range address.
(a) probe `connect` on the remote port: hello + verified kind 18,
    address list matches config; (b) `record` streams frames over the
    remote door; (c) unpaired probe refused at the remote door;
    (d) code pairing completes via the remote door with a scratch
    identity; (e) config unset → no second listener, sessions
    byte-identical to today; (f) unit tests pin MacInfo construction
    and config validation.
