#!/usr/bin/env bash
# Moves this stack from another server to THIS one. Run here, on the new host,
# after ./setup.sh. Everything comes over SSH with rsync; nothing on the old
# host is deleted.
#
#   ./migrate.sh user@oldhost:/path/to/media-stack --pre    copy config + data while the
#                                                          old stack keeps running (slow part)
#   ./migrate.sh user@oldhost:/path/to/media-stack          stop the old stack, copy the delta,
#                                                          carry .env values over, start here,
#                                                          run configure.sh
#
# Re-run as often as you like; rsync only transfers what changed. Needs: ssh
# access to the old host (key-based), rsync on both sides, docker there and here.
set -euo pipefail
cd "$(dirname "$0")"

SRC=${1:-}; MODE=${2:-final}
[[ -n "$SRC" && "$SRC" == *:* ]] || { echo "usage: $0 user@oldhost:/path/to/media-stack [--pre]" >&2; exit 2; }
[[ "$MODE" == "--pre" || "$MODE" == final ]] || { echo "unknown option: $MODE" >&2; exit 2; }
OLD_HOST=${SRC%%:*}; OLD_PATH=${SRC#*:}
[[ -f .env ]] || { echo ".env missing here - run ./setup.sh first" >&2; exit 1; }
for tool in rsync ssh docker; do command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }; done
set -a; source ./.env; set +a

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
old()  { ssh -o BatchMode=yes "$OLD_HOST" "$@"; }

# Keys whose values belong to the stack, not the host, and therefore move.
CARRY_KEYS=(SITE_DOMAIN WEBUI_USERNAME WEBUI_PASSWORD SUBTITLE_LANGUAGES UI_LOCALE UI_DATE_FORMAT UI_TIME_FORMAT UI_FIRST_DAY_OF_WEEK DUB_LANGUAGE USENET_HOST USENET_PORT
  USENET_USERNAME USENET_PASSWORD USENET_CONNECTIONS TORRENT_SEED_RATIO TORRENT_SEED_DAYS
  USENET_MAX_KIB TORRENT_MAX_KIB TORRENT_UPLOAD_MAX_KIB UNRESTRICTED_HOURS
  MEDIA_QUALITY RECYCLARR_SCHEDULE SEERR_QUALITY_PROFILE GUARD_MIN_RATIO GUARD_MAX_RATIO
  HEAL_INTERVAL NEWS_INTERVAL MISSING_SEARCH_TIME UPDATE_DAY UPDATE_TIME
  SPOTWEB_INTERVAL_MIN SPOTWEB_SINCE_YEAR SPOTWEB_STALE_HOURS
  DISK_FLOOR_GIB DISK_WARN_GIB NTFY_EVENTS NTFY_EVENT_APPS NTFY_PRIORITY
  PLEX_CERTIFICATION_COUNTRY PLEX_PUBLIC_PORT
  VPN_WIREGUARD_PRIVATE_KEY VPN_SERVER_COUNTRIES
  PIHOLE_URL PIHOLE_PASSWORD PIHOLE_LABEL PIHOLE2_URL PIHOLE2_PASSWORD PIHOLE2_LABEL
  WEATHER_LATITUDE WEATHER_LONGITUDE WEATHER_LABEL NEWS_FEEDS)

log "Checking the old host"
old "test -f '$OLD_PATH/compose.yml' && test -d '$OLD_PATH/config' && test -d '$OLD_PATH/data'" \
  || { echo "   FAIL $SRC does not look like a media-stack directory" >&2; exit 1; }
ok "$SRC reachable, stack directory found"
# Hardlinks only survive within one filesystem: warn if data/ here spans mounts.
if [[ "$(df --output=target data/torrents data/media 2>/dev/null | tail -n +2 | sort -u | wc -l)" -gt 1 ]]; then
  echo "   WARN data/torrents and data/media are on different filesystems here - hardlinks will not work (README "Directory structure")"
fi

