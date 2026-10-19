#!/bin/sh
# https-ssh.sh - thin launcher for the https-ssh Python application.
#
# It only finds a usable python3 and hands off to https-ssh.py, so the tool can
# be called from any terminal as:  https-ssh <subcommand>
#
# The real program lives next to this file in ~/https-ssh/.

set -eu

# follow symlinks from $0 itself
# (e.g. /usr/local/bin/https-ssh -> ~/https-ssh/https-ssh.sh)
SELF=$0
while [ -L "$SELF" ]; do
    LINK=$(readlink "$SELF")
    case "$LINK" in
        /*) SELF=$LINK ;;
        *)  SELF=$(dirname -- "$SELF")/$LINK ;;
    esac
done
HERE=$(CDPATH= cd -- "$(dirname -- "$SELF")" && pwd)

APP="$HERE/https-ssh"

# a real python3 that can run the app (3.7+ for ThreadingHTTPServer)
PY=""
for cand in "${HTTPS_SSH_PYTHON:-}" python3 /usr/bin/python3 /usr/local/bin/python3 python; do
    [ -n "$cand" ] || continue
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import sys; sys.exit(0 if sys.version_info>=(3,7) else 1)' 2>/dev/null; then
        PY=$cand
        break
    fi
done

if [ -z "$PY" ]; then
    echo "https-ssh: python3 (3.7+) not found in PATH" >&2
    exit 127
fi

if [ ! -f "$APP" ]; then
    echo "https-ssh: application not found at $APP" >&2
    exit 127
fi

exec "$PY" "$APP" "$@"
