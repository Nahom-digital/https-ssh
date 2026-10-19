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

Ready-to-use units are in `deploy/`:

```sh
sudo cp deploy/https-ssh.service deploy/https-ssh-restart.* /etc/systemd/system/
sudo cp deploy/https-ssh.default /etc/default/https-ssh
sudo systemctl daemon-reload
sudo systemctl enable --now https-ssh.service https-ssh-restart.path
```

Edit `/etc/default/https-ssh` to change ports or set an optional shared
secret. A watcher unit restarts the service whenever the file changes.

## License

MIT
