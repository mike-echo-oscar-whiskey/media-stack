#!/usr/bin/env bash
# One-time host setup: writes .env and creates the directory tree. Nothing here
# needs root and nothing is overwritten: an existing .env is left alone (delete
# it to regenerate).
#
# What it measures by itself (never asked): user and group ids, timezone, the
# host's LAN address and subnet, the render/video group ids and whether a GPU
# is present. What it asks for is what no machine can tell: the hostname
# suffix, the accounts you hold and the few preferences that leave the stack
# half-built when they are missing. Every question has a default; Enter takes
# it, and with no terminal (a script, a pipe) all defaults are taken silently.
# Everything else in .env has a sane default and is documented there -
# .env.example is the reference.
set -euo pipefail
cd "$(dirname "$0")"

if [[ -e .env ]]; then
  echo ".env already exists - leaving it untouched. Remove it to regenerate." >&2
  exit 1
fi

puid=$(id -u)
pgid=$(id -g)

tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
[[ -n "$tz" ]] || tz=$(readlink -f /etc/localtime | sed -n 's|.*/zoneinfo/||p')
[[ -n "$tz" ]] || tz=Etc/UTC

# Source address of the default route = the host's LAN IP.
lan_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
[[ -n "$lan_ip" ]] || lan_ip=192.168.1.2
# The LAN subnet (for Plex's "LAN networks"), plus the Tailscale range if present.
lan_net=$(ip -4 route show scope link 2>/dev/null | awk -v ip="$lan_ip" '$0 ~ "src " ip { print $1; exit }')
[[ -n "$lan_net" ]] || lan_net=${lan_ip%.*}.0/24
plex_lan=$lan_net
command -v tailscale >/dev/null 2>&1 && plex_lan="$plex_lan,100.64.0.0/10"

render_gid=$(getent group render | cut -d: -f3 || true)
video_gid=$(getent group video | cut -d: -f3 || true)

# Hardware transcoding override: enabled when the hardware is present. It is
# harmless without Plex Pass (the devices are mounted, Plex just does not use
# them), so there is nothing to lose by turning it on.
hwaccel=""
if command -v nvidia-smi >/dev/null 2>&1; then
  hwaccel=nvidia
elif [[ -e /dev/dri/renderD128 ]]; then
  hwaccel=amd
fi

# ---------------------------------------------------------------- questions
INTERACTIVE=0; [[ -t 0 ]] && INTERACTIVE=1
# The default of every question is the value .env.example ships, so the two
# can never drift apart.
default_for() { sed -n "s/^$1=//p" .env.example | head -n1 | sed 's/^"\(.*\)"$/\1/'; }
ask() {                           # ask PROMPT DEFAULT -> the answer, or DEFAULT
  local answer
  if (( INTERACTIVE )); then
    read -r -p "   $1 [${2:-none}]: " answer || true
    [[ -n "$answer" ]] && { printf '%s' "$answer"; return; }
  fi
  printf '%s' "$2"
}
ask_secret() {                    # ask_secret PROMPT -> the answer, never echoed
  local answer
  (( INTERACTIVE )) || { printf ''; return; }
  read -r -s -p "   $1 [none]: " answer || true
  echo >&2
  printf '%s' "$answer"
}
ask_yn() {                        # ask_yn PROMPT DEFAULT(y|n) -> true when yes
  local answer
  (( INTERACTIVE )) || { [[ "$2" == y ]]; return; }
  read -r -p "   $1 [$([[ "$2" == y ]] && echo "Y/n" || echo "y/N")]: " answer || true
  answer=${answer:-$2}
  [[ ${answer,,} == y* ]]
}
section() { (( INTERACTIVE )) && printf '\n\033[1m%s\033[0m\n' "$*"; return 0; }

section "Hostnames"
site_domain=$(ask "Domain suffix for the service hostnames (sonarr.<suffix>, ...)" "$(default_for SITE_DOMAIN)")

section "Plex"
extra_nets=$(ask "Other networks Plex should treat as local, e.g. another site's LAN (comma-separated CIDRs)" "")
[[ -n "$extra_nets" ]] && plex_lan="$plex_lan,${extra_nets// /}"
plex_port=$(default_for PLEX_PUBLIC_PORT)
ask_yn "Reach Plex from outside the house (needs TCP 32400 forwarded on your router)?" y || plex_port=""
plex_claim=$(ask_secret "Claim token from https://www.plex.tv/claim, valid four minutes (Enter to claim in the browser later)")
if (( INTERACTIVE )) && [[ -n "$plex_claim" ]]; then echo "   token accepted (${#plex_claim} characters)"; fi

