#!/usr/bin/env bash
#
# https-ssh-client.sh - connect to an https-ssh gateway from the client side.
#
# It asks for everything it needs (gateway, user, credential), logs in over
# HTTPS with POST /login, and then runs a normal interactive `ssh` session whose
# transport is a WebSocket over TLS. Only two standard tools are required:
# `ssh` and `websocat`.
#
# Nothing secret is ever put on a command line: the password / private key goes
# into the POST body through a 0600 temp file, and the short-lived token lives
# only in a 0700 temp helper, so `ps` never shows a credential.
#
# Usage:
#   ./https-ssh-client.sh                       # ask for everything
#   ./https-ssh-client.sh -g https://host -u root -- 'uptime'
#   HTTPS_SSH_GATEWAY=https://host HTTPS_SSH_USER=root ./https-ssh-client.sh
#
set -u

VERSION="1.2.0"
CONFIG="$HOME/.https-ssh-client.json"
WS_URL="https://github.com/vi/websocat/releases/latest/download/websocat.x86_64-unknown-linux-musl"

die() { printf 'https-ssh-client: %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*" >&2; }

usage() {
    cat <<'EOF'
https-ssh-client - plain `ssh` over an https-ssh gateway (WebSocket/TLS)
                   (first run installs itself as `https-ssh-client` and `hsc`)

options:
  -g, --gateway URL    gateway base URL, e.g. https://ssh.example.com
  -u, --user USER      remote SSH user
  -H, --host HOST      sshd address as seen by the gateway   (default: asked)
  -p, --port PORT      sshd port as seen by the gateway      (default: asked)
  -k, --key FILE       use this private key (default: ask auth type)
      --password       force password auth
      --gateway-secret S  send X-Gateway-Secret (only if the gateway needs it)
      --forget         delete the saved answers and start fresh (asks everything)
      --no-save        do not remember these answers
  -h, --help           this text

  -- ARGS              pass ARGS straight to ssh (e.g. -- uptime, -- -L 8080:x:80)

environment:
  HTTPS_SSH_GATEWAY, HTTPS_SSH_USER, HTTPS_SSH_TARGET_HOST, HTTPS_SSH_TARGET_PORT,
  HTTPS_SSH_AUTH (password|key), HTTPS_SSH_KEY, HTTPS_SSH_GATEWAY_SECRET

answers are remembered (except secrets) in ~/.https-ssh-client.json
EOF
}

# --------------------------------------------------------------------------
# arguments  (flags > environment > saved config)
# --------------------------------------------------------------------------
F_GATEWAY="" F_USER="" F_HOST="" F_PORT="" F_MODE="" F_KEY="" F_SECRET=""
SAVE=1 FORGET=0 SSH_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        -g|--gateway) F_GATEWAY="${2:-}"; shift 2 ;;
        -u|--user)    F_USER="${2:-}";    shift 2 ;;
        -H|--host)    F_HOST="${2:-}";    shift 2 ;;
        -p|--port)    F_PORT="${2:-}";    shift 2 ;;
        -k|--key)     F_MODE=key; F_KEY="${2:-}"; shift 2 ;;
        --password)   F_MODE=password; shift ;;
        --gateway-secret) F_SECRET="${2:-}"; shift 2 ;;
        --forget)     FORGET=1; shift ;;
        --no-save)    SAVE=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; SSH_ARGS=("$@"); break ;;
        *)            SSH_ARGS+=("$1"); shift ;;
    esac
done

C_GATEWAY="" C_USER="" C_HOST="" C_PORT="" C_MODE="" C_KEY=""
if [ -f "$CONFIG" ]; then
    eval "$(python3 -c '
import json, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
names = {"gateway": "C_GATEWAY", "user": "C_USER", "host": "C_HOST",
         "port": "C_PORT", "mode": "C_MODE", "key": "C_KEY"}
for k, var in names.items():
    v = d.get(k, "")
    if v not in ("", None):
        print("%s=%s" % (var, shlex.quote(str(v))))
' "$CONFIG" 2>/dev/null)"
fi

if [ "$FORGET" = 1 ]; then
    rm -f "$CONFIG"
    C_GATEWAY="" C_USER="" C_HOST="" C_PORT="" C_MODE="" C_KEY=""
    say "forgot saved settings - starting fresh"
fi

