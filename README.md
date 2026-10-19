# https-ssh

Run SSH over HTTPS.

`https-ssh` is a small gateway that lets normal `ssh`, `scp`, `sftp` and `-L`
port forwarding work through a Cloudflare Tunnel (or any HTTP reverse proxy),
so an SSH server behind NAT or a firewall becomes reachable from anywhere at
an ordinary HTTPS URL.

```
client  --HTTPS-->  Cloudflare Tunnel  --HTTP-->  https-ssh  --TCP-->  sshd
 (ssh)                                            (127.0.0.1:9000)   (2208)
```

## How it works

1. The gateway listens on plain HTTP on localhost, and `cloudflared` publishes
   it as an HTTPS URL.
2. `POST /login` checks the credentials by running the real `ssh` binary
   against the target sshd. If sshd accepts them, the client gets a token.
3. `GET /tunnel` is a WebSocket that carries the raw SSH stream, so the client
   side is stock `ssh`.

There is no password database and no SSH implementation here. sshd is the
judge: whatever it accepts, the gateway accepts.

## Install

```sh
git clone https://github.com/Nahom-digital/https-ssh.git
cd https-ssh
sh install.sh
```

Requires Linux, Python 3.7+ (stdlib only) and OpenSSH. No pip, no other
dependencies. The installer puts two commands on your PATH:

- `https-ssh` - the gateway server and CLI
- `https-ssh-client` - interactive client that connects over HTTPS

## Run the gateway

```sh
https-ssh serve --port 9000 --ssh 2208
```

- `--port` - local HTTP port the gateway listens on
- `--ssh` - port sshd is listening on

On the first run it asks whether it should install itself as a systemd
service:

```
Do you want https-ssh to run as a systemd service? (y/n): y
```

`y` installs, enables and starts the service now and on every boot. `n` runs
in the foreground and does not ask again.

Publish it with a Cloudflare Tunnel:

```sh
cloudflared tunnel --url http://127.0.0.1:9000
```

The hostname that `cloudflared` prints is the URL clients use.

## Connect

```sh
https-ssh-client
```

The client asks for the gateway URL and your SSH user once, logs in, and opens
a normal `ssh` session. Later runs reuse the saved answers (passwords and keys
are never saved); use `--forget` to start over.

Any standard WebSocket client works too:

```sh
ssh -o ProxyCommand='websocat -b wss://your-host/tunnel?token=TOKEN' user@127.0.0.1
```

## Login log

Every login attempt, successful or not, is appended to `log.json` next to the
application, including the real client IP address when the request arrives
through the tunnel.

## Run as a service (systemd)

`https-ssh --service` installs or refreshes the service at any time. The same
units are in `deploy/` if you prefer to copy them yourself:

```sh
sudo cp deploy/https-ssh.service deploy/https-ssh-restart.* /etc/systemd/system/
sudo cp deploy/https-ssh.default /etc/default/https-ssh
sudo systemctl daemon-reload
sudo systemctl enable --now https-ssh.service https-ssh-restart.path
```

Edit `/etc/default/https-ssh` to change ports or set an optional shared
secret. A watcher unit restarts the service whenever the file changes.

## Commands

Gateway (`https-ssh`):

- `https-ssh serve --port 9000 --ssh 2208` - run the gateway (default command)
- `https-ssh --service` - install/refresh the systemd service and start it
- `https-ssh --no-service` - never offer the service, always run foreground
- `--host`, `--port`, `--ssh`, `--secret`, `--log` - server settings
- `HTTPS_SSH_HOST`, `HTTPS_SSH_PORT`, `HTTPS_SSH_SSH_PORT`, `HTTPS_SSH_SECRET`,
  `HTTPS_SSH_LOG` - the same settings as environment variables

Built-in client subcommands (the same `https-ssh` command, handy for scripts):

- `https-ssh login USER@HOST` - log in to a gateway and store the token
- `https-ssh connect USER@HOST` - log in, then open an interactive ssh session
- `https-ssh exec USER@HOST -- CMD` - run one command through the gateway
- `https-ssh proxy HOST PORT` - WebSocket tunnel client for ssh ProxyCommand
- `https-ssh status` - list stored session tokens
- `https-ssh logout [USER@HOST]` - drop stored session tokens
- common options: `-g/--gateway URL`, `-p/--password`, `-i/--key FILE`,
  `--ssh-port PORT`, `--secret S`, `--force-login`

Client script (`https-ssh-client`):

- `-g, --gateway URL` - gateway to connect to
- `-u, --user USER` - SSH user
- `-H, --host HOST` / `-p, --port PORT` - sshd address and port as the gateway
  sees them (usually discovered automatically)
- `-k, --key FILE` / `--password` - choose the auth method
- `--gateway-secret S` - send `X-Gateway-Secret` if the gateway needs one
- `--forget` - delete the saved answers and ask everything again
- `--no-save` - do not remember the answers of this run
- `-- ARGS` - pass ARGS straight to ssh (`-- uptime`, `-- -L 8080:localhost:80`)

The client saves your answers (never passwords or keys) in
`~/.https-ssh-client.json`; `--forget` wipes them.

## License

MIT
