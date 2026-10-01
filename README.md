# Media stack

Seventeen containers that find, fetch, name and serve your media, wired together by one script you
can re-run whenever you like. Plex and Jellyfin for watching; Sonarr, Radarr and Lidarr for
deciding what to fetch; Prowlarr with FlareSolverr for searching; SABnzbd and qBittorrent for
fetching; Bazarr for subtitles; Seerr for requests; Recyclarr for quality; ntfy for alerts; a
dashboard generated from the stack itself; and Gluetun, owning the tunnel that the torrent and
indexer traffic never leaves.

Three decisions shape the rest: imports are **hardlinks**, so a file costs its disk space once;
**no path mapping** is ever needed, because every container sees the same `/data`; and **no
credential is committed** — they live in `.env`, which is gitignored and mode 600.

> **Disclaimer — educational purposes only.** This repository documents how these tools fit
> together and is published to learn from. It is provided as is, without warranty of any kind.
> Only use it with content, indexers and services you are entitled to access; obtaining or
> distributing copyrighted material without permission is illegal in most countries and is
> entirely your own responsibility. The authors condone no such use.

## Quickstart

```bash
git clone git@github.com:mike-echo-oscar-whiskey/media-stack.git && cd media-stack
./setup.sh              # writes .env, asking only what no machine can tell
yay -S mergerfs         # the library is a union of local disk and cloud
sudo ./scripts/union-setup.sh   # fuse.conf + the mount unit, then start it
docker compose up -d    # pulls and starts the seventeen containers
./configure.sh          # wires them together through their own APIs
```

`configure.sh` is safe to re-run and is the whole point: every step prints `ok` when it changed
something and `kept` when it found it already right, so a second run should change nothing.