GATEWAY="${F_GATEWAY:-${HTTPS_SSH_GATEWAY:-$C_GATEWAY}}"
SSH_USER="${F_USER:-${HTTPS_SSH_USER:-$C_USER}}"
T_HOST="${F_HOST:-${HTTPS_SSH_TARGET_HOST:-$C_HOST}}"
T_PORT="${F_PORT:-${HTTPS_SSH_TARGET_PORT:-$C_PORT}}"
MODE="${F_MODE:-${HTTPS_SSH_AUTH:-$C_MODE}}"
KEYFILE="${F_KEY:-${HTTPS_SSH_KEY:-$C_KEY}}"
GATEWAY_SECRET="${F_SECRET:-${HTTPS_SSH_GATEWAY_SECRET:-}}"

if [ "$FORGET" = 0 ] && [ -n "$C_GATEWAY" ] && [ -z "$F_GATEWAY" ] \
        && [ -z "${HTTPS_SSH_GATEWAY:-}" ]; then
    say "using saved gateway $C_GATEWAY (user ${C_USER:-?}) - run with --forget to change"
fi

# --------------------------------------------------------------------------
# tools
# --------------------------------------------------------------------------
command -v ssh >/dev/null 2>&1 || die "the 'ssh' binary was not found in PATH"

# Install this script as the `https-ssh-client` and `hsc` commands on first
# run, so it can be started from any directory afterwards.
SELF="$0"
if command -v readlink >/dev/null 2>&1; then
    SELF="$(readlink -f "$0" 2>/dev/null || echo "$0")"
fi

link_self() {
    ln -sf "$SELF" "$1/https-ssh-client" 2>/dev/null || return 1
    ln -sf "$SELF" "$1/hsc" 2>/dev/null || return 1
    INSTALLED_TO="$1"
    return 0
}

install_self() {
    local dir
    # prefer a writable directory that is already on PATH
    for dir in /usr/local/bin "$HOME/.local/bin" "$HOME/bin"; do
        case ":$PATH:" in
            *":$dir:"*) ;;
            *) continue ;;
        esac
        [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || continue
        if [ -w "$dir" ] && link_self "$dir"; then
            return 0
        fi
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
           && sudo ln -sf "$SELF" "$dir/https-ssh-client" 2>/dev/null \
           && sudo ln -sf "$SELF" "$dir/hsc" 2>/dev/null; then
            INSTALLED_TO="$dir"
            return 0
        fi
    done
    # otherwise fall back to ~/.local/bin and tell the user to extend PATH
    for dir in "$HOME/.local/bin" "$HOME/bin"; do
        mkdir -p "$dir" 2>/dev/null || continue
        if [ -w "$dir" ] && link_self "$dir"; then
            return 0
        fi
    done
    return 1
}

INSTALLED_TO=""
if command -v https-ssh-client >/dev/null 2>&1 && command -v hsc >/dev/null 2>&1; then
    :   # both commands are already available
elif install_self; then
    say "installed commands: $INSTALLED_TO/https-ssh-client and $INSTALLED_TO/hsc"
    case ":$PATH:" in
        *":$INSTALLED_TO:"*) ;;
        *) say "note: add $INSTALLED_TO to PATH to use them from any directory" ;;
    esac
else
    say "note: could not install the commands (no writable bin directory on PATH)"
fi

find_websocat() {
    local p
    if command -v websocat >/dev/null 2>&1; then WEBSOCAT="$(command -v websocat)"; return 0; fi
    for p in "$HOME/.local/bin/websocat" /usr/local/bin/websocat /usr/bin/websocat /opt/homebrew/bin/websocat; do
        [ -x "$p" ] && { WEBSOCAT="$p"; return 0; }
    done
    return 1
}

install_websocat() {
    local dest="$HOME/.local/bin/websocat"
    mkdir -p "$HOME/.local/bin" || return 1
    say "downloading websocat -> $dest"
    if curl -fsSL "$WS_URL" -o "$dest" && chmod +x "$dest"; then
        WEBSOCAT="$dest"
        return 0
    fi
    return 1
}

WEBSOCAT=""
if ! find_websocat; then
    say "websocat (the WebSocket client) is required and was not found."
    printf 'install it now from GitHub into ~/.local/bin? [Y/n]: ' >&2
    IFS= read -r yn || true
    case "${yn:-Y}" in
        [Nn]*) die "install websocat, then run this again (https://github.com/vi/websocat)" ;;
    esac
    install_websocat || die "could not download websocat; install it manually and retry"
fi

