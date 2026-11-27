#!/usr/bin/env bash
# install-service.sh — build ledgehost and install it as a systemd
# USER service. Idempotent: re-running rebuilds and reinstalls.
#
#   scripts/install-service.sh [flags]
#
#   --display :NN     DISPLAY for the site drop-in (default :21)
#   --prefix PATH     install prefix (default $HOME/.local)
#   --unit-name NAME  unit name (default ledgehost)
#   --port N          port for a non-default ExecStart (default 17455)
#   --env KEY=VALUE   extra Environment= line in the drop-in (repeatable)
#   --read-write P    extra ReadWritePaths= line in the drop-in (repeatable)
#   --enable          also systemctl --user enable --now
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
display=":21"
prefix="$HOME/.local"
unit="ledgehost"
port=17455
enable=0
display_given=0
extra_env=()
read_write=()

while [ $# -gt 0 ]; do
    case "$1" in
        --display)    display="$2"; display_given=1; shift 2 ;;
        --prefix)     prefix="$2"; shift 2 ;;
        --unit-name)  unit="$2"; shift 2 ;;
        --port)       port="$2"; shift 2 ;;
        --env)        extra_env+=("$2"); shift 2 ;;
        --read-write) read_write+=("$2"); shift 2 ;;
        --enable)     enable=1; shift ;;
        -h|--help)
            sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "install-service: unknown flag $1" >&2; exit 64 ;;
    esac
done

# --- argument validation (audit S15) ----------------------------------
# Every flag value lands verbatim in a systemd unit or drop-in; a newline
# or unit-injection shape in one would smuggle extra directives into the
# service. Reject them before anything is written.

die() { echo "install-service: $1" >&2; exit 64; }

reject_newlines() {   # $1 = flag name, $2 = value
    case "$2" in
        *$'\n'*|*$'\r'*) die "$1: newlines are not allowed (unit injection)" ;;
    esac
}

reject_newlines --display "$display"
reject_newlines --prefix "$prefix"
reject_newlines --unit-name "$unit"
reject_newlines --port "$port"
case "$unit" in
    *[!A-Za-z0-9_.@-]*) die "--unit-name: bad unit name '$unit'" ;;
esac
case "$port" in
    ''|*[!0-9]*) die "--port: not a number: '$port'" ;;
    *) [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "--port: out of range: $port" ;;
esac
case "$display" in
    :*|/*) ;;   # :N or an X socket path
    *) die "--display: expected :N or a socket path, got '$display'" ;;
esac
for e in ${extra_env[@]+"${extra_env[@]}"}; do
    reject_newlines --env "$e"
    [[ "$e" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "--env: expected KEY=VALUE, got '$e'"
done
for p in ${read_write[@]+"${read_write[@]}"}; do
    reject_newlines --read-write "$p"
    case "$p" in
        /*) ;;
        *) die "--read-write: expected an absolute path, got '$p'" ;;
    esac
done

# --- build (repo conventions: toolchain on PATH; the Makefile carries
# --- its own devprefix include/library wiring) -----------------------

SWIFT_BIN="${SWIFT_BIN:-$HOME/tools/swift-6.0.3/usr/bin}"
if [ ! -x "$SWIFT_BIN/swift" ]; then
    echo "install-service: no swift at $SWIFT_BIN (set SWIFT_BIN)" >&2
    exit 1
fi
export PATH="$SWIFT_BIN:$PATH"

echo "install-service: swift build -c release"
(cd "$repo" && swift build -c release)
echo "install-service: make helpers"
(cd "$repo" && make helpers)

# --- install binaries atomically ------------------------------------

libdir="$prefix/lib/ledgehost"
mkdir -p "$libdir"
install_one() {
    local src="$1" name="$2"
    [ -x "$src" ] || { echo "install-service: missing $src" >&2; exit 1; }
    local tmp="$libdir/.$name.new.$$"
    cp -f "$src" "$tmp" && chmod 755 "$tmp" && mv -f "$tmp" "$libdir/$name"
    echo "install-service: $libdir/$name"
}
install_one "$repo/.build/release/ledgehostd" ledgehostd
install_one "$repo/bin/ledgehost-media" ledgehost-media
install_one "$repo/bin/ledgehost-input" ledgehost-input

# --- unit + site drop-in ---------------------------------------------

unitdir="$HOME/.config/systemd/user"
dropin="$unitdir/$unit.service.d"
site="$dropin/site.conf"
mkdir -p "$dropin"
cp -f "$repo/deploy/ledgehost.service" "$unitdir/$unit.service"
echo "install-service: $unitdir/$unit.service"

write_site() {
    {
        echo "[Service]"
        echo "Environment=DISPLAY=$display"
        echo "Environment=XAUTHORITY=%h/.Xauthority"
        for e in ${extra_env[@]+"${extra_env[@]}"}; do
            echo "Environment=$e"
        done
        for p in ${read_write[@]+"${read_write[@]}"}; do
            echo "ReadWritePaths=$p"
        done
        if [ "$prefix" != "$HOME/.local" ] || [ "$port" != 17455 ]; then
            # ExecStart overrides must clear the unit's line first.
            echo "ExecStart="
            echo "ExecStart=$libdir/ledgehostd $port"
        fi
    } > "$site"
    echo "install-service: wrote $site (DISPLAY=$display)"
}

if [ -f "$site" ] && [ "$display_given" = 0 ]; then
    existing="$(sed -n 's/^Environment=DISPLAY=//p' "$site" | head -1)"
    if [ -n "$existing" ] && [ "$existing" != "$display" ]; then
        echo "install-service: WARNING: $site pins DISPLAY=$existing;" >&2
        echo "  keeping it (pass --display explicitly to change)." >&2
    else
        write_site
    fi
else
    write_site
fi

# --- linger check (never sudo) ----------------------------------------

linger="$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo unknown)"
if [ "$linger" != "yes" ]; then
    echo "install-service: WARNING: loginctl linger is '$linger' for $USER." >&2
    echo "  The service stops at your last logout. Enable linger with" >&2
    echo "  'sudo loginctl enable-linger $USER' before relying on it." >&2
fi

# --- reload / enable ---------------------------------------------------

systemctl --user daemon-reload 2>/dev/null \
    || echo "install-service: WARNING: systemctl --user unreachable (no user bus?) — skipped daemon-reload" >&2

if [ "$enable" = 1 ]; then
    systemctl --user enable --now "$unit.service"
    systemctl --user status "$unit.service" --no-pager || true
else
    cat <<DONE

Installed. To enable and start:
  systemctl --user enable --now $unit.service
  systemctl --user status $unit.service
  journalctl --user -u $unit.service -f
DONE
fi