**You need a WireGuard key before you start.** qBittorrent, Prowlarr and FlareSolverr have no route
to the internet except the tunnel, so without one `setup.sh` refuses to finish and those three never
start — see [Torrents through a VPN](#19-torrents-through-a-vpn-gluetun).

Everything after [Starting the stack](#5-starting-the-stack) is either reference, or the manual
equivalent of something `configure.sh` has already done for you.

## How it fits together

```mermaid
flowchart TD
    seerr[Seerr<br/>requests] --> arr[Sonarr · Radarr · Lidarr]
    arr -->|failures| ntfy[ntfy alerts]
    subgraph tunnel["Gluetun tunnel — the only way out"]
        prowlarr[Prowlarr<br/>every search] --> flare[FlareSolverr]
        qbit[qBittorrent]
    end
    arr -->|searches| prowlarr
    prowlarr -->|spots| spotweb[Spotweb<br/>Spotnet index]
    spotweb -->|headers| usenet([Usenet provider])
    arr -->|torrents| qbit
    arr -->|usenet| sab[SABnzbd]
    sab --> usenet
    qbit --> data
    sab --> data
    arr -->|hardlink| data[(/data/media · one filesystem)]
    subgraph archive["Archive tier — optional, off by default"]
        rclone[rclone mount<br/>encrypts before it leaves]
    end
    data -.->|mover.sh, when the disk fills| rclone
    rclone --> cloud([Google Drive<br/>or a Storage Box])
    subgraph watch["Watching"]
        plex[Plex]
        jelly[Jellyfin]
    end
    data --> watch
    archive --> watch
```

Two things that diagram is there to make obvious. **Every search goes through Prowlarr**, so putting
Prowlarr in the tunnel covers the arr apps too — their indexers point at Prowlarr, never at a
tracker. And **the two that talk to your Usenet provider sit outside it**: SABnzbd for the downloads
and Spotweb for the Spotnet index it serves back to Prowlarr. Usenet has no swarm, the provider knows
your account whatever address you arrive from, and the transfer is already TLS, so tunnelling either
would cost throughput and buy nothing.

The third is the dashed line. **The archive tier is optional and it only moves one way on its own**:
`mover.sh` pushes the least recently added titles out to a remote when the local disk fills, and
never brings them back by itself. Everything is encrypted before it leaves the machine, so the
provider holds ciphertext and nothing else, and both players read from the archive exactly as they
read from `/data/media` — an archived film still plays. With `COMPOSE_PROFILES` empty none of it
exists. See README "The archive tier".

## Contents

**Getting it running**

1. [Prerequisites](#1-prerequisites)
2. [Directory structure](#2-directory-structure)
3. [Installation commands](#3-installation-commands)
4. [Permissions setup](#4-permissions-setup)
5. [Starting the stack](#5-starting-the-stack)

**How it works**

6. [URLs, hostnames and ports](#6-urls-hostnames-and-ports)
7. [Initial configuration order](#7-initial-configuration-order)
8. [Quality: profiles, formats and guards](#8-quality-profiles-formats-and-guards)

**Per-app setup — mostly done for you**

9. [Sonarr / Radarr root folders](#9-sonarr--radarr-root-folders)
10. [Connecting Prowlarr](#10-connecting-prowlarr)
11. [Connecting download clients](#11-connecting-download-clients)
12. [Connecting Seerr](#12-connecting-seerr)
13. [Connecting Bazarr](#13-connecting-bazarr)
14. [Plex library setup](#14-plex-library-setup)
15. [Music (Lidarr)](#15-music-lidarr)
16. [Dubbed audio (the original language plus one more)](#16-dubbed-audio-the-original-language-plus-one-more)
17. [Jellyfin alongside Plex](#17-jellyfin-alongside-plex)

**Operating it**

18. [Hardlink verification](#18-hardlink-verification)
19. [Torrents through a VPN (Gluetun)](#19-torrents-through-a-vpn-gluetun)
20. [Updating containers](#20-updating-containers)
21. [Backing up configuration](#21-backing-up-configuration)
22. [Moving to another server](#22-moving-to-another-server)
23. [Alerts (ntfy)](#23-alerts-ntfy)
24. [Keeping the disk from filling](#24-keeping-the-disk-from-filling)
25. [The archive tier](#25-the-archive-tier)
26. [Spotweb, the Spotnet indexer](#26-spotweb-the-spotnet-indexer)

**When something is wrong**

27. [Troubleshooting permissions](#27-troubleshooting-permissions)
28. [Troubleshooting imports](#28-troubleshooting-imports)
29. [Troubleshooting Docker networking](#29-troubleshooting-docker-networking)

---
## 1. Prerequisites

- Linux host (built and verified on EndeavourOS / Arch). Docker Engine ≥ 24 and the Compose
  plugin ≥ 2.20 (`docker compose version`). On Arch: `sudo pacman -S docker docker-compose`
  and `sudo systemctl enable --now docker`.
- Your user in the `docker` group (`sudo usermod -aG docker "$USER"`, then log out and in).
- **Linux is not incidental.** Four things here have no equivalent on Docker Desktop for macOS
  or Windows: Plex's hardware transcoding passes `/dev/dri` or the NVIDIA runtime into the
  container; Plex runs with `network_mode: host`; the four timers are systemd user units; and
  `setup.sh` measures the host with `ip route`, `timedatectl` and `getent group render`. WSL2
  counts as Linux, with limited GPU passthrough and `systemd=true` needed in `wsl.conf`.
- Host tools the scripts use: `docker`, `curl`, `jq`, `python3` with **PyYAML**
  (`pacman -S python-yaml`, `apt install python3-yaml`) — `configure.sh` checks all four and
  stops if one is missing. `migrate.sh` additionally needs `rsync` and `ssh` on both hosts.
- A systemd **user** session for the timers (`heal.sh`, `watch.sh`, `mover.sh`, `news.sh`, `missing.sh`, `update.sh`
  install user units). Each installer enables lingering so they also run when you are not
  logged in, or prints the one `sudo loginctl enable-linger` command to run if it cannot.
- **One filesystem for the whole `data/` tree.** Hardlinks and atomic moves only work within a
  single filesystem. ext4, xfs, btrfs and zfs are all fine; what breaks it is splitting
  `data/torrents` and `data/media` across two mounts. Check with `df -h data/torrents data/media`
  — both lines must show the same `Filesystem`.
- **A WireGuard key from a VPN provider**, before you start. qBittorrent, Prowlarr and
  FlareSolverr have no route out except the tunnel, so `setup.sh` refuses to finish without one
  and those three never start — see section [Torrents through a VPN (Gluetun)](#19-torrents-through-a-vpn-gluetun).
- Plex Pass if you want hardware transcoding (optional).
- For port-free hostnames (`http://sonarr.<domain>`): a DNS server you control on the LAN
  (Pi-hole, the router, …) and a reverse proxy on the host — see section [URLs, hostnames and ports](#6-urls-hostnames-and-ports). Without them
  everything still works on `http://<ip>:<port>` once `APP_BIND=0.0.0.0`.
- No reverse proxy is included. For access from outside your LAN use
  [Tailscale](https://tailscale.com) (or another VPN) or put a reverse proxy with authentication
  in front. **Never port-forward these web UIs to the internet** — several of them have API keys
  and download-path settings that turn into remote code execution when exposed.

## 2. Directory structure

```text
media-stack/                     # the folder name is yours to choose; compose.yml pins the
                                 # project name, so containers stay media-stack_*
├── compose.yml                  # the stack (hardware-neutral)
├── compose.hwaccel.amd.yml      # optional: Intel/AMD VA-API transcoding for Plex
├── compose.hwaccel.nvidia.yml   # optional: NVIDIA transcoding for Plex
├── gluetun/auth.toml            # Gluetun control-server roles for configure.sh's VPN check
├── spotweb/dbfts_abs.php        # one-character fix for Spotweb's search, mounted over the image's copy
├── spotweb/SpotPage_newznabapi.php  # one-line fix so 4K film spots carry a newznab category
├── .env                         # your values (gitignored)
├── .env.example                 # template
├── users.example.json           # template for users.json (family accounts, both servers, gitignored)
├── README.md
├── AGENTS.md                    # repo conventions and known traps, for coding agents
├── CLAUDE.md                    # one line: imports AGENTS.md, so both toolchains read the same file
├── .agents/skills/              # procedures for coding agents, in the vendor-neutral location the
│                                # Agent Skills standard's clients scan: fresh-install-test,
│                                # add-content, remove-content, env-settings
├── .claude/skills/              # symlinks to the above, because Claude Code scans its own path
├── setup.sh                     # asks the few things it cannot measure, writes .env, creates the directories
├── configure.sh                 # wires the running apps together through their APIs
├── lib/                         # one file per section of configure.sh (plex.sh, arr.sh, recyclarr.sh, ...)
│                                # plus alerts.sh, the ntfy helpers heal/watch/mover share
│                                # plus recyclarr-config.py, the Recyclarr config writer
├── update.sh                    # pull + snapshot + recreate; installs the weekly timer
├── heal.sh                      # acts: restarts unhealthy containers, disk brakes, clears rejected downloads; 2-minute timer
├── watch.sh                     # looks: failed downloads, Spotweb, Plex remote access, the archive mount; 10-minute timer
├── news.sh                      # headlines for the dashboard from an RSS/Atom feed; 15-minute timer
├── missing.sh                   # asks Radarr/Sonarr to search everything missing; nightly timer
├── mover.sh                     # archives old titles when the disk fills; hourly, in the quiet window
├── scripts/archive-setup.sh     # one-time setup of the archive's encrypted remote
├── scripts/release-guard.sh     # Sonarr/Radarr custom script: blocks fake films on grab, fakes of both after import
├── scripts/probe-parser.sh      # ask Radarr/Sonarr what it makes of a title, and test a regex against its own engine
├── scripts/audit-space.sh       # what the disk went to: shared hardlinks vs orphaned downloads
├── migrate.sh                   # move the whole stack to another server (run on the new one)
├── caddy/Caddyfile.example      # reverse-proxy template: one hostname per app, no ports
├── backups/                     # config snapshots and run records from update.sh, heal.sh, missing.sh (gitignored)
├── config/                      # application state, one folder per app (gitignored)
│   └── plex/ jellyfin/ sonarr/ radarr/ lidarr/ prowlarr/ bazarr/ seerr/ sabnzbd/ qbittorrent/ recyclarr/ ntfy/ homepage/
└── data/
    ├── local/                   # the local branch: everything that lives on this disk
    │   ├── torrents/
    │   │   ├── incomplete/      # qBittorrent writes here while downloading
    │   │   ├── movies/          # qBittorrent category "movies" - Radarr imports from here
    │   │   ├── tv/              # qBittorrent category "tv"     - Sonarr imports from here
    │   │   └── music/           # qBittorrent category "music"  - Lidarr imports from here
    │   ├── usenet/
    │   │   ├── incomplete/      # SABnzbd temporary folder
    │   │   └── complete/
    │   │       ├── movies/      # SABnzbd category "movies"
    │   │       ├── tv/          # SABnzbd category "tv"
    │   │       └── music/       # SABnzbd category "music"
    │   └── media/{movies,tv,music}
    ├── archive/
    │   └── media/{movies,tv,music}   # the cloud branch: the rclone mount, encrypted
    └── union/                   # mergerfs over local+archive, mounted as /data in
        ├── torrents/ usenet/    #   every media-handling container. The apps only
        └── media/{movies,tv,music}  # ever see this; which branch holds a file is
                                 #   invisible to them and is the mover's business
```

Why this shape (it is the [TRaSH Guides](https://trash-guides.info/File-and-Folder-Structure/)
layout):

- **One `/data` mount everywhere.** Sonarr, Radarr, SABnzbd and qBittorrent all mount
  `./data` at `/data`. A download that qBittorrent reports as `/data/torrents/tv/Show.mkv`
  is at that exact path for Sonarr too, so Sonarr can `link()` it into `/data/media/tv/…`:
  instant, no extra disk space, the torrent keeps seeding. Separate `/downloads` and `/media`
  mounts are two mount points from the kernel's point of view, and `link()` across mount points
  fails — the *arr apps silently fall back to copying.
- **Per-category subfolders** (`torrents/tv`, `usenet/complete/movies`, …) let each *arr watch
  only its own downloads and stop the two clients from interfering with each other's cleanup.
- **`incomplete/` next to the final folder** means the client's move on completion is an
  atomic `rename()` on the same filesystem — no half-written files for Sonarr to import.
- **Plex mounts only `data/media`, read-only.** It never needs downloads, and a read-only mount
  is one less way for a bug or a misclick to touch your library.
- Cross-seeding tools work unchanged with this layout: everything under `data/torrents` is
  one client's tree and hardlinks in `data/media` keep the originals seedable.

## 3. Installation commands

```bash
git clone <this-repo> media-stack
cd media-stack
./setup.sh              # asks what it cannot measure, writes .env + the directories
docker compose up -d
./configure.sh          # wires the apps together once they are healthy
./update.sh install     # weekly image updates (section [Updating containers](#20-updating-containers))
./heal.sh install       # restarts unhealthy containers every HEAL_INTERVAL (section [Torrents through a VPN](#19-torrents-through-a-vpn-gluetun))
./watch.sh install      # watches for silent failures every WATCH_INTERVAL
./news.sh install       # refreshes the dashboard headlines every NEWS_INTERVAL (section [URLs, hostnames and ports](#6-urls-hostnames-and-ports))
./missing.sh install    # retries missing films and episodes at MISSING_SEARCH_TIME (section [Quality: profiles, formats and guards](#8-quality-profiles-formats-and-guards))
```

`setup.sh` measures what the machine can tell it — user and group ids, timezone, LAN address
and subnet, the `render`/`video` groups, whether a GPU is present — and asks only for what it
cannot: the hostname suffix, other networks Plex should treat as local, whether Plex may be
reached from outside, a Plex claim token, the locale, subtitle and dub languages, a Usenet
account, a WireGuard key for the VPN, and coordinates for the weather tile. Every question has
a default and Enter takes it; the Usenet and VPN questions are skipped with one keystroke, and
passwords and keys are read without echo. With no terminal — a pipe or a script — it takes
every default silently. Everything else (rate caps, seeding rules, Pi-hole tiles, news feeds,
image tags) has a working default and is documented in `.env` itself.

`setup.sh` needs no root. `.env` is the only file with host-specific values; `DATA_ROOT` and
`CONFIG_ROOT` in it point at the two trees (relative to this directory, or absolute — a big
array for `data/`, for example). It writes `.env` from this machine's values (`id -u`/`id -g`, the
system timezone, the LAN IP and subnet of the default route, the `render`/`video` group ids,
the domain suffix for hostnames — it asks, default `home.arpa`), creates
the `config/` and `data/` trees with the permissions from section [Permissions setup](#4-permissions-setup), and runs
`docker compose config --quiet`. It refuses to overwrite an existing `.env`.

Review the result — `cat .env` — and correct anything the heuristics got wrong (typically
`LAN_IP` on a host with several interfaces). It also enables the matching Plex
hardware-transcoding override when it finds a GPU.

`configure.sh` talks to the running containers' APIs and does everything in [Sonarr / Radarr root folders](#9-sonarr--radarr-root-folders) through [Plex library setup](#14-plex-library-setup)
that does not need one of your accounts: one Web UI login for qBittorrent, Sonarr, Radarr,
Prowlarr, Bazarr and SABnzbd (asked once — Enter generates a password — stored in `.env`);
qBittorrent paths and categories; SABnzbd folders and categories; Sonarr/Radarr root folders and both
download clients, TRaSH-style naming and a Plex library-refresh hook; Prowlarr → Sonarr/Radarr;
Bazarr → Sonarr/Radarr plus a language profile from `SUBTITLE_LANGUAGES`; SABnzbd's Usenet
provider from `USENET_*` (if set); Plex claim (it asks for the token) and the two libraries;
Seerr end to end (signs in as the Plex owner, server, libraries, Sonarr, Radarr); the Homepage
dashboard's config; and a check that every hostname resolves and is served. It is idempotent — re-run it after a restore or when
something was changed by hand. What remains is listed at the end of its output.

Everything host-specific lives in `.env`, `config/` and `data/`, all of which are gitignored,
so the repository itself can be public. **`.env` also holds the Web UI login after
`configure.sh` has run** — if you ever regenerate it, carry `WEBUI_USERNAME`/`WEBUI_PASSWORD`
over.

Manual equivalent, if you prefer to see each step:

```bash
cp .env.example .env
$EDITOR .env          # PUID, PGID, TZ, LAN_IP, SITE_DOMAIN, RENDER_GID/VIDEO_GID

mkdir -p config/{plex,jellyfin,sonarr,radarr,lidarr,prowlarr,bazarr,seerr,sabnzbd,qbittorrent,recyclarr,ntfy,homepage/news} \
         data/torrents/{incomplete,movies,tv,music} \
         data/usenet/{incomplete,complete/{movies,tv,music}} \
         data/media/{movies,tv,music}

docker compose config --quiet && echo "compose file OK"
```

`docker compose config` renders the final configuration with `.env` substituted; any
`variable is not set` warning means a line is missing from `.env`.

## 4. Permissions setup

Every container runs as the user in `PUID`/`PGID` and creates files with `UMASK=002`
(directories `rwxrwxr-x`, files `rw-rw-r--`). The only rule is: **the directory trees must be
owned by that same user and group.** Then all eight apps read and write the same files with no
`chmod 777` anywhere.

Find your ids — do not assume `1000:1000`, the primary group often differs:

```bash
id -u    # -> PUID
id -g    # -> PGID
```

Put those in `.env`. Then, from inside the repository directory only:

```bash
# Ownership - scoped to this stack's directories, nothing else.
sudo chown -R "$(id -u):$(id -g)" config data

# Directories group-writable; files as they come (containers create them with umask 002).
chmod -R u=rwX,g=rwX,o=rX data
chmod -R u=rwX,g=rX,o= config       # app state: nobody else needs to read API keys
```

If you already have a media library elsewhere, **do not chown/chmod it in bulk without
looking first.** Point `DATA_ROOT` at its parent, check ownership with `ls -ln`, and only fix
what is actually wrong.

Why no `chmod 777`: with matching PUID/PGID it is unnecessary, and world-writable media
directories let any process on the host (or any other container with a bind mount) alter your
library.

## 5. Starting the stack

```bash
docker compose up -d
docker compose ps                     # STATUS should read "Up (healthy)" within ~1-2 minutes
docker compose logs -f --tail=50      # Ctrl-C to stop following
```

Useful one-liners:

```bash
docker compose logs -f sonarr         # one service
docker compose restart qbittorrent    # restart one service
docker compose down                   # stop and remove containers (config and data are kept)
```

## 6. URLs, hostnames and ports

### Hostnames (the normal way in)

Every app has a name under `SITE_DOMAIN` (from `.env`), all resolving to this host, all on
port 80 through a reverse proxy:

| Service | URL | Internal name (app-to-app settings) |
|---|---|---|
| Dashboard (Homepage) | `http://media.<domain>` — also the bare `http://<LAN_IP>/` | — |
| Plex | `http://plex.<domain>/web` | `http://<LAN_IP>:32400` (host network, see section [Troubleshooting Docker networking](#29-troubleshooting-docker-networking)) |
| Jellyfin | `http://jellyfin.<domain>` | `http://jellyfin:8096` (section [Jellyfin alongside Plex](#17-jellyfin-alongside-plex)) |
| Seerr | `http://seerr.<domain>` | `http://seerr:5055` |
| Spotweb | `http://spotweb.<domain>` | `http://spotweb` (section [Spotweb, the Spotnet indexer](#26-spotweb-the-spotnet-indexer)) |
| Sonarr | `http://sonarr.<domain>` | `http://sonarr:8989` |
| Radarr | `http://radarr.<domain>` | `http://radarr:7878` |
| Lidarr | `http://lidarr.<domain>` | `http://lidarr:8686` |
| Prowlarr | `http://prowlarr.<domain>` | `http://gluetun:9696` — it runs in the tunnel |
| Bazarr | `http://bazarr.<domain>` | `http://bazarr:6767` |
| SABnzbd | `http://sabnzbd.<domain>` | `http://sabnzbd:8080` |
| qBittorrent | `http://qbittorrent.<domain>` | `http://gluetun:8081` — it runs in the tunnel |
| Recyclarr | none — a cron job, no web interface (its health check watches its own sync log) | — (section [Quality: profiles, formats and guards](#8-quality-profiles-formats-and-guards)) |
| FlareSolverr | none — solves an indexer's browser check on request | `http://gluetun:8191/` — it runs in the tunnel |
| Docker proxy | none — read-only Docker API for the dashboard | `http://dockerproxy:2375` |
| ntfy | `http://ntfy.<domain>` | `http://ntfy` — failure alerts |

Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, SABnzbd, qBittorrent and Jellyfin share the login
that `configure.sh` set: `WEBUI_USERNAME` / `WEBUI_PASSWORD` in `.env`. Plex and Seerr use your
Plex account.

Rotating an app's API key (Settings → General → API Key) needs nothing else: the next
`./configure.sh` brings Prowlarr, Bazarr, Seerr, Homepage and Recyclarr back in line. Prowlarr
masks a stored key on read, so its links are checked with its own test endpoint rather than by
comparison, and Seerr's are checked on every run — not only on a fresh install, which is where
a rotation used to leave them broken silently.

Two things outside this repo make the names work:

1. **DNS**: A records `<name>.<domain> → LAN_IP` for the twelve names above, in whatever
   serves DNS on your LAN (Pi-hole "Local DNS Records", the router, `dnsmasq`, …).
   `configure.sh` checks each name and prints the exact records that are missing. Devices
   reaching the LAN over a VPN need that DNS server too (Tailscale: *split DNS* for the
   domain).
2. **Reverse proxy on :80**: `caddy/Caddyfile.example` is a complete, tested Caddy config —
   run Caddy on the host network (native, or a container with `network_mode: host`) with
   `SITE_DOMAIN` in its environment. It proxies each name to the app's localhost port; for
   SABnzbd it rewrites the `Host` header to the app's own name (SABnzbd whitelists host
   names), for qBittorrent it must **not** (its CSRF check compares `Host` with the browser's
   `Origin`). Any other proxy (Traefik, Nginx Proxy Manager) works the same way.

SABnzbd has a second guard behind that one, and it is the one that looks like a network
fault. Besides the host name it also judges the *client's* address, and refuses anything it
does not call local with a bare page reading "External internet access denied" that links to
`sabnzbd.org/access-denied`. Left to itself it trusts whatever Python calls a private address,
which leaves Tailscale out — `100.64.0.0/10` is shared address space, not private — so the
stack reaches you from the LAN and refuses you over the tailnet. Caddy does not stand in for
the client either: it forwards the real address in `X-Forwarded-For` and SABnzbd checks every
hop. `SAB_LOCAL_RANGES` in `.env` spells the ranges out, defaulting to the private networks
plus the tailnet, and `configure.sh` writes it into `sabnzbd.ini` — the API silently ignores
that setting, and SABnzbd rewrites the file as it stops, so the step stops the container,
edits, and starts it again. Nothing on this host can detect the fault, since a request from
the host is always local: test it from the device that was refused.

Plain HTTP by design: private names cannot get public certificates, and the LAN/VPN is the
trust boundary. For HTTPS, use Caddy's internal CA (trust it once per device) or a domain you
own with a DNS-01 wildcard certificate.

### Ports

| Port | Bound to | Purpose |
|---|---|---|
| 80 | the reverse proxy, which is outside this stack | all web UIs by hostname |
| 32400/tcp | every interface — Plex runs on the host network, so no setting here applies | Plex clients need it directly, not via the proxy |
| 6881 tcp+udp | — | not published: qBittorrent is in the tunnel and the VPN forwards a port instead |
| 3000, 8096, 8989, 7878, 8686, 9696, 6767, 5055, 8080, 8081, 8087, 8090 | `APP_BIND` (default `127.0.0.1`) | the apps' own UIs, for the proxy and for `configure.sh` |

`APP_BIND=0.0.0.0` in `.env` (then `docker compose up -d`) also exposes the app ports on the
LAN as `http://<ip>:<port>` — useful before DNS is in place, or if you skip the proxy.

Nothing else is published. Containers talk to each other on the private `media-stack_media`
network by service name — that name is fixed by `name: media-stack` in `compose.yml`, so it does
not change with the folder you cloned into; those addresses resolve only inside the containers. FlareSolverr has
no UI and no port at all — only Prowlarr reaches it, and since both run in the tunnel the address is `http://gluetun:8191`.

### Dashboard

Homepage (`http://media.<domain>`) is generated by `configure.sh` on every run:

- **Media**: Plex (streams, library counts) and Seerr (pending, processing, available).
- **Recently added**: the newest films, the newest seasons and the newest albums, read from
  Plex's Movies, TV Shows and Music libraries, each line opening the item in Plex Web. The music
  tile is found by library *type* rather than by title — this stack names the films and series
  libraries, but a music library may be called anything, and a stack without one simply does not
  get the tile. It lists albums rather than tracks, or one import fills it with its own track
  listing.
- **Today**: three agendas — episodes airing (Sonarr), films releasing (Radarr) and albums
  releasing (Lidarr) — and one headlines tile per entry in `NEWS_FEEDS`; an entry with several feed URLs becomes one mixed
  tile, newest item of each source in turn (`news.sh` fetches them, `./news.sh install` keeps
  them fresh every 15 minutes; the dashboard reads the results from its own container).
- **Downloads** and **Automation**: one tile per app with its queue and wanted counts. Sonarr
  and Lidarr show missing items as *Wanted*; only Radarr's widget separates wanted from
  missing.
- **Infrastructure**: the VPN exit (address, country, forwarded port); an **Alerts** tile linking
  to ntfy; up to two Pi-hole tiles (`PIHOLE_*`, `PIHOLE2_*`), e.g. one per site; and the three
  services that have no interface at all — Recyclarr, FlareSolverr and the Docker proxy — whose
  tiles exist for their container state. A Pi-hole at another site is reached over the tunnel,
  which needs the gateway to masquerade container traffic into it (the dns repo's bootstrap
  does). Their monitor is an ICMP ping of the host, not an HTTP check: Homepage's HTTP monitor
  only sends HEAD, and Pi-hole v6 answers HEAD with 405 plus framing the dashboard's parser
  rejects, on every route. So the tile's dot reports the host and the widget beside it reports
  Pi-hole itself.
- Header: host resources — CPU, memory and free space on `/data`, and with the archive tier on a
  second disk for `/data/archive`, so a mover run can be watched from both ends at once. It
  carries a cloud instead of a drive: the resources widget takes no `icon:` key of its own, so
  `config/homepage/custom.css` (generated, and only while the tier is on) masks that one glyph.
  It pins the disk by position, counted back out of `widgets.yaml` rather than written down
  twice, so adding a third disk moves neither the cloud nor the number.
  Then the weather for `WEATHER_LATITUDE`/`WEATHER_LONGITUDE` (Open-Meteo, no account) and the
  clock in `UI_LOCALE`'s format. Typing on the page searches the tiles (quick launch).

Every tile carries a status dot from a site monitor on its internal address and, through the
Docker proxy (below), its container's state. CPU and memory start folded: click a status dot to
expand that container's figures. They fold back on the next page load, because Homepage keeps no
memory of it — the open state is seeded from `showStats` on every load. Setting `showStats` in
`settings.yaml` is worse than it looks: there it *forces* the panel open and the fold click
cannot close it at all. Note that the memory figure is the Docker API's, which charges the
kernel's page cache to the container: qBittorrent reading and writing torrents shows tens of
gigabytes where its own footprint is about 30 MB.

The API keys live in `config/homepage/services.yaml` (mode 600). `settings.yaml`,
`widgets.yaml`, `docker.yaml` and `custom.css` are regenerated too; put `# keep` on the first
line of any of them to take it over — or `/* keep */` for `custom.css`, where a bare `# keep`
would be a parse error that swallowed the rule after it. `bookmarks.yaml`
is yours from the start. The Plex tile gains its widget once the server is claimed.

### Container state on the dashboard

Every tile shows its container's state and, when you click the status dot, its CPU and memory.
That comes from the Docker API, which the dashboard reaches through **`dockerproxy`**
([tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)) rather than
the socket itself: the proxy answers `GET` only (`POST=0`) and only under `/containers`
(`CONTAINERS=1`), publishes no port and sits on the internal network. A `POST` to restart a
container comes back `403`.

It is still a privilege worth naming. `/containers/{id}/json` includes each container's
environment, so anything that can reach the proxy can read **Gluetun's WireGuard private key**
and the apps' API keys. Homepage already holds those API keys in its own `services.yaml`; the VPN
key is what this adds. Nothing else on the `media` network is exposed to the outside, and the
proxy is not published — that is what keeps the trade acceptable. If you would rather not make
it, remove the `dockerproxy` service and the `server:`/`container:` lines survive harmlessly as
no-ops (`docker.yaml` simply stops resolving).

It also buys tiles for the services that have no interface at all — Recyclarr, FlareSolverr and
the proxy itself — where the container state is the only thing there is to know.

## 7. Initial configuration order

Each step needs a credential or setting produced by the previous one, so do them in this order:

| # | App | Why here |
|---|---|---|
| 1 | `docker compose up -d` | everything else needs running containers |
| 2 | qBittorrent, SABnzbd | produce the password / API key the *arr apps need |
| 3 | Plex, Jellyfin | claim Plex, complete Jellyfin's wizard, create the libraries — the *arr apps' library hooks need them |
| 4 | Sonarr, Radarr, Lidarr | root folders, download clients (from step 2), Plex and Jellyfin hooks; note their API keys |
| 5 | Spotweb | reuses the Usenet account from step 2 and issues the API key Prowlarr needs |
| 6 | Prowlarr | pushes indexers into the *arr apps, so those must exist first with API keys; registers FlareSolverr |
| 7 | Bazarr | reads series and movies from Sonarr/Radarr; links to Plex and Jellyfin |
| 8 | Seerr | signs in via Plex and proxies requests to Sonarr/Radarr — needs those finished |

`./configure.sh` performs steps 2–8 in exactly this order. [Connecting Prowlarr](#10-connecting-prowlarr) through [Hardlink verification](#18-hardlink-verification), plus the VPN, Jellyfin and migration chapters, describe
what it did (and how to do it by hand). What remains **manual** is exactly what needs one of your
accounts: indexers in Prowlarr, subtitle providers in Bazarr, and your Usenet provider's
credentials (which you can hand to the script through `USENET_*` in `.env`).

`configure.sh` sets one login on all seven local UIs (Forms authentication, required on the LAN
too), so no first-visit password prompts remain. It asks for username and password on its
first run (Enter generates a password). To choose a different one later, run
`./configure.sh --set-login` — it asks again and re-applies the login everywhere, including
qBittorrent, which it resets safely if the old password is unknown. `.env` is the source of
truth: whatever `WEBUI_USERNAME`/`WEBUI_PASSWORD` say is what every app gets on the next run.

## 8. Quality: profiles, formats and guards

What a release has to be to be worth downloading: which profiles exist and where they come
from, and what is refused before it ever reaches the disk.

### Where the profiles come from

Quality is not hand-written here. A **Recyclarr** container (MIT, the tool the guides' own
community uses) syncs the [TRaSH Guides](https://trash-guides.info/) into Radarr and Sonarr and
keeps them current: the quality definitions (how big a release may be per minute of runtime),
the custom-format collection with the guides' scores — release-group tiers, audio formats, HDR,
streaming services, the low-quality and unwanted lists — and four quality profiles per app:

| `MEDIA_QUALITY` | Radarr profile | Sonarr profile |
|---|---|---|
| `1080p-encode` | `HD Bluray + WEB` | `WEB-1080p` |
| `1080p-remux` | `Remux + WEB 1080p` | `Remux + WEB 1080p` |
| `2160p-encode` | `UHD Bluray + WEB` | `WEB-2160p` |
| `2160p-remux` | `Remux + WEB 2160p` | `Remux + WEB 2160p` |

All four exist at once, so any title can be asked for differently — in Seerr under *Advanced*,
or in the app itself. `MEDIA_QUALITY` only says which one is the **default**: the profile Seerr
requests with, and the one a film or series on a stock profile is moved onto. These profiles
choose the best release available rather than the smallest, and they allow upgrades, so a WEB-DL
is replaced when a Blu-ray-sourced release of the same title turns up. Watch the disk.

`configure.sh` writes `config/recyclarr/configs/{radarr,sonarr}.yml` from the templates
Recyclarr ships, fills in the URL and API key, and runs one sync; the container then re-syncs on
`RECYCLARR_SCHEDULE` (`@daily`). Put `# keep` on the first line of either file to take it over.

It serves nothing, so there is no page to open and nothing for a dashboard tile to poll. Its
**health check** asks the only question that matters instead: does a log from the last two days
say `Completed at`? If the schedule stops being kept — a failed git fetch, a template the guides
no longer ship — the container goes unhealthy, `docker compose ps` says so and `heal.sh` restarts
it. An installation that has never synced has no logs and counts as healthy until the first run.
This is also why `wait_healthy` in `configure.sh` ignores services that declare no health check:
a container without one reports an empty status forever.
Two details worth knowing if you edit them: the four templates per app are merged into **one
instance**, because Recyclarr groups instances by `base_url` and silently does nothing when
several share a server; and `reset_unmatched_scores` is off, or a sync would clear the scores of
the formats that are ours rather than the guides'.

What `configure.sh` still owns, because no guide covers it: the **dubbed-audio preference**
(section [Dubbed audio](#16-dubbed-audio-the-original-language-plus-one-more)), which profile is the default, and the release guard below. Every other quality decision —
which formats exist, what they score, what each profile accepts — belongs to the guides. Profiles this stack managed before the
guides took over (`1080p Encode` and friends) are emptied onto the default and deleted.

### Fakes, cams and anything under 720p

No custom format of ours stands between you and a bad release; the quality rules are the
guides' and stay that way.

#### What the profile already refuses

Cams, screeners and low-resolution rips are handled by the profile, not by a format. `CAM`,
`TELESYNC`, `TELECINE`, `WORKPRINT`, `REGIONAL`, `DVDSCR`, `SDTV` and the 480p/576p tiers are
*qualities* in Radarr and Sonarr, and the guide profiles do not allow them — `HD Bluray + WEB`
permits exactly Bluray-720p, WEB 1080p and Bluray-1080p. Anything parsed into another quality
is refused before a format score is counted. That is why the TRaSH guides ship no cam format
either: their `LQ` formats only list release groups. Junk that announces itself in the title,
from bad groups to AI upscales, is covered by the guides' own `LQ`, `LQ (Release Title)` and
`Upscaled` formats, all scored -10000 in every managed profile.

#### Why title patterns are the wrong tool

Fakes are different, because a fake carries a perfectly good quality and often a clean title.
Unreleased films attract them: AI "versions", fan edits and uploads named after the film that
are something else entirely. Radarr's *minimum availability* keeps RSS from grabbing before
the digital release, but a search — manual, or triggered by a request — ignores it and takes
what is offered. Three fake *Odyssey* releases arrived that way on 2026-09-23.

This stack tried patterns, and the history shows why they were dropped: every one of those
fakes was *grabbed* and only then failed, including the two whose titles carried a marker,
while the one with a clean title could never have matched a pattern at all. What stopped all
of them was the guard below, which looks at the release date and the file itself.

If you do reach for a pattern — a dubbed-audio tag, say (section [Dubbed audio](#16-dubbed-audio-the-original-language-plus-one-more)) — never guess what it
matches. Ask the app's own parser:

```bash
./scripts/probe-parser.sh radarr "Some.Movie.2026.HDCAM.1080p.x264-GRP"
./scripts/probe-parser.sh sonarr -r '\b(NLD|NL[ ._-]?Gesproken)\b' "Show.S01E01.1080p.WEB-DL.NLD.x264"
```

Without `-r` it prints the quality, languages and custom formats the app matches for a title.
With `-r` it creates a throwaway custom format holding that regex, reports which titles it
catches, and deletes it again. The engine is .NET's rather than grep's, and a pattern that
reads correctly in a shell can match nothing here.

#### The release guard

`scripts/release-guard.sh`, mounted at `/scripts` in Sonarr and Radarr and wired as a *Custom
Script* connection by `configure.sh`:

- **On grab, films only**: one whose digital or physical release is still ahead cannot have a
  genuine release yet, so the grab is removed from the queue and blocklisted before anything is
  downloaded. Radarr's own *minimum availability* only guards its RSS runs; a search, and Seerr
  requests trigger one, walks past it.

  **Series are deliberately exempt.** Dutch broadcasters publish to NLZIET and their own apps
  before the linear broadcast, so an episode can legitimately exist days before the date TVDB
  carries. Judging series on the air date threw genuine episodes away and then grabbed them
  again. What protects a series is the runtime and frame-size comparison below.
- **On import**, three checks in order:

  1. **Not out yet?** Films only, and rejected whatever the file looks like — a cinema recording
     of the right length passes every other test.
  2. **Runtime.** The file's duration against what TMDb or TVDB publish. Shorter than 80 % or
     longer than 115 % (`GUARD_MIN_RATIO` / `GUARD_MAX_RATIO`) means a fake or a mislabelled
     upload. Genuine files here measure 0.99 to 1.01; the one real fake came in at 0.50.

     The floor is 0.80 rather than something tighter because the two sources do not always
     measure the same thing. For an ad-supported broadcast the published runtime is often the
     **slot** while the file is the **programme** — a 55 minute slot arrives as a 45 minute
     file, ratio 0.82. A 0.90 floor threw those episodes away and blocklisted them. The ceiling
     costs alternate cuts: an extended cut runs 1.1 to 1.4× theatrical, so raise
     `GUARD_MAX_RATIO` if you want them.
  3. **Frame size.** A release named 1080p must reach about 1920 wide or 1080 high. Letterboxed
     and pillarboxed films pass; a 720p upscale sold as 1080p does not.

  Any failure marks the grab failed, which blocklists it, deletes the file and starts a fresh
  search — for a film, only once it is actually out. An unknown runtime gives no verdict rather
  than a guess. Every decision is logged to `config/<app>/release-guard.log`.

#### What heal.sh clears up afterwards

The apps stop tracking a download once it is imported, so several kinds of debris outlive them.
`heal.sh` (section [Torrents through a VPN](#19-torrents-through-a-vpn-gluetun)) sweeps every two minutes:

- **A rejected torrent still seeding**: matched against the apps' failed downloads and deleted
  with its files.
- **A payload that never fails**: a release carrying an executable downloads fine and is refused
  at import as a *warning*, so nothing marks it failed, "redownload failed" never fires, and the
  item sits in the queue for good while the episode stays missing. Blocklisted and removed,
  matching only that message. Anything merely slow is left alone.
- **Seeding what you no longer keep**: an upgrade replaces a file and the torrent carries on
  uploading the same bytes under its own name. Removed **with its data** once qBittorrent has
  stopped it — at ratio 1 or 24 hours — so the seed promised at grab time is honoured first.
  Never a torrent still in an app's queue, nor a category in `HEAL_ORPHAN_KEEP`.
- **Data nothing owns**: files left behind when a torrent has already gone, which grow with
  every upgrade — 32 GB had collected by 2026-09-25. Deleted from `data/torrents` when nothing
  in the library shares the bytes, no torrent covers it, every queue is empty and nothing has
  touched it for `HEAL_ORPHAN_HOURS` (24 by default; 0 turns the sweep off).
- **A finished usenet download nothing imported**: the sweep above walks `data/torrents` only,
  so 26 GiB collected in `data/usenet/complete`. Reclaimed under the same two settings, but with
  a different guard: nothing *holds* a finished usenet download, and the torrent sweep ignores a
  queue item parked on a warning — which is what an episode waiting on a TBA title is, for up to
  48 hours, with its file complete. This one matches the apps' queue `outputPath` instead.
- **A magnet that never resolves**: it sits in `metaDL` until a peer hands over the metadata,
  which for a dead swarm is never, while holding one of the client's download slots. Nothing
  else notices — qBittorrent's timers cover *seeding*, the apps have no stalled handling, and the
  state is neither failed nor finished. Three such magnets once stopped 38 healthy torrents from
  starting. Given up on after `HEAL_METADATA_STALL_MINUTES` (60 by default; 0 turns it off), and
  removed through the app that asked for it so another release is searched for.

### Music, which nothing syncs

TRaSH has no Lidarr data — `docs/json` holds Radarr and Sonarr and nothing else — and its Lidarr
page says so, pointing at Davo's Community Lidarr Guide, which is an index into the Servarr wiki
where the values actually live. One community source, no dataset behind it, nothing to keep it
current. So `configure_lidarr_formats` takes only what cannot go stale: four custom formats,
scored on every profile, plus the guide's FLAC size ceilings (1400 MB/min, 1495 for 24bit).

| Format | Score | |
|---|---|---|
| `Vinyl` | −10000 | Surface noise and a different master — wrong for a library you stream. |
| `CD` | 10 | Source preference. |
| `Lossless` | 10 | Inert while the profile allows none; correct the moment one does. |
| `WEB` | 5 | Source preference. |

Two of the guide's recommendations are deliberately left out. Its three preferred release groups
are hardcoded scene names — the equivalent lists for films and series are safe only because
Recyclarr refreshes them. And its `Minimum Custom Format Score = 1` rejects any release matching
no format at all, which a plain `MP3 320` does; set it per profile in Lidarr's UI if you want it.

### Retrying what stalled

After a failed download Radarr and Sonarr blocklist the release and try the next candidate
at once, but once they run out they stop for good; from then on the title only returns if a
brand-new release appears in the hourly RSS feed. `./missing.sh` asks both apps to search
everything they still lack, and `./missing.sh install` runs it nightly at 02:00, inside the
unrestricted window (section [Connecting download clients](#11-connecting-download-clients)), with the profiles and the guards applied as on any other
grab. Only released films are searched: Radarr's own missing search
ignores release dates and would fetch fakes of unreleased ones. `./missing.sh status` shows
the last run.

When a fake does get in anyway: on the film's page in Radarr, Activity → History, click
*Mark as failed* on the grab. That blocklists the release, and after deleting the file
(Files → the bin) a new search skips it. Seerr cannot do this; it only requests.

## 9. Sonarr / Radarr root folders

`configure.sh` also sets each app's Settings → UI from `.env`. `UI_LOCALE` is the switch —
empty or `en-US` leaves the apps at their own defaults — and three keys say what to apply:
`UI_DATE_FORMAT` (`YYYY-MM-DD`, `DD/MM/YYYY` or `MM/DD/YYYY`, with the long date and the
calendar's week column following from it), `UI_TIME_FORMAT` (`24h` or `12h`, which the
dashboard clock follows too) and `UI_FIRST_DAY_OF_WEEK` (`monday` or `sunday`). The language
stays English. Same in Lidarr and Prowlarr.

**Sonarr** → Settings → Media Management → Root Folders → Add:

```text
/data/media/tv
```

**Radarr** → Settings → Media Management → Root Folders → Add:

```text
/data/media/movies
```

In both, under Settings → Media Management → *Importing*, make sure **Use Hardlinks instead of
Copy** is on (it is the default). Do not tick "Remote Path Mappings" for anything — every
service sees the same `/data` paths, so there is nothing to map.

Renaming and the naming formats come from the [TRaSH Guides](https://trash-guides.info/), and
for Sonarr and Radarr it is **Recyclarr** that applies them, alongside the quality definitions
and custom formats — the guide owns the formats, so the guide's own sync is what sets them. The
Plex variants are used (`{tvdb-…}` for series folders, `{tmdb-…}` for films), because Plex's
agents match on the braced id; Jellyfin's bracketed `[tvdbid-…]` form cannot be had at the same
time. Because Recyclarr re-applies them on every sync, edits made under *Episode/Movie Naming*
in the UI do not survive — change `MEDIA_NAMING` in `lib/recyclarr-config.py` instead, or put
`# keep` on the first line of `config/recyclarr/configs/<app>.yml` to take the file over.
Lidarr has no Recyclarr support, so `configure.sh` sets its naming once and then leaves it.

`configure.sh` also adds a **Plex** connection (Settings → Connect) so Plex refreshes the
library right after an import, rename or delete. The connection is added once the Plex server
is claimed.

`configure.sh` reads each app's API key from `config/<app>/config.xml` for Prowlarr and
Bazarr. Seerr (manual) needs them too: Settings → General → Security → API Key.

## 10. Connecting Prowlarr

Prowlarr is the single place you configure indexers; it pushes them into Sonarr and Radarr and
keeps them in sync. Add only indexers you have an account with and are entitled to use.

Steps 1–2 are done by `configure.sh`, which also registers SABnzbd and qBittorrent as
Prowlarr's own download clients so a grab from Prowlarr's search page works, with the
indexer category mapped to the client category the apps use (Movies → `movies`, TV → `tv`,
Audio → `music`, anything else → `prowlarr`); step 3 is **manual** (your
accounts).

1. Prowlarr → Settings → Apps → **+** → Sonarr:
   - Prowlarr Server: `http://gluetun:9696` (Prowlarr runs in Gluetun's namespace)
   - Sonarr Server: `http://sonarr:8989`
   - API Key: Sonarr's key from section [Sonarr / Radarr root folders](#9-sonarr--radarr-root-folders)
   - Sync Level: *Add and Remove Only* (default) — Test, then Save.
2. Repeat for Radarr with `http://radarr:7878` and Radarr's key, and for Lidarr with
   `http://lidarr:8686` and Lidarr's key.
3. Prowlarr → Indexers → **+** → add your indexers. Each one appears in Sonarr/Radarr under
   Settings → Indexers within a minute, tagged as managed by Prowlarr.

Use the service names above, not the host's IP. Docker DNS resolves them on the stack's
network, they survive an IP change on the host, and they do not depend on a port that is
published to the LAN.

### Cloudflare-protected indexers (FlareSolverr)

Some indexer sites put a Cloudflare "checking your browser" page in front of every request,
which Prowlarr cannot pass on its own. FlareSolverr is a small service with a headless
Chromium that passes it for Prowlarr. `configure.sh` registers it (Settings → Indexers →
Indexer Proxies → *FlareSolverr*, host `http://gluetun:8191/`) together with a tag named
`flaresolverr`. Prowlarr uses the proxy only for indexers that carry that tag, and even then
only when it actually meets a Cloudflare challenge — so:

- an indexer that fails with a Cloudflare error: edit it in Prowlarr, add the tag
  `flaresolverr`, Test again;
- everything else stays untouched.

The container idles at ~400 MB and takes up to ~1 GB while solving a challenge (it is a browser).
Nothing about it changes the rule above: only indexers you have an account with.

## 11. Connecting download clients

### qBittorrent

`configure.sh` does all of this; the settings it applies are listed here so you can check or
redo them. Log in at `http://qbittorrent.<domain>` with `WEBUI_USERNAME`/`WEBUI_PASSWORD` from `.env`. (On a
container that was never configured, qBittorrent prints a one-time password to its log —
`docker compose logs qbittorrent | grep -A1 'temporary password'` — and `configure.sh` uses it
to set the permanent one.)

- **Tools → Options → Web UI**: username and password (stored hashed in
  `config/qbittorrent/qBittorrent/qBittorrent.conf` — never in `compose.yml`).
- **Options → Downloads**:
  - Default Save Path: `/data/torrents`
  - Keep incomplete torrents in: `/data/torrents/incomplete` (tick it)
  - "Append .!qB extension" on; it stops the *arr apps from importing a partial file.
  - Seeding limits from `TORRENT_SEED_RATIO` / `TORRENT_SEED_DAYS` (stop when either is
    reached — that is what lets Sonarr/Radarr's *Remove Completed* clean the torrent up).
    Measured here, ratio 1 arrives after about three hours and the day limit has never
    fired, so ratio is what binds and the day is the backstop.
  - **Private trackers seed by time instead.** A public tracker keeps no account of what you
    return, but a private one usually calls a torrent a hit and run unless it seeded a minimum
    period, whatever ratio it reached — and a ratio cap would stop it hours short.
    `configure.sh` therefore reads each indexer's privacy from Prowlarr and sets a *seed time*
    of `TORRENT_PRIVATE_SEED_HOURS` (72 by default) with **no** ratio cap on the private ones,
    through Sonarr's and Radarr's own per-indexer seed criteria. Public indexers get neither
    and fall back on the global pair. Check your tracker's rules before lowering it. A torrent
    may also carry a stray share limit from whatever added it; `heal.sh` puts those back on
    *Use global share limits* — except the private stamp, which it recognises and leaves.
  - Speed limits (Options → Speed) from `TORRENT_MAX_KIB` / `TORRENT_UPLOAD_MAX_KIB` — KiB/s,
    because that is the unit qBittorrent stores, so the number is applied exactly; convert a
    line speed with KiB = Mbit × 125000 ÷ 1024 — so
    the rest of the network keeps bandwidth; `UNRESTRICTED_HOURS` becomes the alternative-
    limit schedule with no limits in that window. 0 = unlimited. The upload cap matters more
    once private trackers are seeding for days: it is what stops a long seed taking the whole
    uplink while a Plex client is streaming from outside the house.
- **Options → Connection**: listening port `6881` (matches `TORRENTING_PORT` and the published
  port). Turn *off* UPnP/NAT-PMP — forward the port on your router by hand if you want it.
  The port is whatever the VPN provider forwards; Gluetun
  sets it, and *Bypass authentication for clients on localhost* is on for that.
- **Categories** (right-click *Categories* in the sidebar → Add category):
  - `tv` → save path `/data/torrents/tv`
  - `movies` → save path `/data/torrents/movies`
  - `music` → save path `/data/torrents/music`

Then in **Sonarr** → Settings → Download Clients → **+** → qBittorrent:

| Field | Value |
|---|---|
| Host | `gluetun` |
| Port | `8081` |
| Username / Password | what you set above |
| Category | `tv` |
| Remove Completed | on (Sonarr removes the torrent once seeding rules are met) |

Test, Save. Same in **Radarr** with category `movies` and in **Lidarr** with category `music`.

### SABnzbd

Your Usenet provider is your own account: either put it in `.env` (`USENET_HOST`,
`USENET_PORT`, `USENET_USERNAME`, `USENET_PASSWORD`, `USENET_CONNECTIONS`) and re-run
`configure.sh`, or add it by hand under Config → Servers. Everything below is done by
`configure.sh`, including the line-speed cap from `USENET_MAX_KIB` (Config → General,
*Maximum line speed*) and, for `UNRESTRICTED_HOURS`, two scheduler entries that lift the cap
at the start of the window and restore it at the end:

- **Config → Folders**:
  - Temporary Download Folder: `/data/usenet/incomplete`
  - Completed Download Folder: `/data/usenet/complete`
- **Config → Categories**: add `tv`, `movies` and `music`, each with a folder of the same name
  (relative to the completed folder, i.e. they land in `/data/usenet/complete/<category>`).
- **Config → General → Security**: copy the **API Key**.

SABnzbd refuses requests whose `Host` header it does not know ("Access denied - Hostname
verification failed"). `compose.yml` sets `hostname: sabnzbd` on the container, and SABnzbd
whitelists its own hostname when it creates its config, so `http://sabnzbd:8080` works from
Sonarr/Radarr on a fresh install. If you brought an existing `config/sabnzbd` along, add it
yourself: Config → Special → `host_whitelist` → append `sabnzbd`, Save, restart SABnzbd.

In **Sonarr** → Settings → Download Clients → **+** → SABnzbd:

| Field | Value |
|---|---|
| Host | `sabnzbd` |
| Port | `8080` |
| API Key | from above |
| Category | `tv` |

Same in **Radarr** with category `movies` and **Lidarr** with category `music`.

Finally, in Sonarr, Radarr and Lidarr → Settings → Download Clients → *Completed Download
Handling*: **Enable** on, **Remove Completed** on. This is what turns a finished download into a
hardlinked, renamed file in `/data/media/…`. `configure.sh` also turns on *Import Extra Files*
(`srt,sub,idx,ass,ssa`), so subtitles shipped with a release are kept next to the video
instead of being discarded and searched for again by Bazarr.

## 12. Connecting Seerr

Seerr is the request front-end: users browse, request, and Seerr hands the request to Sonarr or
Radarr and reports availability from Plex.

`configure.sh` does the whole setup wizard once Plex is claimed: it signs Seerr in with the
Plex owner's token (Plex stores it in its own config after the claim), registers the server as
`http://<LAN_IP>:32400`, enables the libraries, adds Radarr and Sonarr (`http://radarr:7878`,
`http://sonarr:8989`, root folders `/data/media/movies` and `/data/media/tv`, quality profile
`HD-1080p` or the app's first profile) as defaults, sets the application URL to
`http://seerr.<domain>`, sets the region from `PLEX_CERTIFICATION_COUNTRY` with English
metadata, turns on the owner's Plex **watchlist sync** (anything added to the watchlist in
Plex becomes a Seerr request within three minutes) and marks the wizard complete. You then
simply open `http://seerr.<domain>` and *Sign in with Plex* with the same account.

The watchlist sync only works for accounts that signed in to Seerr themselves, because Seerr
polls plex.tv with the token it stored at login. Managed Plex Home users have no e-mail
address, cannot be imported into Seerr and therefore have no watchlist sync; their profiles
do have a watchlist in Plex, it just stays in Plex.

By hand, the same steps are:

1. Open `http://seerr.<domain>` → **Sign in with Plex** (the account that owns the Plex server).
2. Settings → Plex → **Server**: Hostname/IP `plex`, Port `32400`, SSL off; Save, **Sync
   Libraries**, tick *Movies* and *TV Shows*.
3. Settings → Services → **Radarr** → Add: Hostname `radarr`, Port `7878`, API key from
   Radarr, Test, Quality Profile, Root Folder `/data/media/movies`, *Default Server*, Save.
4. Settings → Services → **Sonarr** → Add: hostname `sonarr`, port `8989`, root folder
   `/data/media/tv`.
5. Settings → Users: decide who may request; Plex Home / friends sign in with their own Plex
   accounts.

## 13. Connecting Bazarr

Bazarr downloads subtitles for what Sonarr and Radarr manage. It sees the media at the same
paths they report, so no path mapping is needed.

Steps 1–3 are done by `configure.sh`: profile 1 always mirrors `SUBTITLE_LANGUAGES` in `.env`
(order = preference; change the value and re-run; profiles you add yourself are untouched),
and once Plex is claimed the Plex link is configured too — classic token method with the
server owner's token, `http://<LAN_IP>:32400`, "refresh item" and "set added date" after every
subtitle download, so new subtitles show up in Plex at once. Step 4 is **manual** —
providers need your accounts.

1. Open `http://bazarr.<domain>` → Settings → **Sonarr**: enable, Address `sonarr`, Port `8989`,
   API key from Sonarr, *Test*, Save. Leave *Path Mappings* empty.
2. Settings → **Radarr**: Address `radarr`, Port `7878`, its API key. Same.
3. Settings → **Languages**: the language profile and its defaults for series and movies.
4. Settings → **Providers**: add subtitle providers you have accounts for.
5. Settings → **Subtitles**: *Use embedded subtitles* stays on (default), so a file that
   already carries a language is not searched for it again.

Expected paths inside Bazarr: `/data/media/tv/<Series>/…` and `/data/media/movies/<Movie>/…`.
Subtitle files are written next to the video, which is why Bazarr's `/data/media` mount is
read-write while Plex's is read-only.

## 14. Plex library setup

1. Claim (**manual token, scripted apply**): `configure.sh` asks for a token from
   <https://www.plex.tv/claim>, applies it and clears it again. By hand: put it in `.env` as
   `PLEX_CLAIM=claim-…`, run `docker compose up -d plex` within four minutes, then clear the
   value; it is single-use. Libraries (step 4) are created by `configure.sh` as well.
2. Open `http://plex.<domain>/web`, sign in, name the server.
3. Settings → Network is set by `configure.sh` once the server is claimed: *Custom server
   access URLs* = `http://LAN_IP:32400` (clients on the LAN, a routed site or your VPN connect
   directly), *LAN Networks* = `PLEX_LAN_NETWORKS` (those ranges get full-speed local
   playback instead of remote-stream caps), and, if `PLEX_PUBLIC_PORT` is set, a fixed
   public port under *Remote Access*.
4. Add libraries:
   - **Movies** → folder `/data/media/movies`
   - **TV Shows** → folder `/data/media/tv`
   - **Music** → folder `/data/media/music` (Plex Music agent; Plexamp plays it)
   `configure.sh` also turns on *Scan my library automatically*, *Run a partial scan when
   changes are detected* and a daily scheduled scan (Settings → Library) — without the
   partial-scan setting Plex answers Sonarr's and Radarr's import-time refresh requests with
   200 and scans nothing; the daily full scan is only a safety net, new media arrives through
   the watcher and the arr hooks within seconds. The Plex connection in Sonarr/Radarr (Settings → Connect) is added
   by `configure.sh` as well.
   Each library's *Certification Country* is set from `PLEX_CERTIFICATION_COUNTRY` in `.env`
   (age ratings shown in your country's system).
5. **Hardware transcoding** (Plex Pass): `setup.sh` enables the matching `COMPOSE_FILE`
   override when it finds a GPU (or uncomment the line in `.env` and `docker compose up -d
   plex`); `configure.sh` then switches Plex's hardware decoding and encoding on as soon as
   the container can see the device. On Intel/AMD, `RENDER_GID`/`VIDEO_GID` in `.env` must
   match `getent group render video` on the host. Verify with `docker compose exec plex ls -l
   /dev/dri` (files present, not "No such file") and a playing stream showing *(hw)* in the
   dashboard.

### Switched off by `configure.sh`

- **Online Media Sources** (plex.tv account setting, Settings → Online Media Sources):
  *Movies & Shows on Plex*, *Live TV* channels and the retired News, Podcasts and Web Shows
  are set to *Disabled*. Every client home screen otherwise fetches those rows from the
  internet on each visit, which is most of what makes the TV apps feel slow. Disabling them on
  the admin account covers the managed Home users as well. *Sync my watch state* stays on;
  the watchlist and Continue Watching need it.
- **Debug logging** (Settings → General): rotates a 10 MB log every few minutes on a busy
  server. Turn it back on in Plex only while diagnosing something.
- **Crash reports**, **Allow media deletion** (removals go through Sonarr/Radarr, which keep
  their own databases in step) and **ad-marker analysis** (only DVR recordings contain ad
  breaks, and the stack makes none).

Relay, cinema trailers, intro and credits markers, chapter thumbnails, push notifications
and local discovery are left as Plex ships them.

### Remote access

Plex's *Remote Access* status means "reachable from the internet".

- **Default — public port** (`PLEX_PUBLIC_PORT=32400`): forward TCP 32400 on your internet
  router to `LAN_IP:32400`; `configure.sh` sets the matching manual port in Plex and *Remote
  Access* turns green for any network. Plex account authentication is then the only barrier —
  this is the one service in the stack designed for that, so keep it updated
  (`docker compose pull`) and do not forward anything else.
- **Opt-out — VPN only** (`PLEX_PUBLIC_PORT` empty): nothing is exposed. Devices on Tailscale
  (or a site routed to this LAN) still reach `http://LAN_IP:32400` directly because the server
  advertises that address. Plex's status page then says "not available outside" — correct
  and intended; clients without the VPN cannot connect.

Either way, `PLEX_LAN_NETWORKS` (this LAN, other sites' LANs, the VPN range — `setup.sh`
asks) decides who gets full-speed local playback instead of remote-stream caps.

Plex runs on the **host network** (`network_mode: host`), unlike every other service. Behind a
published port Docker's userland proxy hands Plex every connection from the bridge address
(`172.18.0.1`), so Plex cannot tell a TV in the living room from a viewer on the internet and
treats them all as remote: remote bandwidth caps and the client's remote quality apply to
everyone, and `PLEX_LAN_NETWORKS` never matches. On the host network Plex sees real client
addresses and the local/remote distinction works; it listens on 32400 directly (plus its GDM and
DLNA discovery ports, so LAN auto-discovery works too) and the other containers reach it at
`http://<LAN_IP>:32400` rather than by a service name — `configure.sh` fills that in. The firewall note in section [Plex library setup](#14-plex-library-setup) still applies: 32400/tcp must be allowed.

Two more things decide whether a client on the LAN really connects directly:

- **Advertised addresses.** On the host network Plex would also publish the Docker bridge
  addresses (`172.17.0.1`, `172.18.0.1`) as local connections, and every client tries and
  times out on those first. `configure.sh` pins Plex's *preferred network interface* to the
  one that carries `LAN_IP`, so only the real address is published.
- **DNS rebind protection.** Plex clients prefer the secure connection
  `https://<ip-dashed>.<hash>.plex.direct:32400`, a public name that resolves to the server's
  *private* address on purpose (it is how a private IP gets a valid certificate). Resolvers with
  rebind protection, such as Unbound with `private-address:` or Pi-hole's rebind setting,
  strip that answer; the client then fails the direct connection and quietly falls back to
  Plex's internet relay, which shows as slow menus and posters on the LAN and `127.0.0.1` as the
  player address in the server's sessions. Whitelist the domain: Unbound `private-domain:
  "plex.direct"`, dnsmasq `rebind-domain-ok=/plex.direct/`. Check from any LAN device with
  `dig <name>.plex.direct` — an empty answer means the resolver is stripping it.

### Who sees which library

`users.json` — the same file Jellyfin's accounts come from (section [Jellyfin alongside Plex](#17-jellyfin-alongside-plex)) — also
decides what each **Plex Home** user may see, under one rule: films and series for
everyone, music for the adults. Without that the two servers disagree, and a child who
cannot reach music on one of them reaches it on the other.

What `configure.sh` can and cannot do here is worth knowing, because it is split:

- **Library access: managed.** Each Home user's sharing record is written through
  `PUT /api/servers/<machine>/shared_servers/<id>`. A user with no record sees every
  library, so a record is created only when something has to be withheld — which means
  deleting it by hand is what restores the default. The ids in that request are
  **plex.tv's own nine-digit section ids**, not the server's local `1`, `2`, `3`;
  sending the local keys matches nothing and silently unshares everything.
- **Age restriction: not managed.** Plex exposes no endpoint for a Home user's
  restriction profile — `/api/v2/home/users/<id>` answers 405 to every method — so it
  stays a manual setting under *Settings → Users & Sharing*. Each run prints the profile
  Plex holds beside the `rating` in `users.json` so a disagreement is visible rather
  than silent. Jellyfin's side of the same rating *is* applied, so this is the one place
  where the two servers can drift apart.

The admin account is skipped: it always sees everything.

## 15. Music (Lidarr)

Lidarr is Sonarr/Radarr for music: it monitors artists and albums (MusicBrainz metadata),
searches through the same Prowlarr indexers, downloads through the same SABnzbd/qBittorrent
(category `music`) and imports into `/data/media/music/<Artist>/<Album> (Year)/…` with
hardlinks. Plex gets a **Music** library on that folder (Plex Music agent); Plexamp is the
player to use with it.

`configure.sh` wires all of it: the shared login, root folder `/data/media/music` (default
quality profile *Standard*, metadata profile *Standard*), both download clients, renaming
(Lidarr's default track format), the Plex library-refresh hook, the Prowlarr application and
the dashboard tile. Lidarr thinks in **albums**: requesting a track means getting its album.

Manual, as everywhere: indexers come from Prowlarr, so nothing to add here — but music
availability on Usenet/torrent indexers is thinner than film/TV.

## 16. Dubbed audio (the original language plus one more)

Subtitles (section [Connecting Bazarr](#13-connecting-bazarr)) are useless to a child who cannot read yet: the *audio* has to be
in their language. What that needs is one file carrying both languages, not a second copy of the
film — so this adds no library, no root folder and no second request. It is optional and **off as
shipped**: with `DUB_LANGUAGE` empty nothing here exists. Set it to an ISO 639-1 code (`nl`, `de`,
`fr`, …) and every quality profile in **Radarr and Sonarr** starts preferring a release that
carries the original audio *and* that language.

This follows TRaSH's own `[French MULTi.VO]` profiles, which exist for French and German and for
no other language — the guides ship no Dutch language format at all. So the first two formats
below are this stack's own and everything after them is the guides':

- two custom formats — *Dutch Audio*, matching the language the app parses from the release, and
  *Dutch Dub (title)*, matching the spellings its parser does not know (`NLD`, `NL Gesproken`,
  `Nagesynchroniseerd`). Both deliberately avoid the bare word "Dutch", which the first format
  already covers and which would otherwise match a film *called* "The Dutch Job".

  How much each format does depends on the language, and the split was measured against
  `/api/v3/parse` rather than guessed. The parser resolves most tags on its own — `GERMAN`,
  `GER`, `German.DL`, `FRENCH`, `TRUEFRENCH`, `VFF`, `VF`, `VFQ`, `SPANISH`, `Castellano`,
  `ITA`, `POLISH`, `PLDUB`, `Dubbing.PL`, `CZ.Dabing`, `HUN`, `RUS`, `JAPANESE` — so for those
  languages the language format alone is enough and no title pattern is created. Five codes get
  one because their common tags come back as *Unknown*: `nl`, `pt` (`PT-BR`, `DUBLADO`), `sv`
  (`SWE`, `Svenskt Tal`), `tr` (`DUBLAJ`, `TR.DUB`) and `cs` (`CZECH`, `DABING`). Polish
  *Lektor* is left out on purpose — that is one voice read over the original audio, not a dub,
  and a child needs the dub.

  A regional dub is a language of its own in both apps, so `pt` also accepts
  *Portuguese (Brazil)* and `es` also accepts *Spanish (Latino)*; without that a Brazilian or
  Latin-American dub would never match;
- *Language: Not Original* at **−10000**, the guides' format rebuilt here because Recyclarr syncs
  only what a profile template asks for and none of the templates this stack uses asks for it. It
  refuses any release that dropped the original audio — a Dutch-only dub included, which is the
  point: the file has to work for everyone in the house;
- the two dub formats at **+500**, with `minFormatScore` left at the guides' `0`. A preference,
  never a requirement: a film with no dub available downloads exactly as it would without this
  section, instead of sitting in the wanted list forever;
- Bluray folded into the `WEB` group at the same resolution, so `HD Bluray + WEB` ranks
  `[Bluray-1080p | WEBDL-1080p | WEBRip-1080p]` as one step, `Bluray-720p` below it. Quality rank
  beats custom-format score in both apps, so without the merge +500 could never pick a
  multi-language WEB-DL over an English-only Bluray — and the multi-language masters are streaming
  rips. Remux stays above the group. The guides merge for the same reason.

`minUpgradeFormatScore` is raised to **701** in the same pass: 500 for the dub plus the 200-point
spread across the guides' release-group tiers. Nothing already on disk is re-grabbed merely to
gain a second audio track, while a file sitting on a −10000 penalty still upgrades, because that
gain is far larger. To pull the dub onto a film you already have, search that film by hand.

**In Plex**: set the children's profile *Audio language* to Nederlands (Settings → Account →
Language). A `MULTi` file then plays Dutch for them and the original for you; profiles are per
user, so the two never interfere.

Two limits worth knowing: a dub cannot be added afterwards the way Bazarr adds subtitles — it is
a matter of finding the right release, or nothing; and dubs exist mostly for children's films and
animation, which is exactly the case this is for, but far from every title has one. The word list
in `configure.sh` (`dub_title_regex`) holds patterns for Dutch only; other languages use the
parser's own language detection until someone adds patterns for them.

---

## 17. Jellyfin alongside Plex

Jellyfin runs next to Plex as a second media server on the **same read-only library**
(`/data/media`, identical paths). Requests go through Seerr on Plex (section [Connecting Seerr](#12-connecting-seerr)); both
servers stay. It is part of the default stack; remove it again with
`docker compose rm -sf jellyfin` and `rm -r config/jellyfin`.

What `configure.sh` sets up, all idempotent:

- **Setup wizard and login**: the administrator is `WEBUI_USERNAME` / `WEBUI_PASSWORD` from
  `.env`, like the other apps. `--set-login` changes it here too (Jellyfin's own forgot-password
  flow, whose PIN file lands in `config/jellyfin/`, is used to reset a password that no longer
  matches). One user for now; add more under Dashboard > Users, and give a child only the
  libraries it should see (Jellyfin restricts library access per user, no "Home" needed).
- **Administrator defaults**, applied once: preferred subtitle language from
  `SUBTITLE_LANGUAGES`, missing episodes visible, dark dashboard, next-episode overlay and
  episode stills in Next Up. A marker in the display preferences stops them from being
  re-applied, so later changes in the UI stay.
- **Family accounts** from `users.json` (copy `users.example.json`; the file
  is gitignored because it names your family). One object per user: name, role (`admin`,
  `adult`, `child`), the highest content rating a child may watch, the switches `channels`, `hidden`, `nopass`
  and `rich`, preferred audio language and preferred subtitle language. **Films and series are
  the same for every account**, in Jellyfin as in Plex, and the parental rating decides what
  appears inside them — a hidden library makes a film invisible even when its rating allows it,
  and the two mechanisms disagreeing is how a child ends up with an empty home screen. Music is
  the exception: tracks carry no age rating at all, so it is withheld from a child by library
  rather than by rating. The rating is on the scale of the metadata country, so with
  `PLEX_CERTIFICATION_COUNTRY=NL` it is Kijkwijzer — `0` (AL), 6, 9, 12, 14, 16, 18 — and it is a
  rating rather than an age: a five-year-old is `0`, not `5`. Ratings from other systems are
  mapped onto the same scale (`PG-13` is 13, `R` is 17), which matters because a library
  usually holds both. There is no `livetv` switch because the stack has no live TV — no
  tuner, no listing provider and no plugin that publishes channels. Children get
  unrated items blocked and no SyncPlay; adults and children may not delete media or
  control other people's players. An audio preference makes that track play whenever the
  film has it — which is how one multi-language file serves a child in Dutch and everyone
  else in the original (section [Dubbed audio](#16-dubbed-audio-the-original-language-plus-one-more)); a subtitle preference turns subtitles on
  always. Missing users are created without a password (set one in Dashboard > Users);
  rights and preferences are re-applied on every run, so edit them in the file, not in the
  UI. Users that are not in the file are never touched, let alone deleted.
- **Libraries**: Movies, TV Shows and Music — the same folders as Plex, metadata in English.
- **Hardware transcoding**: VA-API on `/dev/dri/renderD128` when `compose.hwaccel.amd.yml`
  is active (the override adds Jellyfin next to Plex). No subscription needed. HDR tone
  mapping stays off: it needs an OpenCL runtime the image does not ship for AMD.
- **Reverse proxy**: the Docker bridge gateway is trusted as a proxy, so the dashboard and the
  logs show real client addresses behind Caddy. Add the `jellyfin` site from
  `caddy/Caddyfile.example` and the DNS record like for any other app.

What does **not** carry over: watch state and "continue watching" are per server, and Seerr
signs in through Plex (section [Connecting Seerr](#12-connecting-seerr)) — one Seerr instance serves one media server. Bazarr
refreshes both servers after a subtitle download, Sonarr/Radarr/Lidarr refresh both after an
import, so requests made through Seerr appear in Jellyfin too.
## 18. Hardlink verification

A hardlink is the same inode reachable from two paths. Same inode number, link count 2.

From the host, after the first import:

```bash
# Pick an imported file and its original download.
ls -li data/media/tv/*/*/* | head -3
ls -li data/torrents/tv/*/* | head -3
```

The first column (inode) must match between the two, and the third column (link count) is
`2` or more. Or ask the kernel directly:

```bash
find data -samefile "data/media/tv/Some Show/Season 01/Some Show - S01E01.mkv"
```

Two paths printed = hardlinked. One path = it was copied.

Synthetic test that does not need real media (run inside the container as `abc`, the user
Sonarr actually runs as — a plain `exec` would run as root and prove nothing about permissions):

```bash
docker compose exec -u abc sonarr sh -c '
  echo test > /data/torrents/tv/hl-test.bin &&
  ln /data/torrents/tv/hl-test.bin /data/media/tv/hl-test.bin &&
  stat -c "%i %h %n" /data/torrents/tv/hl-test.bin /data/media/tv/hl-test.bin &&
  rm /data/torrents/tv/hl-test.bin /data/media/tv/hl-test.bin'
```

Expected: two lines with the same inode and a link count of `2`. An `Invalid cross-device
link` error means the two paths are on different filesystems or different Docker mounts —
see section [Directory structure](#2-directory-structure).

For the whole library rather than one file, `./scripts/audit-space.sh` sorts the download
trees into the three cases that matter: data **shared** with the library through hardlinks,
which costs nothing; data **orphaned** because the library copy was deleted by an upgrade or
by the release guard while the download kept its own name, which is real space nobody owns;
and what the download client still holds. It ends with how much `heal.sh` will reclaim on its
next pass, given `HEAL_ORPHAN_HOURS` and `HEAL_ORPHAN_KEEP` (section [Torrents through a VPN](#19-torrents-through-a-vpn-gluetun)). Summing
`data/media` and `data/torrents` by hand overstates the total by exactly the shared amount,
which is why the script reports a deduplicated figure too.

## 19. Torrents through a VPN (Gluetun)

**Required, not optional.** The torrent **and indexer** traffic goes through a VPN: qBittorrent's
downloads and uploads, every search the *arr apps make — they are all proxied by Prowlarr, whose
indexers they point at rather than the tracker — and the Cloudflare challenges FlareSolverr
solves on Prowlarr's behalf. Plex, the *arr apps' own metadata lookups, Seerr and SABnzbd keep
using your normal connection.

Without `VPN_WIREGUARD_PRIVATE_KEY` the stack does not come up: `setup.sh` refuses to finish,
and qBittorrent, Prowlarr and FlareSolverr wait on a Gluetun that never turns healthy. That is
deliberate — a stack that quietly falls back to your own address is the failure this prevents.
Plex, Jellyfin, Seerr and the dashboard are unaffected either way; they never enter the namespace.

How it works: `compose.yml` includes a **Gluetun** container that owns a WireGuard tunnel and
a firewall that drops everything not going through it (a kill switch). qBittorrent, Prowlarr and
FlareSolverr run in Gluetun's network namespace (`network_mode: service:gluetun`), so
none of them has a route to the internet other than the tunnel — if the VPN drops they stop;
they never leak. Their **DNS** goes through it too: inside the namespace the resolver is
Gluetun's own, over TLS, so the tracker hostnames being looked up are not visible on your own
connection either. Gluetun also asks the provider for a **forwarded port** and, on every
(re)connection, tells qBittorrent to listen on it, so incoming peers keep working without any
port on your router.

Why Prowlarr belongs in the tunnel: it is the single point every indexer query passes through,
so leaving it outside publishes your address, and the searches made from it, to every tracker.
**SABnzbd stays out** on purpose — Usenet has no swarm, the provider knows the account whatever
address it arrives from, transfers are TLS, and `USENET_MAX_KIB` worth of downloads would have
to share the tunnel for no privacy gained. Usenet *searching* is covered regardless, because
NZBgeek is proxied by Prowlarr like every other indexer.

Written for **Proton VPN** (Plus plan for port forwarding). Set-up:

1. In your Proton account → *WireGuard configuration*: create one for a Linux router/other
   platform, tick **NAT-PMP (Port Forwarding)** under *VPN options*, generate, and copy the
   `PrivateKey` line. One key works on every server; you never need the rest of the file.
2. In `.env`: `VPN_WIREGUARD_PRIVATE_KEY=<that key>` and `VPN_SERVER_COUNTRIES=Netherlands` (the
   nearest country is the fastest; Gluetun picks a P2P server there on each start). `setup.sh`
   asks for both on a fresh install and will not finish without the key. `COMPOSE_FILE` needs
   nothing for the VPN — it only ever names a hardware-acceleration override.
3. `docker compose up -d && ./configure.sh`. The **VPN** step prints the exit address and
   checks that the forwarded port equals qBittorrent's listening port — on the very first
   start it sets it itself, because Gluetun's own hand-off is refused until `configure.sh`
   has allowed localhost past the login; from then on Gluetun does it on every reconnection.
   Changing that port restarts qBittorrent, because a port changed at runtime leaves its DHT
   with zero nodes. After a restart give DHT **three to five minutes** to bootstrap: until it
   has a few hundred nodes a torrent only sees the peers its tracker hands out, which on a
   quiet tracker looks like a broken download.

What this arrangement means day to day:

- The *arr apps reach qBittorrent **and Prowlarr** as `gluetun` (a container inside another's
  namespace has no name of its own), and Prowlarr reaches FlareSolverr there too;
  `configure.sh` re-points the download clients, the Prowlarr applications, the FlareSolverr
  indexer proxy and the dashboard tiles on every run. `http://qbittorrent.<domain>` and
  `http://prowlarr.<domain>` keep working — Caddy talks to the same host ports, which Gluetun
  now publishes.
- Prowlarr writes its own address into every indexer it pushes to Sonarr, Radarr and Lidarr, and
  only re-pushes when its definition changes. `configure.sh` therefore asks Prowlarr for a forced
  application sync after the address moves; without it the apps would keep searching a name that
  no longer resolves until the next scheduled sync, up to six hours later.
- `6881` is not published and the router forward for it is unnecessary; incoming peers arrive
  on the provider's forwarded port through the tunnel.
- If Gluetun alone restarts (crash, manual restart), qBittorrent's network goes with it: it
  stays in the old, dead namespace, where its own UI still answers, so Docker kept calling it
  healthy. The override's health check therefore also probes Gluetun's control API through the
  shared namespace, and `./heal.sh` (installed as a two-minute timer by `./heal.sh install`)
  restarts whatever is unhealthy, Gluetun before its dependants. Measured: back within about
  two minutes without anyone touching it. `update.sh` recreates both, so upgrades need nothing.
- The image's `TORRENTING_PORT` is switched off here: the provider decides the port, and
  qBittorrent's own config must survive a restart.
- `.env` holds the private key (mode 600, gitignored) like every other credential.

Check it yourself: `docker compose exec qbittorrent curl -s https://ipinfo.io/ip` must print
the VPN's address, not yours — and so must the same command against `prowlarr` and
`flaresolverr`, while `sabnzbd` and `sonarr` must still print your own. `docker compose exec
prowlarr cat /etc/resolv.conf` must show `nameserver 127.0.0.1`, Gluetun's resolver, rather than
Docker's `127.0.0.11`. `docker compose stop gluetun` and the ip command must fail.
`docker compose logs gluetun` shows the server, the forwarded port and qBittorrent's answer.
A healthy state is `dht_nodes` in the hundreds and `connection_status: connected` in
`http://qbittorrent.<domain>/api/v2/transfer/info`; "firewalled" there means no peer has
connected *in* yet, which fixes itself once the forwarded port and the listening port agree.

Other providers Gluetun supports (PIA, AirVPN, Windscribe, Mullvad — the last without port
forwarding, so seeding is limited to peers you connect to) need different `VPN_*` values in
`compose.yml`'s Gluetun service; see Gluetun's wiki. "No logs" is a claim every provider makes — prefer one
with an independent audit or a public real-world test of it.

## 20. Updating containers

Images are tagged `latest` in `.env`, but nothing updates itself behind your back. Updates
run through `update.sh`, by hand or on a weekly timer:

```bash
./update.sh            # pull; if anything changed: snapshot config, recreate, verify, prune
./update.sh install    # systemd user timer, UPDATE_DAY at UPDATE_TIME (+ up to 15 min jitter)
./update.sh status     # last result, next run, recent log, snapshots
```

What one run does, in order: `docker compose pull`; if no container would change, stop
there. Otherwise record the running image IDs (`backups/images-<date>.txt`), stop the stack,
snapshot `config/` and `.env` to `backups/config-<date>.tar.gz` (Plex's cache excluded),
`docker compose up -d`, wait until every health check is green, prune superseded images and
keep the last four snapshots. If something stays unhealthy, the run reports `FAILED` with the
snapshot to restore and the previous image IDs to pin — the previous images are still on disk
until a later successful run prunes them.

Why this rather than pinned tags or a container auto-updater:

- LinuxServer.io tags look like `4.0.15.2941-ls290`; pinning eight of them means editing
  eight values per upgrade, and a stale pin quietly misses security fixes.
- Auto-updaters (Watchtower and friends) restart apps the moment an image lands, mid-import or
  mid-database-migration, and keep no backup. That is the most common way people lose a
  Sonarr database. `update.sh` restarts at a quiet hour with a snapshot taken first.

The timer is a *user* unit; `install` also enables lingering (`loginctl enable-linger`) so it
fires when you are not logged in — if that needs root it tells you the one command.

**Rolling back:** `docker compose stop`, restore the snapshot (`tar -xzf
backups/config-<date>.tar.gz`), take the previous tag from `backups/images-<date>.txt`
(or the image's Packages page on GitHub), set e.g. `SONARR_TAG=4.0.14.2938-ls287` in `.env`,
then `docker compose up -d`.

Plex is set to `VERSION=docker` so the container image decides the Plex version; Plex's own
in-app updater is disabled. Plex updates arrive with the rest.

## 21. Backing up configuration

Everything worth keeping is in `config/`: databases, API keys, indexer settings, Plex metadata.
`data/` is your media and is not covered here. `update.sh` already takes a snapshot before
every update (`backups/`, last four kept); the manual version of the same thing:

```bash
docker compose stop                   # SQLite databases must not be written during the copy
tar -C . -czf "../media-stack-config-$(date +%F).tar.gz" config .env
docker compose start
```

`config/plex` grows large (metadata, thumbnails). To keep backups small you can exclude
`config/plex/Library/Application Support/Plex Media Server/Cache` — it is rebuilt automatically.

Restore: stop the stack, extract the archive over the directory, fix ownership (section [Permissions setup](#4-permissions-setup)),
`docker compose up -d`.

Test a restore once. A backup that has never been restored is a hope, not a backup.

## 22. Moving to another server

Everything the stack *is* lives in three places, so a move is a copy, not a rebuild:

| What | Where | Moves how |
|---|---|---|
| Definition | this repository | `git clone` |
| Host values and secrets | `.env` | `setup.sh` writes a new one; `migrate.sh` carries the stack-level values over |
| Application state | `config/` | rsync (Plex's cache excluded — it is rebuilt) |
| Media and downloads | `data/` | rsync, hardlinks and sparse files preserved |

Plex keeps its identity (the server id lives in `config/plex`), so clients, shares and Seerr
reconnect without re-claiming; the *arr apps keep their databases and API keys, so every
link between them survives.

On the **new** server, with SSH key access to the old one:

```bash
git clone <this-repo> media-stack && cd media-stack
./setup.sh                                   # this host's ids, IP, GPU; Enter past the questions,
                                             # migrate.sh carries the old answers over
./migrate.sh user@oldhost:/path/media-stack --pre   # copy while the old stack keeps running
#   ... hours later, when the bulk copy is done:
./migrate.sh user@oldhost:/path/media-stack         # stop old, copy the delta, start here
```

`migrate.sh` checks free space first (real usage, so preallocated downloads do not count
double), stops the old stack only in the final pass (consistent databases), carries the
stack-level `.env` values (login, domain, providers, seeding limits, VPN, Plex options — not
the host-specific ones; `COMPOSE_FILE` names only a GPU override and is not carried), starts the stack and runs `configure.sh`. Re-running any pass is safe.
The old stack is left stopped, never deleted.

What it cannot do for you, printed at the end: router forwards (32400, 6881) to the new IP,
the DNS records (or the reverse proxy's upstreams) to the new IP, the new host's firewall, the
timers (`./update.sh install`, `./heal.sh install`, `./watch.sh install`, `./news.sh install`,
`./missing.sh install`, and `./mover.sh install` if the archive tier is in use), and finally
`docker compose down` on the old
host once you are happy.

Two things to get right *before* the move: keep `data/` on one filesystem on the new server
(hardlinks do not cross mounts — section [Directory structure](#2-directory-structure)), and use the same `PUID`/`PGID` or expect one
`chown -R` of `config/` and `data/` afterwards. Different GPU vendor? `setup.sh` picks the
matching transcoding override; nothing to migrate.

## 23. Alerts (ntfy)

Nothing in this stack tells you anything unless you ask it. An indexer that stops answering, a
download client that cannot be reached, an import that needs a decision, a film that finished and is
sitting there ready to play — all of it stays inside an app until someone looks. These alerts are
the part that reaches out.

`configure.sh` runs an **ntfy** container and points the apps at one topic. Self-hosted on purpose:
the alert stream says what is being downloaded and when, which is exactly what the VPN work keeps
off other people's infrastructure.

### Choosing what you get told

**What you get told is yours to choose.** `NTFY_EVENTS` in `.env` takes a comma-separated list:

| Value | Fires when |
|---|---|
| `ready` | a film or episode finished importing and can be played now |
| `failed` | a download failed and nothing was left to try |
| `manual` | a download is stuck and needs a human |
| `health` | an app reports a problem, and again when it recovers — including Plex remote access going down |
| `disk` | free space crossed `DISK_WARN_GIB`, or the brakes went on or off |
| `grab` | a download started |
| `upgrade` | a better version replaced a file you already had |

The default is `ready,failed,manual,health` — the things worth looking at your phone for. `grab` and
`upgrade` are off because an alert on every step of every download is one nobody reads, and the
failures drown in it. An empty `NTFY_EVENTS` leaves the connections in place but silent; an empty
`NTFY_TOPIC` means no alerts are configured anywhere.

Several of the `health` and `disk` alerts do not come from an app at all — `watch.sh` raises them
itself, because nothing else would. The Spotweb one is described in README "Spotweb, the Spotnet
indexer". The other is **Plex remote access**: playing from outside your LAN depends on
`PLEX_PUBLIC_PORT` still being forwarded on your router, and `configure.sh` turns Plex's own Relay
fallback off, because the relay is capped hard enough to be reported as a playback problem. A direct
connection is not capped — but a forward that stops working then fails outright rather than
degrading to a slow stream, and the first sign would be someone abroad unable to play anything. So
`heal.sh` asks Plex what plex.tv made of its port mapping, and alerts once when the answer stops
being `mapped`, once more when it recovers. The verdict has to hold for three runs first, since
`waiting` is normal while Plex starts. The check does nothing when `PLEX_PUBLIC_PORT` is empty,
which is how you say you do not want remote access at all.

`NTFY_EVENT_APPS` decides which apps send `ready`, `failed`, `grab` and `upgrade`, and defaults to
`sonarr,radarr`. `health` and `manual` always come from every app, so one left out of the list can
still say that it is broken. Music is not in the default because Lidarr imports per track.

### How loudly

`NTFY_PRIORITY` sets how loudly, per kind of alert, on ntfy's scale: 1 min, 2 low, 3 default, 4
high, 5 max. Only 4 and 5 break through a phone's do-not-disturb; 1 and 2 arrive without a sound.
Use the same names as `NTFY_EVENTS`; anything not named gets 4, and a bare number instead of a list
sets everything to that level.

```
NTFY_PRIORITY=ready:2,failed:5,manual:4,health:3
```

An app's ntfy connection carries **one** priority for everything it sends, so `configure.sh` groups
the wanted events by level and creates one connection per distinct level, named `ntfy-p<level>`.
With the default above, Sonarr ends up with three:

| Connection | Priority | Fires on |
|---|---|---|
| `ntfy-p2` | 2 | `onImportComplete` |
| `ntfy-p3` | 3 | `onHealthIssue`, `onHealthRestored` |
| `ntfy-p4` | 4 | `onManualInteractionRequired` |

Give two kinds the same level and they share a connection; change a level and the connections are
repartitioned, with the spares removed. `configure.sh` owns every connection named `ntfy` or
`ntfy-p<1-5>` and nothing else, so the Plex, Jellyfin and Release guard connections beside them are
left alone. Emptying `NTFY_EVENTS` removes them all and leaves the app silent.

**No emoji.** ntfy renders each entry in a notification's `tags` field as an emoji, so the stack
sends none and clears any that are already set. Alerts arrive as plain title and text.

### Why the names are not the apps' names

**The names are app-neutral because the apps are not.** The same "it is playable now" event is
`onImportComplete` in Sonarr, `onDownload` in Radarr and `onReleaseImport` in Lidarr, and Radarr has
no `onImportComplete` at all. Sonarr has both, and they are not the same thing: `onDownload` is
"On File Import" and fires once per episode, while `onImportComplete` fires once per download. The
stack picks the second, so a 24-episode season pack is **one** alert rather than twenty-four.
`configure.sh` owns the whole set of toggles on the connection, so one switched on by hand in a web
UI is switched back off on the next run.

**`failed` does not come from Sonarr or Radarr, because it cannot.** Neither has a failure event of
any kind — not on the ntfy connection, not on any other notification type they support.
`watch.sh` reads their history instead and pushes those alerts itself, which is why a failure
arrives within a `WATCH_INTERVAL` rather than instantly.

It also means something more useful than a raw history feed would give you. A single film routinely
produces thirty `downloadFailed` rows in twenty minutes, because the release guard marks every fake
it rejects as failed and the search moves on to the next candidate — that is the guard working, not
a failure. So `watch.sh` reports the **item**, not the release, and only once the app has stopped
trying: no file, and nothing for it left in the queue. Anything still downloading stays pending and
is judged again on the next run. Its high-water mark lives in `backups/failed-alerts.json`, and the
first run only records it, so turning alerts on does not replay every failure the stack has ever had.

`disk` comes from `heal.sh` for the same reason, and carries the free-space warning as well as
the brakes engaging and releasing — see README "Keeping the disk from filling". Dropping `disk`
from `NTFY_EVENTS` silences those messages and leaves the brakes on.

Lidarr is the exception that proves the point: it is the only one of the four with real
`onDownloadFailure` and `onImportFailure` events, so when it is in `NTFY_EVENT_APPS` its failures
come straight from the app.

Bazarr reaches the same topic through Apprise and has no per-event granularity at all — a flat list
of provider URLs with one on/off switch each — so `NTFY_EVENTS` does not reach it. Prowlarr only has
four events in total and never downloads anything itself, so in practice it contributes health.

### The server, and getting it on your phone

**Nobody reads or writes without an account.** The server runs with
`NTFY_AUTH_DEFAULT_ACCESS=deny-all`, and `configure.sh` creates the `NTFY_USER` account on its first
run, generates its password into `.env`, and grants it read-write on the topic. Anonymous publishing
and reading both return `403`.

That is what lets the topic — `NTFY_TOPIC`, `media-stack` by default — be named rather than random. Without accounts the
topic name is the only protection, which forces it to be unguessable; with them the name can say what
it is. The port binds to `APP_BIND` as well, so only the reverse proxy and the LAN reach it.

**Subscribing**: install the ntfy app, add server `http://ntfy.<domain>`, the topic, and the login
from `NTFY_USER` / `NTFY_PASSWORD`. On Android use the F-Droid build, which talks to your own server
without Firebase. iOS cannot do instant delivery from a self-hosted server without relaying a
wake-up through ntfy.sh, so it is not the right fit here.

**Where alerts reach you**: anywhere the phone can reach the server — the LAN, or the tailnet, since
this host routes its LAN over Tailscale. Off both, nothing arrives at that moment, but nothing is
lost either: the server keeps messages for 72 hours and delivers what was missed on reconnect. If
you want them live while away, turn on always-on Tailscale rather than exposing the port.

The dashboard carries an **Alerts** tile that links to the ntfy web interface, where the same
messages are readable without a phone. It shows up or down rather than a message count: ntfy serves
its message feed as newline-delimited JSON, which the dashboard's generic API widget cannot parse,
and a widget that silently shows nothing would be worse than none.

## 24. Keeping the disk from filling

A full filesystem does not degrade gracefully. Journald, Docker and every container fail at the same
time, and on this machine one filesystem carries the OS, the Docker state, `CONFIG_ROOT` and all of
`DATA_ROOT` — so "the disk filled up" and "the server stopped working" are the same sentence. None of
the apps guard against it on their own: **neither Sonarr nor Radarr has a disk-space health check**,
and qBittorrent has no free-space setting at all.

So there are brakes, and they all come off one number in `.env`:

```
DISK_FLOOR_GIB=25
```

Below that line, three things happen, in the three places that can each stop a different thing:

| Component | What it does | How |
|---|---|---|
| SABnzbd | pauses the queue, resumes by itself | `download_free` + `fulldisk_autoresume`, enforced **continuously** by SABnzbd |
| Sonarr / Radarr / Lidarr | a token 1 GiB floor only — an import costs no space here, and is what frees the download folder | `minimumFreeSpaceWhenImporting` |
| qBittorrent | downloading torrents are stopped | **polled** by `heal.sh` — it has no setting of its own |

`configure.sh` sets the first two. The third is `heal.sh`, on its timer.

**Why torrents actually stop above the floor.** A poll is not a guarantee. At `TORRENT_MAX_KIB` for
one `HEAL_INTERVAL`, a download can take several more GiB between two runs — with the defaults,
about 3 GiB — so a check that waited for the floor itself would look, see space, and find none next
time. `heal.sh` therefore stops torrents at **floor + headroom**, where the headroom is derived from
the rate cap and the timer interval, with a 2 GiB minimum. Change either and the headroom follows.
The floor is what holds; the brake point is how it is held.

This is also why SABnzbd is given the floor directly and trusted with it. It is the faster of the two
clients by some margin, and it polices itself continuously, so it needs no headroom. Only torrents
are left to the poll.

**Seeding is never stopped.** Only torrents in a downloading state are touched. A seeding torrent
costs no space, and stopping it would cost ratio on exactly the private trackers
`TORRENT_PRIVATE_SEED_HOURS` exists to protect.

**It only starts what it stopped.** The hashes it stopped are recorded in
`backups/disk-alerts.json`, and only those are started again when space recovers — a torrent you
stopped by hand stays stopped. Recovery needs free space back above the brake point plus 25%, so a
finishing download cannot flap the whole queue.

**Turning off the alerts does not turn off the brakes.** `NTFY_EVENTS` decides what gets *said*.
Drop `disk` from it and the brakes still work, silently, with the reasons still in the journal. Only
`DISK_FLOOR_GIB=0` takes the brakes off.

### Knowing before it happens

`DISK_WARN_GIB` is the other half, and the one you actually want:

```
DISK_WARN_GIB=75
```

It warns once on the way down and once back above, with a 10% margin so it cannot chatter, and the
message names how much the next orphan sweep would reclaim — the difference between "act now" and
"this sorts itself out". It arrives through ntfy like everything else; see
README "Alerts (ntfy)" for the levels.

The dashboard's disk tile shows the same filesystem, but Homepage's resources widget has no
threshold option, so it can only ever be something you remember to look at.

### Choosing a floor

Set it above the largest single download you expect to *finish*, plus room for an unpack and a
container image pull. The brake stops new downloads; it cannot stop one already in flight, so a
16 GiB film that started when there was plenty of room will walk straight through a floor set
lower than itself. Docker images alone are around 10 GB here, `update.sh` pulls more, and journald
wants its share.

25 GiB is a sensible floor on a large disk. 5 GiB protects against almost nothing that actually
happens — it is the point at which the machine is already in trouble.

To see where the space went, and how much of it is real rather than hardlinked,
`./scripts/audit-space.sh`.

## 25. The archive tier

The library lives on one disk that `data/torrents` and `data/usenet` share, and a full filesystem
takes the whole stack down rather than degrading. `DISK_FLOOR_GIB` stops new downloads before that
happens (README "Keeping the disk from filling"), which keeps the machine alive but also stops the
library growing. The archive tier is a second, encrypted place the library can live instead, and
`ARCHIVE_REMOTE_PERCENT` decides how much of it does — so the floor is approached less often, or
never.

Nothing moves because of its age. Age only decides which titles go first, on the assumption that
what arrived longest ago is least likely to be watched next — an assumption, not a measurement:
the mover reads the date a title was added, not whether anyone has played it.

```
data/
├── torrents/      real filesystem, unchanged
├── usenet/        real filesystem, unchanged
├── media/         real filesystem  ← hardlinks, atomic moves, the release guard
└── archive/       rclone mount     ← encrypted, elsewhere
```

**Archived titles still play.** They stay in the Plex and Jellyfin libraries, stay in Sonarr and
Radarr, and stream on demand. Only the bytes moved. "Archive" names the role, not a retirement.

**The whole tier is optional.** The `rclone` service sits behind the `archive` compose profile, so
without `COMPOSE_PROFILES=archive` in `.env` it does not exist as far as compose is concerned and no
container starts that could only fail for want of a remote. `configure.sh`, `watch.sh` and
`mover.sh` all report it as absent and change nothing. Turn it on when you run out of room; leave it
off while a bigger disk is doing the job. `DATA_ROOT` can point at that disk (README "Directory
structure"), and the two are not alternatives - a disk that fills can still overflow here.

### Why a second path and not one merged tree

Most guides describe a union — mergerfs or rclone's own — so the two tiers look like one directory
and files can move between them invisibly. That was rejected here, because every cost lands on the
part of the stack that already works:

This stack **does** use a union — mergerfs over `data/local` and `data/archive`, mounted at
`data/union` and given to every container as `/data`. That was resisted for a long time for two good
reasons, and both had to be answered before it could be done:

- **An import must still be a hardlink.** A union is FUSE, so linking from an ext4 download folder
  into a FUSE library is cross-device: `link()` returns `EXDEV` and Sonarr silently copies the whole
  file instead. The answer is that the union spans the downloads too — `torrents` and `usenet` live
  on the local branch and are inside the same mergerfs mount as the library, so a link is made
  *within* that branch and costs nothing. `scripts/union-verify.sh` tests exactly this, because it
  is the failure that would otherwise go unnoticed until the disk filled twice as fast.
- **A union that fails open shows an empty library.** If mergerfs is not mounted, `/data/media`
  resolves to the bare local directory, which looks entirely normal and is quietly missing
  everything archived — and the apps would treat several hundred gigabytes as missing and
  re-download it. So nothing fails open: the mount unit is ordered `Before=docker.service`,
  `mover.sh` refuses to run unless both branches and the union are mounted, `watch.sh` alerts when
  `/data/media` is not a FUSE mount inside the apps, and `configure.sh` says so too.

What the union buys is the thing a second root folder could never give: **the apps do not know where
a file is**. A title is at the same `/data/media` path whichever branch holds it, so the mover moves
*individual files* — one episode of a series, not the series — with no app call, no database change
and no library rescan.

### Setting it up

Everything below happens once. `configure.sh` reports `no archive configured` until it is done, and
changes nothing in the meantime.

```bash
./scripts/archive-setup.sh      # asks for the provider and the encryption password
docker compose up -d            # start the mount
./configure.sh                  # one root folder per library, on the union
./mover.sh install              # hourly timer
```

`archive-setup.sh` sets `COMPOSE_PROFILES=archive` itself once the remote answers, so the second
command starts the mount rather than doing nothing. To switch the tier off again, clear that key and
`docker compose up -d --remove-orphans`: nothing else changes, the apps simply have one root folder
fewer and whatever was already archived stays where it is until the mount returns.

`archive-setup.sh` bakes in three settings that **cannot be changed after the first upload** -
`filename_encryption = standard`, `directory_name_encryption = true` and
`filename_encoding = base64` - because changing any of them means rclone can no longer find what it
wrote. Filenames are encrypted, so the provider sees the size and shape of the collection but not
one title.

**Google Drive** additionally needs an OAuth client of your own: rclone's shared one stops working
during 2026. Create a Google Cloud project, enable the Drive API, add the scopes `drive`, `docs` and
`drive.metadata.readonly`, add yourself as a test user, then **publish** the app - grants in Testing
mode expire after seven days, which would break the mount weekly. Verification is *not* needed: a
personal-use app under 100 users is exempt, at the price of one "unverified app" warning during
setup. The script also sets `root_folder_id`, so the token reaches one folder rather than the whole
Drive, and `use_trash = false`, so deleted files stop counting against the quota.

**A Hetzner Storage Box, or any SSH host,** needs a hostname, a username and an SSH key. No OAuth,
no quotas, no daily caps.

### The password has no reset

There is no recovery path. Lose the encryption password and every archived file is permanently
unreadable - which is the encryption doing exactly what it was asked to. Generate it in a password
manager, store it there *before* using it, and keep a copy somewhere other than this machine.
`config/rclone/rclone.conf` holds it obscured, not encrypted, so that file is as sensitive as the
password itself and is what a backup needs to contain.

### What the mover does

#### When it runs

Hourly, and does nothing while the library is where it should be. Two things start it:
`ARCHIVE_REMOTE_PERCENT` being short, at whatever hour, and free space falling below
`DISK_WARN_GIB`.

```
100%      ARCHIVE_REMOTE_PERCENT   where the library should live
 75 GiB   DISK_WARN_GIB            the emergency, and the "disk filling" alert
 25 GiB   DISK_FLOOR_GIB           downloading stops: SABnzbd pauses, torrent
                                   downloads held. Imports carry on.
```

The share is the steady-state policy; the warn mark is the emergency that overrides it. Below the
mark the mover moves whatever `ARCHIVE_MAX_GIB_PER_RUN` allows whether the share is met or not,
because a disk about to fill is the worse problem. The floor is where the stack stops working to
save itself, so the warn mark has to come first — by the time the floor is reached, what it guards
against has happened.

Otherwise it waits for `UNRESTRICTED_HOURS`. Archiving is a bulk upload on the same uplink Plex
streams out on, and moving a title is most disruptive while someone is watching it; in that window
rclone's cap is `off`, so the move runs at line speed. Below `DISK_FLOOR_GIB` it goes whatever the
hour, downloading having already stopped.

#### What it moves, and what it will not

The least recently added titles, until `ARCHIVE_REMOTE_PERCENT` of the library lives in the cloud.
That share is a **placement policy, not a free-space target** — `100` keeps the disk as a staging
area, `50` keeps half local, `0` turns it off — counted over local **plus** already archived, so
the denominator does not shrink as it works and leave the figure chasing its own tail. Files move
one at a time, so the result lands within one file of the target rather than overshooting by a
whole series.

Music goes too, by the same rule and with no special handling: it is a file on the local branch like
any other.

Three things it will not move: a file younger than `ARCHIVE_MIN_AGE_DAYS`, one smaller than
`ARCHIVE_MIN_FILE_MIB` — subtitles and artwork cost nothing locally and Bazarr rewrites subtitles in
place — and one still **hardlinked to a seeding torrent**, because uploading a copy while the
torrent's copy holds the disk pays twice and reclaims nothing. That last test is `find -links 1`, so
it is per file: one seeding episode no longer pins the other thirty in its series, which is what the
old per-folder check did and why 40 GiB shows could sit local for the sake of a single file.

Moves are plain file operations, not API calls, and that is the inversion the union allows. The old
tier moved titles through each app's `moveFiles` endpoint because the app owned the database saying
where a title lived; now the path never changes, so there is nothing to tell it. A file whose name
would not survive encryption is skipped and logged, checked per file for the same reason as above.

#### What the upload may take

`ARCHIVE_UPLOAD_WINDOW` is an rclone bandwidth timetable — `06:00,30517K 01:00,off` caps it at
250 Mbit/s by day and lifts the cap overnight. Without it the archive is the only uncapped mover on
the line: `USENET_MAX_KIB` bounds the way in and `TORRENT_UPLOAD_MAX_KIB` the way out, and a run
would take the whole uplink, which remote Plex streams and torrent seeding share. The damage is
queueing rather than shortage — a saturated uplink adds latency to everything behind it. Rates are
binary, so 250 Mbit/s is `Mbit × 125000 ÷ 1024` = `30517K`. The hours must match
`UNRESTRICTED_HOURS`: rclone wants one timetable string and `compose.yml` cannot split that value,
so this is the one place the window is written twice.

`ARCHIVE_MAX_GIB_PER_RUN` bounds a single run, and `.env.example` gives the four reasons it is not
unlimited. Only one binds: everything a run moves passes through rclone's cache before it uploads,
so the cap has to fit `RCLONE_CACHE_MAX` — half of it, since `--vfs-cache-max-age` is an hour and
the timer fires hourly, so two runs can be resident. `mover.sh` clamps it if it is set higher.

#### Three things a real move taught

None of them readable off the code:

- **The space does not come back when the file moves.** A write to the mount lands in rclone's local
  cache and uploads afterwards, so `df` is unchanged for as long as the cached copy survives — which
  is why `--vfs-cache-max-age` is an hour here and not rclone's default week, and why the mover
  counts what it has moved rather than watching free space. One that waited for `df` would archive
  the whole library.
- **The upload has to be waited for.** The move returns as soon as the bytes are cached. `mover.sh`
  asks rclone's `vfs/queue` whether the uploads have drained before reporting what it did, so a run
  never finishes leaving gigabytes queued for the next one to start on top of.
- **Plex and Jellyfin have nothing to notice.** Under the union the file is at the same path after
  the move as before it, so no scan is needed and none is triggered. The old tier had to force one,
  because a root folder change is not an import, a rename or a delete, and an archived title would
  otherwise vanish from both libraries until their next scheduled scan.

### Changing provider

`media:` is the only remote the stack ever mounts. Swapping Google Drive for a Storage Box is two
lines in `config/rclone/rclone.conf` and nothing at all in this repo:

```ini
[media]
remote = gdrive:           # becomes  hetzner:media-stack
```

On Drive the provider-side folder is named by `root_folder_id` on the `gdrive` remote rather than by
a path, so `gdrive:` already *is* the `media-stack` folder and nothing else in the Drive is
reachable. On an SSH host there is no such scoping, so the directory is named in the path.

`configure.sh` reads the backend type and only gives advice that applies to it.

### When it stops working

`watch.sh` checks that `/data/media` really is a FUSE mount inside Sonarr and Radarr and that the
cloud branch is mounted on the host, and alerts on the `health` events (README "Alerts (ntfy)") when
it is not, once three runs agree - the mount is briefly absent while the rclone container restarts.
The check is silent on a stack with no archive configured. It tests the union rather than the cloud
branch alone because the dangerous failure is not a missing directory but a plausible one: without
mergerfs, `/data/media` is the bare local branch, which looks completely normal and is simply
missing everything archived.

`mover.sh` refuses to run unless the union, the local branch and the cloud branch are all mounted.
An unmounted cloud branch is the worst case: it is then a plain directory on the local disk, so a
"move to the cloud" would write the bytes onto the very disk the run is trying to free, and rclone
would hide them completely the moment it mounted over them.

```bash
systemctl status media-stack-union                           # the union itself
docker compose logs rclone                                   # the mount's own account of itself
docker compose exec -T sonarr stat -f -c %T /data/media      # "fuse" where it matters, not "ext2/ext3"
./scripts/union-verify.sh                                    # all of the above, plus the hardlink test
./mover.sh status                                            # what was archived, and when
```

If the mount is missing inside the apps but present on the host, the bind lost its propagation:
recreate them with `docker compose up -d sonarr radarr`.

## 26. Spotweb, the Spotnet indexer

Spotnet is a Dutch Usenet community: spots are signed posts describing what is on the groups, and
**Spotweb** indexes them and speaks Newznab, so Prowlarr can search it like any other indexer. It is
the one indexer in this stack that the stack itself runs.

`configure.sh` sets it up completely. Nothing is clicked, and nothing is typed twice — it reuses the
`USENET_*` account already in `.env` for SABnzbd, because Spotweb needs a Usenet server of its own to
read the headers from.

### What it is not

Deliberately **not** in Gluetun's namespace. Like SABnzbd, Spotweb talks to a Usenet provider that
knows the account whatever address it arrives from, so there is no swarm to hide from and the
transfer is already TLS. It sits on the `media` network as a normal container, and Prowlarr reaches
it from inside the tunnel by name — Gluetun allows the local Docker subnet in both directions, so
that call never goes through the VPN.

There is also **no database container**. Spotweb runs on SQLite, with the file at
`config/spotweb/spotweb.db3`, which keeps this to one 38 MB image and avoids the two upstream bugs
that only bite on MySQL.

### The three Usenet servers

Spotweb stores **three** Usenet servers — `nntp_nzb`, `nntp_hdr` and `nntp_post`. Because headers and
posting are stored as separate copies, **Settings → Usenet server** opens with *"use a different
server for headers?"* and *"…for posting?"* already ticked. Fill in only the top one, save, and
retrieval carries on pointing at whatever was there before — and the save reports success.

`configure.sh` writes the NZB server and blanks the other two, because an empty host makes Spotweb
fall back to the NZB server. Reading them back through Spotweb's own settings shows all three with
the same host, which is what correct looks like; the stored values are what differ.

If you change the server by hand, untick both boxes.

### Retention, and why the first run takes a while

`SPOTWEB_SINCE_YEAR` sets how far back to index, and becomes Spotweb's `retrieve_newer_than`. It is a
floor on what gets **stored**, not on what gets read: there is no "start at article N", so the first
pass walks the whole group — millions of articles — and simply declines to store the older ones.
Expect several minutes, and expect the counters to show almost everything as `invalid` or
`rtntn.skip` while it works through the back catalogue. That is normal.

Retrieval runs on the container's own cron, every `SPOTWEB_INTERVAL_MIN` minutes. Keep that longer
than a run takes — upstream's lock is not reliable enough to let two overlap.

### Going back further

Raising the depth is two settings, not one. `SPOTWEB_SINCE_YEAR` is the floor on what Spotweb
**stores**; separately, in `usenetstate.curarticlenr`, it tracks how far it has **read**. The reader
only moves forward, so once it is past the old articles a lower floor has nothing left to act on.

Edit the year in `.env`, then run the backfill — it reads the same key, so the depth stays in one
place:

```bash
./scripts/spotweb-backfill.sh         # re-scan from SPOTWEB_SINCE_YEAR
./scripts/spotweb-backfill.sh 2015    # or from a year given here instead
./scripts/spotweb-backfill.sh -n      # say what it would do, change nothing
```

`configure.sh` says so too: when the index starts later than the configured year, its Spotweb section
prints the year it actually reaches and points at this script. It never widens the index itself — that
is a twenty-minute retrieval, and `configure.sh` stays fast and re-runnable.

The script lowers the floor and runs `retrieve.php --retro`. Editing `usenetstate.curarticlenr` by
hand has no effect: Spotweb does not trust that number, and on each run re-derives its position by
looking up the newest spots it already holds — the last 5000 message ids — on the server, which is
what keeps it correct when a server renumbers articles. `--retro` is the only switch that ignores the
stored position and starts at the first article. Spots already held are skipped, not duplicated.

**It holds the container's cron off for the duration** and restores it on exit. Two retrievals must
not overlap — upstream's lock does not prevent that, and on SQLite the second writer takes the write
lock and the first one's work is rolled back while `retrieve.php` still reports success. The script
therefore judges a pass by whether the spot count moved, not by what the output says.

Budget around twenty minutes whichever year you choose: the whole group is read either way, so the
year decides only what is *kept*.

**A spot is only an index entry.** Whether it can still be *downloaded* depends on your Usenet
provider's article retention, not on Spotweb, so how far back is worth indexing is a question about
your provider rather than about this stack. Retention differs a lot between providers and generally
grows over time, so check what yours offers rather than assuming — spots older than your window will
index fine and fetch nothing.

There is a floor either way: Spotnet spots only begin around **2010**, so an earlier year costs
nothing extra and finds nothing more. For scale, on this stack's group the full archive back to 2010
is about **2.3 million spots in an 850 MB database** — roughly 100k spots a year at 375 bytes each,
which is nothing next to the disk this stack watches.

### Prowlarr needs a second user, and here is why

Prowlarr gets Spotweb as a **generic Newznab** indexer; Prowlarr ships no Spotweb definition among
its six hundred.

The API key cannot be the admin's: Spotweb refuses any key belonging to a user id at or below the
admin's, and answers an HTML error page instead, which Prowlarr reports as a mismatched XML tag. So
`configure.sh` creates a `prowlarr` user and uses its key. Its password is random and never needed.

One more ordering quirk: Prowlarr validates an indexer by **searching** it, so it refuses to save one
that returns nothing — and a freshly installed Spotweb returns nothing until the first retrieval has
run. `configure.sh` therefore counts the spots and waits: the Spotweb step says so, and the indexer
is added on the next run, once there is something to find.

### The search fix it ships with

`compose.yml` mounts `spotweb/dbfts_abs.php` over the image's copy of
`lib/dbeng/dbfts_abs.php`. One character differs from upstream: the regex in `splitWords()` gains the
`/u` modifier.

Without it `\w` is ASCII-only, so a search term written in a non-Latin script is dropped while the
`AND` that joined it to the next term survives. What reaches SQLite then begins with a bare `AND`,
which FTS5 refuses — `fts5: syntax error near "AND"` — and Spotweb answers a plain-text crash page
with HTTP 200. Prowlarr counts that as a failure and disables the indexer, so Sonarr and Radarr
report **"Indexers unavailable due to failures: Spotweb"**.

It is not an edge case. Sonarr and Radarr search a title's *alternates*, which for a great many films
and series are Korean, Japanese or Hindi, so the stock image fails several times an hour and the
warning never stays away.

### The UHD category fix it ships with

`compose.yml` also mounts `spotweb/SpotPage_newznabapi.php` over the image's copy of
`lib/page/SpotPage_newznabapi.php`. One line differs from upstream: `spotAcat2nabcat()` gains
`15 => '2000|2040'` in the Movie map.

Spotnet subcategory 15 is UHD. The Series map has it and the reverse map already claims it —
`nabcat2spotcat(2040)` returns `…,cat0_z0_a15` and its own comment ends `X264, UHD` — but the
forward map for films stops at 14. A 4K film spot therefore leaves the API with **no**
`<newznab:attr name="category">` at all, and Prowlarr refuses a release that has no category:

```
Invalid Release: 'Young Guns (1988) - 2160p HDR BRMux - DoVi - Atmos - NLsub'
from indexer: Spotweb. No categories provided.
```

Every 4K film on Spotnet is invisible to Sonarr and Radarr, and the log calls the release invalid
rather than uncategorised — so the message points away from the cause. Nothing else is affected:
1080p and below map correctly, and series spots carry `5000` even when their subcategory does not
resolve, so only films lose their category entirely.

It maps to `2040` rather than a new `2045` deliberately. That is what `nabcat2spotcat()` already
maps subcategory 15 to, and `2040` is declared in `categories()`, so Prowlarr can resolve it from
the caps document — inventing `2045` would mean a category the image never advertises.

`configure.sh` checks the image's own copy of **both** patched files against the versions the patches
were taken from, and reports `search fix still applies to this image` and `UHD category fix still
applies to this image`. If a future image changes either file it warns instead, so an override
cannot quietly hide an upstream fix — at which point that mount can probably go.

### When it stops working

Spotweb prints `crashed` and **exits 0**, so a failed retrieval is invisible to anything watching
exit codes — including its own cron. `watch.sh` watches the only thing that is observable from
outside: whether new spots keep arriving. `SPOTWEB_STALE_HOURS` sets how long a gap is too long, and
the alert goes out with the `disk` events (see README "Alerts (ntfy)"). An empty database is not
staleness, so the check stays quiet until the first spots land.

To look for yourself:

```bash
docker compose exec -T -u abc spotweb php /app/query.php --get_nntp_configured   # 0 means no server
docker compose exec -T -u abc spotweb php /app/retrieve.php                      # judge the OUTPUT
```

A good run ends with `Finished retrieving spots` and contains none of `crashed`, `Fatal error` or
`Uncaught`. Never judge it by the exit code.

## 27. Troubleshooting permissions

**Symptom:** `Access to the path is denied`, `Permission denied`, files owned by `root` or a
strange uid inside `data/`.

```bash
# 1. What ids are the containers using?
docker compose exec -u abc sonarr id   # expect uid=PUID gid=PGID from .env (abc is the LSIO app user)

# 2. Who owns the tree on the host?
ls -ln data data/torrents data/media   # numeric owner:group must equal PUID:PGID
ls -ln config/sonarr

# 3. Can the container write where it must?
docker compose exec -u abc sonarr sh -c 'touch /data/media/tv/.w && rm /data/media/tv/.w && echo write-ok'
docker compose exec -u abc qbittorrent sh -c 'touch /data/torrents/.w && rm /data/torrents/.w && echo write-ok'
```

Fixes:

- Wrong owner on the host: rerun the `chown` from section [Permissions setup](#4-permissions-setup) on **this stack's directories**.
- A file inside is owned by root: it was created by something outside the stack (a manual
  `sudo cp`, an older container without PUID). Fix that one path: `sudo chown PUID:PGID <path>`.
- `PUID`/`PGID` changed in `.env`: `docker compose up -d` recreates the containers; LSIO images
  fix ownership of `/config` on start but not of `/data` (by design — it can be huge).
- Files created with `rw-r--r--` and the group cannot write: `UMASK` in `.env` is not `002`.

## 28. Troubleshooting imports

**Symptom:** download finishes, nothing appears in `/data/media`, or Sonarr shows a warning
under Activity → Queue.

0. **Nothing is ever grabbed** ("wanted / missing" forever, no queue): Radarr/Sonarr have no
   usable indexer. Check System → Status for "No indexers available". An indexer that Prowlarr
   accepts but does not sync is one **without categories** (raw search engines such as
   NZBIndex): Prowlarr only pushes indexers whose categories overlap the app's, and the apps
   always search with a category filter, which such indexers cannot answer. Use those manually
   from Prowlarr's *Search* page (Grab → category `movies`/`tv`; the import chain takes over),
   and give the apps a categorised Newznab/Torznab indexer for automation.
1. Read the reason: Activity → Queue → the ⚠ icon says exactly why (wrong category, no
   matching episode, "path does not exist", unpacking failed).
2. **"Path does not exist" / "Remote path mapping"**: the download client reports a path Sonarr
   cannot see. In this stack that means a client was configured with a save path outside
   `/data` (check qBittorrent's default save path and SABnzbd's completed folder). Fix the
   client, not the mapping.
3. **Copied instead of hardlinked** (slow, doubles disk usage): section [Hardlink verification](#18-hardlink-verification). Usually a second
   bind mount or `data/media` on another disk.
4. **Import never triggers**: Settings → Download Clients → *Completed Download Handling* must
   be enabled, and the client's category must match what the download was sent with.
5. **Stuck at "Importing" with `.!qB` or `.part` files**: the download is not actually complete
   or is still being repaired/unpacked by SABnzbd. Wait, or check the client.
6. **Unpacking left `_UNPACK_…` directories**: SABnzbd ran out of disk, or its `incomplete`
   folder is on another filesystem than `complete`. Both must be under `/data/usenet`.
7. Logs: Sonarr → System → Logs, or `docker compose logs --since 30m sonarr | grep -i import`.

## 29. Troubleshooting Docker networking

**Symptom:** an app cannot reach another ("connection refused", "name does not resolve").

```bash
# Is everything on the same network?
docker network inspect media-stack_media --format '{{range .Containers}}{{.Name}} {{end}}'

# Does the name resolve from inside the calling container?
# qBittorrent, Prowlarr and FlareSolverr have no names of their own: they run in
# Gluetun's network namespace, so they answer as "gluetun" and nothing else.
docker compose exec sonarr getent hosts sabnzbd jellyfin gluetun

# Is the port open on the target? Use the CONTAINER port - and "gluetun" for the
# three in the tunnel: 8081 qBittorrent, 9696 Prowlarr, 8191 FlareSolverr.
docker compose exec sonarr curl -sS -o /dev/null -w '%{http_code}\n' http://gluetun:8081/
docker compose exec sonarr curl -sS 'http://sabnzbd:8080/api?mode=version'
```

Common causes:

- qBittorrent behind the proxy shows an unstyled login page and rejects the password with
  `401`: the proxy rewrites the `Host` header, so it no longer matches the browser's `Origin`
  and qBittorrent's CSRF check refuses every request. Pass the original `Host` through (no
  `header_up Host` on that site). Directly, the port in the URL must equal `WEBUI_PORT`
  (8081). SABnzbd is the opposite case (`403 Hostname verification failed`): it needs
  `header_up Host {upstream_hostport}` or its own name in `host_whitelist`.
- A hostname resolves but the browser shows another app or the dashboard: the proxy has no
  site for that name (typo in `SITE_DOMAIN`, or the site block is missing) — unknown names
  fall through to the default site.
- Homepage shows "Host validation failed": the name you used is not in
  `HOMEPAGE_ALLOWED_HOSTS` (`compose.yml`: `media.<domain>`, `LAN_IP`, `localhost:3000`).
- Using `localhost` or `127.0.0.1` in an app-to-app setting. Inside a container that is the
  container itself. Use the service name.
- A container was started outside this Compose project and is not on `media-stack_media`.
- Health checks show `unhealthy`: `docker inspect --format '{{json .State.Health}}' sonarr | jq`
  shows the last probe output.
- Plex clients relay or say "indirect": `LAN_IP` in `.env` must be this host's LAN address
  and `configure.sh` must have run after the claim (it sets the custom access URL). "Not
  available outside your network" is expected without `PLEX_PUBLIC_PORT` + a router forward.
- The host firewall (if you run one) must allow the published ports on the LAN interface and
  must not block the `docker0`/`br-*` bridge; on Arch check `sudo nft list ruleset` or
  `sudo iptables -S`.
- Port already in use on the host: `docker compose up` says so explicitly. Find the owner with
  `ss -tlnp | grep :8080` and change the **host** side of the mapping in `compose.yml`.
- Plex works on this machine and over the VPN but not from other LAN devices or the internet
  (probes report "No route to host"): the **host firewall** rejects the port. When Docker does
  not manage iptables (`"iptables": false` in `/etc/docker/daemon.json`, typical on a gateway),
  published ports go through the host's INPUT rules. `configure.sh` warns about this for
  firewalld; the fix is `sudo firewall-cmd --permanent --zone=<zone of the LAN interface>
  --add-port=32400/tcp && sudo firewall-cmd --reload` (add `6881/tcp` and `6881/udp` for
  incoming torrent peers). UPnP cannot replace this — nor the router forward — for a
  container on a bridge network.

