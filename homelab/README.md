# radio-scheduler (optional)

A tiny service for an always-on Linux machine (home server, NAS, Raspberry Pi) in the same network as the radio.
The app sends it the shows you tick in **Favourites schedule**; at the start time the service:

1. turns the radio on (if it is in standby),
2. switches to Internet radio,
3. plays the preset whose name matches the station,
4. sets the volume (`VOLUME`, default 14).

The radio keeps playing afterwards. Each plan fires once. Your Mac can be asleep.

Python 3 standard library only, no dependencies.

## Install

On the server:

```bash
git clone https://github.com/pandawidkur/fsapi-radio-controller.git
cd fsapi-radio-controller/homelab/radio-scheduler
./install.sh <radio-ip> [pin] [token]
```

- `pin` is the radio's NetRemote PIN (default `1234`).
- `token`: in the app open **Settings → Scheduler**, click **Copy token** and paste it here.
  You can also put it into `~/radio-scheduler/token` later and run `systemctl --user restart radio-scheduler`.

The service runs as a systemd user unit (`systemctl --user status radio-scheduler`, logs: `journalctl --user -u radio-scheduler`).

## Connect the app

**Settings → Scheduler**, then pick one:

- **SSH** (recommended): enter the server as an ssh destination (`user@host` or an alias from `~/.ssh/config`).
  The app runs `curl localhost:8735` on the server over ssh, so no port has to be opened.
  Key-based login without a password prompt is required.
- **HTTP**: enter the server's address and port 8735. Open the port for your LAN only, e.g. with ufw:
  `sudo ufw allow from 192.168.0.0/24 to any port 8735 proto tcp`.

Use **Test connection** to check it.

## API

All endpoints except `/health` require the header `X-Token: <token>`.

- `GET /health` returns `{"ok": true}`.
- `GET /schedule` returns `{"plans": [...]}`.
- `PUT /schedule` replaces the list with `{"plans": [{"id", "station", "slot", "title", "start"}]}`.
  `start` is ISO 8601 with an offset, e.g. `2026-11-11T21:00:00+01:00`.
- `GET /status` returns plans, the last 20 events and the server time.
