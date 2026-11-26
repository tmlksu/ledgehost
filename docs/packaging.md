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

    Environment=DISPLAY=:21
    Environment=XAUTHORITY=%h/.Xauthority

`scripts/install-service.sh --display :NN --prefix PATH --unit-name N
--enable` adjusts these; see `--help`.

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

**Note:** the remote-desktop session may renumber its display after a
reboot (first free from `:20`). If the desktop comes back on `:22`,
update the drop-in's `DISPLAY=` and restart.

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
