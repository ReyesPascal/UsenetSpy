# UsenetSpy

A small read-only monitor that shows which **public IP** your Usenet traffic leaves from.
It finds your Usenet containers on its own and alerts you if Newshosting could see more than one IP.

It's built to answer one question: *is the server the only thing talking to Usenet, and is it
always using one IP?*

## What it shows

```
CONTAINER(S)                 CONNS  PUBLIC IPv4       PUBLIC IPv6              USENET SERVERS
nzbdav                       10     73.x.x.x          -                        10x 216.x.x.x
usenet-ultimate              3      73.x.x.x          -                        3x 216.x.x.x
host                         0      73.x.x.x          -

OK: all Usenet traffic leaves from one IP: 73.x.x.x
```

- **Auto-discovery.** Any running container whose name or image matches `nzbdav`, `usenet`,
  `ultimate`, `sabnzbd`, `nzbget`, `gluetun`, `altmount` or `decypharr` is listed. The laptop itself (`host`) is always listed.
  New containers are picked up every 15 seconds.
- **Catches strays.** A container that opens Usenet connections without matching that pattern gets listed anyway, with an
  `UNEXPECTED` alert.
- **VPN-aware.** Containers that share a network (`network_mode: service:gluetun` or
  `network_mode: host`) are grouped into one row, for example `gluetun+sabnzbd`.
- **Real public IP per container.** It checks from inside each container's own network, so a container
  behind a VPN shows the VPN's IP.

| Status / alert | Meaning |
|---|---|
| `OK: all Usenet traffic leaves from one IP` | What you want. |
| `!! SPLIT: Newshosting is seeing N IPs right now` | Two routes in use at once (for example one container behind a VPN). Expect 502 errors. |
| `!! WARNING: ... leave the internet from DIFFERENT IPv4s` | Idle right now, but a split would happen as soon as both are busy. |
| `ALERT ... public IPv4 changed` | The server's IP changed (laptop moved networks, VPN reconnected, ISP change). |
| `ALERT UNEXPECTED Usenet connections from 'X'` | Something you didn't expect is connecting to Usenet. |
| `IDLE` | No Usenet connections open. |

## Install

```bash
git clone https://github.com/ReyesPascal/UsenetSpy.git
cd UsenetSpy
docker compose build
```

## Use

**Live dashboard** (refreshes every 2 seconds, Ctrl-C to quit):
```bash
docker compose run --rm -e MODE=live usenetspy
```

**Background change log.** It prints a line only when something changes, which is handy for leaving it running during a test:
```bash
docker compose up -d
docker logs -f usenetspy
docker compose down            # when you're done
```

### Testing a phone over Tailscale Funnel
1. On the phone, with mobile data on and Wi-Fi and Tailscale off, open `ifconfig.me` and note the IP.
2. Start the live dashboard on the server.
3. Press play on the phone. `usenet-ultimate` briefly opens a few connections (health check), then
   `nzbdav` jumps while the video streams, all on your home IP.
4. On Android, run **PCAPdroid** during playback and filter for port 563. It should show nothing.

**Limit:** this tool can only see traffic that passes through the server. If a phone connected
to Usenet directly over mobile data, the server would never see it. That's why step 4 matters.

## Settings (`docker-compose.yml` → `environment`)

| Variable | Default | What it does |
|---|---|---|
| `MATCH` | `nzbdav\|usenet\|ultimate\|sabnzbd\|nzbget\|gluetun\|altmount\|decypharr` | Name/image pattern for auto-discovery |
| `CONTAINERS` | *(empty)* | Exact names to watch instead of auto-discovery, e.g. `"nzbdav usenet-ultimate"` |
| `NNTP_PORTS` | `563 119` | Usenet ports to count. Avoid 443: it would also count indexer web traffic. |
| `INTERVAL` | `2` | Seconds between refreshes |
| `IP_CHECK_EVERY` | `60` | Seconds between public-IP checks |
| `MODE` | `log` | `log` (change log) or `live` (dashboard) |

## Security note

To look inside other containers' networks it runs **privileged**, with the host process list and
the Docker socket. That's effectively root on the laptop. It only reads (it lists containers,
reads connection tables and fetches `1.1.1.1/cdn-cgi/trace` for the public IP), but run it when you
need it and `docker compose down` afterwards rather than leaving it up permanently.

Public-IP checks go to Cloudflare by IP address (`1.1.1.1`, `2606:4700:4700::1111`), so no DNS is needed.