# Enough room here? Real disk usage on the old host (downloads in progress are
# sparse, preallocated files) vs free space on this filesystem.
need=$(old "du -sk '$OLD_PATH/config' '$OLD_PATH/data' 2>/dev/null | awk '{s+=\$1} END{print s+0}'")
have=$(df -k --output=avail . | tail -n1)
here=$(du -sk config data 2>/dev/null | awk '{s+=$1} END{print s+0}')
if (( need - here > have )); then
  printf '   FAIL not enough free space here: need ~%d GiB more, %d GiB available\n' "$(( (need - here) / 1048576 ))" "$(( have / 1048576 ))" >&2
  exit 1
fi
ok "space: ~$(( need / 1048576 )) GiB to copy, $(( have / 1048576 )) GiB free here"

if [[ "$MODE" == final ]]; then
  log "Stopping the old stack (consistent databases)"
  old "cd '$OLD_PATH' && docker compose stop" >/dev/null
  ok "old containers stopped (not removed)"
  docker compose stop >/dev/null 2>&1 || true
fi

log "Copying application state (config/)"
rsync -aHS --info=progress2 --exclude 'plex/Library/Application Support/Plex Media Server/Cache/' \
  "$SRC/config/" config/
ok "config/ in sync"

log "Copying media and downloads (data/) - hardlinks and sparse files preserved"
rsync -aHS --info=progress2 "$SRC/data/" data/   # -S keeps preallocated downloads sparse
ok "data/ in sync"

if [[ "$MODE" == "--pre" ]]; then
  log "Pre-copy done"
  echo "   The old stack is still running. When ready for the switch: $0 $SRC"
  exit 0
fi

log "Carrying stack values from the old .env"
mkdir -p backups && chmod 700 backups
old "cat '$OLD_PATH/.env'" > backups/old.env && chmod 600 backups/old.env
# The family accounts file is local and gitignored: bring it along when present.
if old "test -f '$OLD_PATH/jellyfin-users.json'"; then
  old "cat '$OLD_PATH/jellyfin-users.json'" > jellyfin-users.json && chmod 600 jellyfin-users.json
  log "Carried jellyfin-users.json"
fi
OLD_ENV=backups/old.env KEYS="${CARRY_KEYS[*]}" python3 - <<'PY'
import os, pathlib
old = dict(l.split('=', 1) for l in pathlib.Path(os.environ['OLD_ENV']).read_text().splitlines() if '=' in l and not l.startswith('#'))
p = pathlib.Path('.env'); lines = p.read_text().splitlines()
for key in os.environ['KEYS'].split():
    val = old.get(key, '')
    if not val: continue
    for i, l in enumerate(lines):
        if l.startswith(key + '='): lines[i] = f'{key}={val}'; break
    else: lines.append(f'{key}={val}')
# COMPOSE_FILE stays host-specific: it only ever names a GPU override now, and
# the VPN is part of compose.yml rather than something to opt into.
p.write_text('\n'.join(lines) + '\n')
PY
ok "${#CARRY_KEYS[@]} keys checked (host-specific ones - PUID/PGID, LAN_IP, GPU groups, COMPOSE_FILE - stay as setup.sh set them; the VPN key is carried)"
rm -f backups/old.env

log "Starting the stack here"
docker compose up -d >/dev/null
./configure.sh < /dev/null

log "Done. Still yours to do"
cat <<MSG
   1. Router: forward TCP 32400 (Plex) and TCP+UDP 6881 (torrent peers) to $LAN_IP instead of the old host.
   2. DNS: point the *.$SITE_DOMAIN records at $LAN_IP (or at your reverse proxy, with the proxy
      upstreams changed to $LAN_IP). Re-run ./configure.sh afterwards; its hostname check should pass.
   3. Host firewall here: allow 32400/tcp and 6881/tcp+udp if the host runs one (README "Plex library setup").
   4. Plex clients reconnect by themselves (the server keeps its identity); Seerr, Bazarr and
      Prowlarr keep their links (same API keys).
   5. The old stack is stopped, not deleted. Once everything works here:
      ssh $OLD_HOST 'cd $OLD_PATH && docker compose down'  - then remove its data/ at your leisure.
MSG