# --------------------------------------------------------------------------
# ask
# --------------------------------------------------------------------------
ask() { # ask VAR "label" "default"
    local __var=$1 label=$2 def=${3:-} ans
    if [ -n "$def" ]; then
        printf '%s [%s]: ' "$label" "$def" >&2
    else
        printf '%s: ' "$label" >&2
    fi
    IFS= read -r ans || true
    [ -z "$ans" ] && ans="$def"
    printf -v "$__var" '%s' "$ans"
}

say "https-ssh client $VERSION  (ssh over websocket/TLS)"
say ""

if [ -z "$GATEWAY" ]; then
    ask GATEWAY "Gateway URL (e.g. https://ssh.example.com)" ""
fi
[ -n "$GATEWAY" ] || die "no gateway given"

# normalise: add a scheme, drop a trailing slash
case "$GATEWAY" in
    http://*|https://*) ;;
    *) GATEWAY="https://$GATEWAY" ;;
esac
GATEWAY="${GATEWAY%/}"
case "$GATEWAY" in
    https://*) WS_SCHEME=wss ;;
    *)         WS_SCHEME=ws ;;
esac
HOSTPORT="${GATEWAY#*://}"
GATEWAY_LABEL="$HOSTPORT"          # what you typed, e.g. ssh.example.com
TUNNEL="$WS_SCHEME://$HOSTPORT/tunnel"

# discover the sshd port the gateway dials, to offer it as the default
if [ -z "$T_PORT" ] || [ -z "$T_HOST" ]; then
    disc="$(curl -sS -m 8 "$GATEWAY/health" 2>/dev/null || true)"
    if printf '%s' "$disc" | grep -q '"service": *"https-ssh"'; then
        [ -z "$T_HOST" ] && T_HOST="$(printf '%s' "$disc" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ssh_host",""))' 2>/dev/null)"
        [ -z "$T_PORT" ] && T_PORT="$(printf '%s' "$disc" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("ssh_port",""))' 2>/dev/null)"
        [ -n "$T_PORT" ] && say "gateway reachable (sshd ${T_HOST:-127.0.0.1}:${T_PORT})"
    else
        say "warning: could not read $GATEWAY/health"
    fi
fi

[ -n "$SSH_USER" ] || ask SSH_USER "SSH user" "${USER:-root}"
[ -n "$T_HOST" ]   || ask T_HOST  "sshd host as seen by the gateway" "127.0.0.1"
[ -n "$T_PORT" ]   || ask T_PORT  "sshd port as seen by the gateway" "2208"

if [ -z "$MODE" ]; then
    ask MODE "Auth type - password or key" "password"
fi
case "$MODE" in
    p*|P*) MODE=password ;;
    k*|K*) MODE=key ;;
    *) die "auth type must be 'password' or 'key'" ;;
esac

SECRET=""
if [ "$MODE" = key ]; then
    [ -n "$KEYFILE" ] || ask KEYFILE "Private key file (sent to $GATEWAY_LABEL)" "$HOME/.ssh/id_ed25519"
    [ -r "$KEYFILE" ] || die "cannot read key file: $KEYFILE"
else
    printf 'Password for %s@%s: ' "$SSH_USER" "$GATEWAY_LABEL" >&2
    IFS= read -rs SECRET || true
    printf '\n' >&2
    [ -n "$SECRET" ] || die "no password given"
fi

# --------------------------------------------------------------------------
# log in over HTTPS
# --------------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/https-ssh-client.XXXXXX")" || die "mktemp failed"
chmod 700 "$WORK"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# build the request body in a 0600 file; the secret only ever travels through
# the environment (invisible in `ps`), never as an argument.
HTTPS_SSH_T_HOST="$T_HOST" HTTPS_SSH_T_PORT="$T_PORT" HTTPS_SSH_T_USER="$SSH_USER" \
HTTPS_SSH_T_MODE="$MODE" HTTPS_SSH_T_SECRET="$SECRET" HTTPS_SSH_T_KEYFILE="$KEYFILE" \
python3 - "$WORK/body.json" <<'PY' || die "could not build the login request"
import json, os, sys
d = {
    "host": os.environ["HTTPS_SSH_T_HOST"],
    "port": int(os.environ["HTTPS_SSH_T_PORT"]),
    "user": os.environ["HTTPS_SSH_T_USER"],
}
if os.environ.get("HTTPS_SSH_T_MODE") == "key":
    with open(os.environ["HTTPS_SSH_T_KEYFILE"]) as fh:
        d["key"] = fh.read()
else:
    d["password"] = os.environ["HTTPS_SSH_T_SECRET"]
with open(sys.argv[1], "w") as fh:
    json.dump(d, fh)
