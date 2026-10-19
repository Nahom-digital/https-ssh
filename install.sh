#!/bin/sh
# install.sh - make the https-ssh commands available in every terminal.
#
# Installs two symlinks into the first writable directory that is already on
# PATH (/usr/local/bin, ~/.local/bin or ~/bin):
#
#     https-ssh          the server / gateway and client CLI
#     https-ssh-client   the interactive "connect over HTTPS" helper
#
# Run as your normal user; sudo is only used if /usr/local/bin needs it.

set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
APP="$HERE/https-ssh"
LAUNCHER="$HERE/https-ssh.sh"
CLIENT="$HERE/https-ssh-client.sh"

for f in "$APP" "$LAUNCHER" "$CLIENT"; do
    [ -f "$f" ] || { echo "install.sh: missing $f" >&2; exit 1; }
    chmod +x "$f"
done

# pick the first writable directory that is on PATH
TARGET=""
SUDO=""
for dir in /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) continue ;;
    esac
    mkdir -p "$dir" 2>/dev/null || continue
    if [ -w "$dir" ]; then
        TARGET="$dir"
        break
    fi
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        TARGET="$dir"
        SUDO=sudo
        break
    fi
done

if [ -z "$TARGET" ]; then
    echo "Could not find a writable directory on PATH."
    echo "Add this to your shell profile instead:"
    echo "  export PATH=\"$HERE:\$PATH\""
    exit 1
fi

${SUDO:-} ln -sf "$LAUNCHER" "$TARGET/https-ssh"
${SUDO:-} ln -sf "$CLIENT"   "$TARGET/https-ssh-client"
echo "installed: $TARGET/https-ssh        -> $LAUNCHER"
echo "installed: $TARGET/https-ssh-client -> $CLIENT"

if command -v https-ssh >/dev/null 2>&1; then
    echo "ready:  $(command -v https-ssh)"
    https-ssh --version
else
    echo "note: $TARGET is not on PATH in this shell; open a new terminal."
fi

if command -v websocat >/dev/null 2>&1; then
    echo "client: websocat found ($(command -v websocat))"
else
    echo "client: websocat not installed yet - https-ssh-client offers to install it on first run"
fi
