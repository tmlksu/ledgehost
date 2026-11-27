# Packaging — ledgehostd as a systemd user service

`scripts/install-service.sh` builds a release daemon plus the C helpers
and installs everything for the current user. No root, no sudo.

## What gets installed where

| path | contents |
|---|---|
| `$HOME/.local/lib/ledgehost/ledgehostd` | the daemon (release build) |
| `$HOME/.local/lib/ledgehost/ledgehost-media` | GStreamer capture/encode helper |
| `$HOME/.local/lib/ledgehost/ledgehost-input` | XTest input + clipboard helper |
| `~/.config/systemd/user/ledgehost.service` | the unit (`deploy/ledgehost.service`) |
| `~/.config/systemd/user/ledgehost.service.d/site.conf` | site drop-in: `DISPLAY`, `XAUTHORITY` |

The binaries install atomically (copy to a temp name in the same
directory, then `mv`), so a running service never sees a half-written
file. ledgehostd finds the helpers next to its own binary — keep all
three in one directory.

The unit itself carries no site-specific lines. The drop-in sets:

    Environment=DISPLAY=:1
    Environment=XAUTHORITY=%h/.Xauthority

`scripts/install-service.sh --display :NN --prefix PATH --unit-name N
--enable` adjusts these; see `--help`.

### Remote access (optional, off by default)

A second listener — the "remote door" — for devices reaching the host
through an overlay network (docs/remote-access-plan.md). Same drop-in:

    Environment=LH_REMOTE_PORT=8443        # remote door's listen port
    Environment=LH_REMOTE_ADDRESS=w.x.y.z  # host devices dial (no port)
    # Environment=LH_REMOTE_DIAL_PORT=443  # only if a forwarder maps it
    # Environment=LH_REMOTE_VIA="VPN"      # display string (default VPN)
    # Environment=LH_REMOTE_BITRATE_KBPS=6000   # remote start bitrate (default 6000, 0 = home default)

Unset `LH_REMOTE_PORT` disables remote access entirely — no second
listener. Any malformed value fails the daemon at startup (loudly, in
the journal) rather than silently disabling the door.

`LH_REMOTE_BITRATE_KBPS` sets the INITIAL encoder bitrate of a media
pipeline created by a remote-door session: the LAN-tuned 15 Mbps start
overruns a thin overlay path, so remote-created pipelines start lower.
It applies only at pipeline creation — media pipelines are shared per
capture source, so the door of the session that FIRST selects a source
decides the spawn value; a `changeSettings` from any viewer retunes
the running pipeline as usual. `0` opts out (remote sessions start at
the home default too).

## Admin CLI

`ledgehost-admin` (installed next to the daemon) talks to the daemon's
admin socket at `<configDir>/admin.sock`: `status`, `code [--new]`,
`devices`, `revoke <prefix>` — see docs/admin.md. The site unit needs
`--config` only if it sets a custom `XDG_CONFIG_HOME`.

## The linger requirement

A user service stops when the user's last session ends — for a remote
desktop host that means it dies at logout. `loginctl enable-linger`
keeps the user manager (and the service) running between sessions and
starts it at boot. The install script checks `loginctl show-user $USER
-p Linger` and warns when it is off; enabling linger needs sudo once:

    sudo loginctl enable-linger $USER

## Changing the display (or any site setting)

Edit `~/.config/systemd/user/ledgehost.service.d/site.conf` directly,
or use `systemctl --user edit ledgehost`, then:

    systemctl --user daemon-reload
    systemctl --user restart ledgehost

Re-running the install script does **not** overwrite an existing
drop-in whose `DISPLAY` differs from the flag default — it keeps the
file and warns. Pass `--display` explicitly to force a rewrite.

**Note:** a session that allocates its display dynamically may
renumber it after a reboot. If the desktop comes back on a different
display, update the drop-in's `DISPLAY=` and restart.

## Day-to-day commands

    systemctl --user start ledgehost
    systemctl --user stop ledgehost
    systemctl --user restart ledgehost
    systemctl --user status ledgehost
    journalctl --user -u ledgehost -f        # logs

## Upgrade

    scripts/install-service.sh             # rebuild + reinstall
    systemctl --user restart ledgehost

The script is idempotent; binaries swap atomically under the running
service, so the restart picks up the new build.

## Uninstall

    systemctl --user disable --now ledgehost
    rm ~/.config/systemd/user/ledgehost.service
    rm -r ~/.config/systemd/user/ledgehost.service.d
    rm -r ~/.local/lib/ledgehost
    systemctl --user daemon-reload

This does not touch `~/.config/ledgehost` (the identity and paired
devices). Remove it separately only if you want a fresh pairing.

## Unit notes

- `Type=exec`, `Restart=on-failure`, `RestartSec=5s`,
  `StartLimitIntervalSec=120`/`StartLimitBurst=10`.
- Sandboxing: `NoNewPrivileges`, `UMask=0077`, `RestrictAddressFamilies`
  (AF_UNIX for the X socket, AF_INET/6 for clients, AF_NETLINK for
  GStreamer/udev), `LockPersonality`, `ProtectSystem=strict` with
  `ReadWritePaths=~/.config/ledgehost`. If unprivileged user
  namespaces are restricted (AppArmor) the unit will fail to start —
  remove the `ProtectSystem`/`ReadWritePaths` lines.
- Deliberately absent: `PrivateTmp`, `ProtectHome`, `PrivateDevices`,
  `MemoryDenyWriteExecute` (they break the X socket, config access,
  `/dev/dri`, or encoder codegen respectively).
- `WantedBy=default.target`, no `After=network.target` (meaningless in
  the user manager).
- The daemon itself needs no X at startup: the helpers open `DISPLAY`
  per session, so the service can start before the desktop does.
- Known gap: clipboard pausing while the session is locked is not
  implemented (no lock-state detection on this host).