PY
chmod 600 "$WORK/body.json"

: > "$WORK/curl.cfg"
chmod 600 "$WORK/curl.cfg"
[ -n "$GATEWAY_SECRET" ] && printf 'header = "X-Gateway-Secret: %s"\n' "$GATEWAY_SECRET" >> "$WORK/curl.cfg"

say "logging in to $GATEWAY_LABEL as $SSH_USER (${MODE}) ..."
RESP="$(curl -sS -m 60 --fail-with-body -X POST "$GATEWAY/login" \
        -H 'Content-Type: application/json' -K "$WORK/curl.cfg" \
        --data-binary "@$WORK/body.json" 2>&1)" || true
printf '%s' "$RESP" > "$WORK/resp.json"

eval "$(python3 -c '
import json, shlex, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
for k, v in (("ok", "LOGIN_OK"), ("error", "LOGIN_ERR"),
             ("token", "TOKEN"), ("method", "LOGIN_METHOD")):
    print("%s=%s" % (v, shlex.quote(str(d.get(k, "")))))
' "$WORK/resp.json" 2>/dev/null)"
: "${LOGIN_OK:=}"; : "${LOGIN_ERR:=}"; : "${TOKEN:=}"; : "${LOGIN_METHOD:=}"

if [ "$LOGIN_OK" != "True" ] && [ "$LOGIN_OK" != "true" ]; then
    say "login failed: ${LOGIN_ERR:-$RESP}"
    exit 1
fi
[ -n "$TOKEN" ] || die "the gateway did not return a token"

say "ok (${LOGIN_METHOD:-?})"

# remember the answers (never the password / key material)
if [ "$SAVE" = 1 ]; then
    HTTPS_SSH_C_GATEWAY="$GATEWAY" HTTPS_SSH_C_USER="$SSH_USER" \
    HTTPS_SSH_C_HOST="$T_HOST" HTTPS_SSH_C_PORT="$T_PORT" \
    HTTPS_SSH_C_MODE="$MODE" HTTPS_SSH_C_KEY="$KEYFILE" \
    python3 -c '
import json, os, sys
d = {}
for env, key in (("HTTPS_SSH_C_GATEWAY", "gateway"), ("HTTPS_SSH_C_USER", "user"),
                 ("HTTPS_SSH_C_HOST", "host"), ("HTTPS_SSH_C_PORT", "port"),
                 ("HTTPS_SSH_C_MODE", "mode"), ("HTTPS_SSH_C_KEY", "key")):
    v = os.environ.get(env, "")
    if v:
        d[key] = v
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as fh:
    json.dump(d, fh, indent=2)
os.chmod(tmp, 0o600)
os.replace(tmp, sys.argv[1])
' "$CONFIG" 2>/dev/null || true
fi

# --------------------------------------------------------------------------
# connect
# --------------------------------------------------------------------------
# the proxy helper keeps the password/key out of `ps` entirely; only the token
# is visible in websocat's argv, and a token alone cannot log in (the SSH layer
# still authenticates), so it is not a shell-access credential.
# (the token goes in the URL: websocat's -H is variadic and eats the URL)
cat > "$WORK/proxy.sh" <<EOF
#!/bin/sh
exec "$WEBSOCAT" -b "$TUNNEL?token=$TOKEN"
EOF
chmod 700 "$WORK/proxy.sh"

# make the ssh session authenticate the same way, so the user is asked once
SSH_EXTRA=()
if [ "$MODE" = key ]; then
    SSH_EXTRA=(-o IdentitiesOnly=yes -i "$KEYFILE")
else
    cat > "$WORK/askpass.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$HTTPS_SSH_PW"
EOF
    chmod 700 "$WORK/askpass.sh"
    # SSH_ASKPASS_REQUIRE=force (OpenSSH >= 8.4) keeps the tty while answering
    # the auth prompt from memory, so the password is typed only once.
    export SSH_ASKPASS="$WORK/askpass.sh" SSH_ASKPASS_REQUIRE=force
    export DISPLAY="${DISPLAY:-:0}"
    export HTTPS_SSH_PW="$SECRET"
fi

say "connecting: $SSH_USER@$GATEWAY_LABEL  (gateway sshd $T_HOST:$T_PORT via $TUNNEL)"
say ""

ssh -o "ProxyCommand=$WORK/proxy.sh" \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    "${SSH_EXTRA[@]}" \
    -p "$T_PORT" "$SSH_USER@$T_HOST" "${SSH_ARGS[@]}"
rc=$?
exit $rc
