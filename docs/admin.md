# Admin socket and `ledgehost-admin`

The daemon opens a unix-domain socket at `<configDir>/admin.sock` at
startup (0600, inside the already owner-only config dir) for
operator commands. The socket file itself is the trust boundary —
there is no extra token. If the socket cannot be created the daemon
logs it loudly and serves on without an admin door.

`ledgehost-admin` ships with the daemon (same directory). One
connection carries ONE request: `len(4, BE) + JSON body` (≤ 64 KiB),
answered with one length-prefixed JSON reply and closed.

    ledgehost-admin [--config DIR] <command>

`--config` overrides the config dir (default:
`$XDG_CONFIG_HOME/ledgehost` or `~/.config/ledgehost`) — needed when
the daemon runs under a site unit with a different
`XDG_CONFIG_HOME`.

## Commands

- `status` — macID, host name, home port, the remote door's
  listen/dial port and advertised address when remote access is
  configured, paired-device count, active-session count.
- `code` — the CURRENT 12-digit pairing code and its remaining
  validity in seconds. This is the very secret the pairing door
  accepts right now, read from the daemon's live pairing state; the
  value crosses only the socket — the journal logs the command,
  never the code.
- `code --new` — rotate the code immediately. The old code stops
  working at once; the new one gets a fresh validity window. Runs the
  same rotation path as expiry/success rotation: `triesLeft` resets
  and the 10-minute age clock restarts (the daemon's expiry check is
  age-based, so a `--new` code gets a full window rather than dying
  at a fixed timer tick).
- `devices` — paired devices: display name, model and fingerprint
  (the CLI prints the first 8 characters; `revoke` accepts any
  unambiguous prefix).
- `revoke <fingerprint-prefix>` — remove the matching pin so future
  sessions are refused, and immediately close that device's live
  sessions (same effect as editing `paired.json` plus the 2 s
  revocation poll, but atomic and without the wait). An unknown or
  ambiguous prefix is a clear error and changes nothing.

## Failure behaviour

- Malformed JSON / unknown command / oversized frame → an error
  reply; the daemon is unharmed.
- The socket file deleted mid-run → admin connections fail;
  everything else is unaffected. A new socket appears at the next
  daemon start.
- Replies with `"ok": false` carry an `"error"` string; the CLI
  prints it and exits non-zero.