section "Languages and formats"
ui_locale=$(ask "Locale for dates and clock in the apps and on the dashboard (en-US leaves the apps alone)" "$(default_for UI_LOCALE)")
subtitle_languages=$(ask "Subtitle languages for Bazarr, most wanted first (ISO 639-1)" "$(default_for SUBTITLE_LANGUAGES)")
dub_language=$(ask "Dubbed audio for young children who cannot read subtitles yet (ISO 639-1, Enter for none)" "")

section "Usenet"
usenet_host="" usenet_username="" usenet_password=""
usenet_port=$(default_for USENET_PORT) usenet_connections=$(default_for USENET_CONNECTIONS)
if ask_yn "Do you have a Usenet provider?" n; then
  usenet_host=$(ask "Server hostname" "")
  usenet_port=$(ask "Port (563 = TLS, 119 = plain)" "$(default_for USENET_PORT)")
  usenet_username=$(ask "Username" "")
  usenet_password=$(ask_secret "Password")
  usenet_connections=$(ask "Connections your plan allows" "$(default_for USENET_CONNECTIONS)")
fi

section "VPN (required)"
# Not a choice: qBittorrent, Prowlarr and FlareSolverr have no route to the
# internet other than Gluetun's tunnel, so without a key they cannot start and
# neither searching nor downloading works.
vpn_key=$(ask_secret "WireGuard private key (Proton VPN: a configuration with NAT-PMP ticked)")
if [[ -z "$vpn_key" ]]; then
  echo "   A WireGuard private key is required: qBittorrent, Prowlarr and FlareSolverr have no" >&2
  echo "   route out other than the tunnel, so without it nothing searches and nothing downloads." >&2
  exit 1
fi
vpn_countries=$(ask "Countries as Gluetun names them, nearest is fastest" "$(default_for VPN_SERVER_COUNTRIES)")

section "Dashboard"
weather_latitude="" weather_longitude="" weather_label=""
coords=$(ask "Coordinates for the weather tile, as 52.37,4.90 (Enter for no weather)" "")
if [[ "$coords" =~ ^(-?[0-9]+(\.[0-9]+)?)[,\ ]+(-?[0-9]+(\.[0-9]+)?)$ ]]; then
  weather_latitude=${BASH_REMATCH[1]}; weather_longitude=${BASH_REMATCH[3]}
  weather_label=$(ask "Name to show above it" "")
elif [[ -n "$coords" ]]; then
  echo "   not a coordinate pair - leaving the weather tile out (WEATHER_* in .env)" >&2
fi

compose_file=""
if [[ -n "$hwaccel" ]]; then
  compose_file="compose.yml:compose.hwaccel.$hwaccel.yml"
fi

# ---------------------------------------------------------------- write .env
# Values reach python through the environment, never the command line: a
# password or a key must not show up in the process list.
PUID_V=$puid PGID_V=$pgid TZ_V=$tz LAN_IP_V=$lan_ip PLEX_LAN_V=$plex_lan \
SITE_DOMAIN_V=$site_domain PLEX_PORT_V=$plex_port PLEX_CLAIM_V=$plex_claim \
UI_LOCALE_V=$ui_locale SUBTITLE_V=$subtitle_languages DUB_V=$dub_language \
USENET_HOST_V=$usenet_host USENET_PORT_V=$usenet_port USENET_USER_V=$usenet_username \
USENET_PASS_V=$usenet_password USENET_CONN_V=$usenet_connections \
VPN_KEY_V=$vpn_key VPN_COUNTRIES_V=$vpn_countries COMPOSE_FILE_V=$compose_file \
WEATHER_LAT_V=$weather_latitude WEATHER_LON_V=$weather_longitude WEATHER_LABEL_V=$weather_label \
RENDER_GID_V=${render_gid:-989} VIDEO_GID_V=${video_gid:-985} \
python3 - <<'PY'
import os, pathlib, re

