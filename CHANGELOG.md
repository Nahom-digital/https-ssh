# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-10-19

### Added
- First-run service offer: when the gateway starts in an interactive terminal
  for the first time it asks "Do you want https-ssh to run as a systemd
  service? (y/n)". `y` writes the systemd units and `/etc/default/https-ssh`,
  enables the service and starts it now and on every boot; `n` remembers the
  choice and keeps running in the foreground.
- `--service` flag to install or refresh the systemd service and exit.
- `--no-service` flag to skip the offer and always run in the foreground.
- The client installs itself as both `https-ssh-client` and the short alias
  `hsc` on first run, and `install.sh` creates both links.
- README now lists every command and flag for the gateway, the built-in
  client subcommands and `https-ssh-client`, including `--forget`.

## [1.1.0] - 2026-10-19

### Added
- `https-ssh-client.sh` - interactive client that runs plain `ssh` over
  WebSocket/TLS. It asks for the gateway and credentials, logs in with
  `POST /login`, remembers the answers (never secrets) and installs itself as
  the `https-ssh-client` command on first run, so it works from any directory.
- `--forget` on the client: deletes the saved answers and starts fresh.
- `/tunnel` now also accepts `?token=` and `Authorization: Basic`, so standard
  WebSocket clients such as `websocat` can be used with no custom client code.
- `/login` accepts private key **material**, not only a server-side key path.
- `/health` reports `ssh_host` and `ssh_port`, so clients auto-discover the
  target instead of asking for it.
- Real client IP in `log.json`: `CF-Connecting-IP` / `X-Forwarded-For` are used
  when the connection arrives from a local tunnel, instead of `127.0.0.1`.
- `deploy/` templates for the systemd units and the config file.
- LICENSE (MIT), .gitignore, this changelog.

### Fixed
- **Tunnels were dropped after 15 seconds of silence from sshd.** The upstream
  socket kept the connect timeout (`socket.create_connection(..., timeout=15)`
  leaves it set) and the resulting read timeout was handled exactly like EOF by
  the byte pump. The timeout is now cleared after connecting, so idle tunnels
  are governed by `HTTPS_SSH_IDLE` (default 900s).
- `websocat -H` is variadic and swallowed the URL; the client now carries the
  token in the query string.

## [1.0.0] - 2026-10-17

### Added
- Initial release.
- Gateway server: `serve` (also the default when no subcommand is given).
- HTTP API: `GET /`, `GET /health`, `POST /login`, `GET /tunnel` (WebSocket),
  `POST /exec`, `POST /logout`, `GET /sessions`.
- Client subcommands: `login`, `connect`, `exec`, `proxy`, `status`, `logout`.
- Authentication delegated to the real `ssh` binary - sshd is the judge.
- Login log (`log.json`): JSON array, atomic writes, capped at 5000 entries.
- systemd units, including a `.path` watcher that restarts the service when
  `/etc/default/https-ssh` changes.