pairs = {
    'PUID': 'PUID_V', 'PGID': 'PGID_V', 'TZ': 'TZ_V', 'LAN_IP': 'LAN_IP_V',
    'PLEX_LAN_NETWORKS': 'PLEX_LAN_V', 'SITE_DOMAIN': 'SITE_DOMAIN_V',
    'PLEX_PUBLIC_PORT': 'PLEX_PORT_V', 'PLEX_CLAIM': 'PLEX_CLAIM_V',
    'UI_LOCALE': 'UI_LOCALE_V', 'SUBTITLE_LANGUAGES': 'SUBTITLE_V',
    'DUB_LANGUAGE': 'DUB_V', 'USENET_HOST': 'USENET_HOST_V',
    'USENET_PORT': 'USENET_PORT_V', 'USENET_USERNAME': 'USENET_USER_V',
    'USENET_PASSWORD': 'USENET_PASS_V', 'USENET_CONNECTIONS': 'USENET_CONN_V',
    'VPN_WIREGUARD_PRIVATE_KEY': 'VPN_KEY_V', 'VPN_SERVER_COUNTRIES': 'VPN_COUNTRIES_V',
    'WEATHER_LATITUDE': 'WEATHER_LAT_V', 'WEATHER_LONGITUDE': 'WEATHER_LON_V',
    'WEATHER_LABEL': 'WEATHER_LABEL_V',
    'RENDER_GID': 'RENDER_GID_V', 'VIDEO_GID': 'VIDEO_GID_V',
}

# An empty answer means "leave the template's value alone", except where
# empty is itself the answer: no remote Plex port.
ALLOW_EMPTY = {'PLEX_PUBLIC_PORT'}

def quoted(value):
    # The scripts read .env with `source`, so anything with a space or a
    # semicolon in it has to arrive quoted.
    return f'"{value}"' if re.search(r'[\s;]', value) else value

lines = pathlib.Path('.env.example').read_text().splitlines()
for key, var in pairs.items():
    raw = os.environ[var]
    if raw == '' and key not in ALLOW_EMPTY:
        continue
    value = quoted(raw)
    for i, line in enumerate(lines):
        if line.startswith(key + '='):
            lines[i] = f'{key}={value}'
            break

compose = os.environ['COMPOSE_FILE_V']
if compose:
    for i, line in enumerate(lines):
        if line.startswith('COMPOSE_FILE='):
            lines[i] = f'COMPOSE_FILE={compose}'
            break
    else:
        last = max(i for i, l in enumerate(lines) if l.startswith('#COMPOSE_FILE='))
        lines.insert(last + 1, f'COMPOSE_FILE={compose}')

pathlib.Path('.env').write_text('\n'.join(lines) + '\n')
PY
chmod 600 .env

mkdir -p config/{plex,jellyfin,sonarr,radarr,lidarr,prowlarr,bazarr,seerr,sabnzbd,qbittorrent,recyclarr,ntfy,spotweb/cache,homepage/news} \
         data/torrents/{incomplete,movies,tv,music} \
         data/usenet/{incomplete,complete/{movies,tv,music}} \
         data/media/{movies,tv,music}
chmod -R u=rwX,g=rwX,o=rX data
chmod -R u=rwX,g=rX,o= config

docker compose config --quiet

weather_summary=none
[[ -n "$weather_latitude" ]] && weather_summary="$weather_latitude,$weather_longitude"
plex_hint=""
[[ -n "$plex_port" ]] && plex_hint="  - Plex remote access: forward TCP $plex_port on your internet router to $lan_ip:$plex_port"

cat <<MSG

Wrote .env (mode 600):
  PUID=$puid PGID=$pgid TZ=$tz
  LAN_IP=$lan_ip  SITE_DOMAIN=$site_domain  PLEX_LAN_NETWORKS=$plex_lan
  Usenet: ${usenet_host:-none}   VPN: ${vpn_countries}   Weather: $weather_summary
Directories created under config/ and data/. Compose file validates.

Next:
  - Edit .env if any value above is wrong (LAN_IP if you have several NICs).
    Everything not asked for is in there with a comment: rate caps, seeding
    rules, a second dashboard clock, Pi-hole tiles, news feeds, image tags.
${plex_hint:+$plex_hint
}  - Jellyfin family accounts: cp jellyfin-users.example.json jellyfin-users.json and edit (README "Jellyfin alongside Plex")
  - Self-healing: ./heal.sh install (README "Torrents through a VPN", self-healing)
  - Nightly retry of missing films and episodes: ./missing.sh install (README "Quality")
  - The web UI login for all nine apps is set by ./configure.sh (it generates
    one and stores it in .env; change it later with ./configure.sh --set-login)
MSG
case "$hwaccel" in
  amd)    echo "    (Intel/AMD GPU found at /dev/dri - compose.hwaccel.amd.yml enabled)" ;;
  nvidia) echo "    (NVIDIA driver found - compose.hwaccel.nvidia.yml enabled)" ;;
esac
echo "  - docker compose up -d"
