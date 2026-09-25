#!/usr/bin/env bash
# Wires the running containers together through their APIs. Safe to re-run:
# every step checks before it changes anything.
#
# What it does:            one Web UI login for qBittorrent, Sonarr, Radarr,
#                          Lidarr, Prowlarr, Bazarr and SABnzbd
#                          (asked once, stored in .env); qBittorrent
#                          paths/categories; SABnzbd folders/categories;
#                          Sonarr+Radarr+Lidarr root folders and
#                          download clients; Prowlarr -> those three, plus the
#                          FlareSolverr proxy; Bazarr
#                          -> Sonarr/Radarr; Plex claim (optional) + libraries;
#                          Sonarr/Radarr -> Plex library refresh and TRaSH-style
#                          naming; Bazarr language profile; SABnzbd Usenet
#                          provider (from USENET_* in .env); Recyclarr, which
#                          syncs the TRaSH Guides' quality definitions, custom
#                          formats and profiles into Radarr and Sonarr, plus a
#                          dubbed twin of each profile; Seerr end to end
#                          (Plex login, server, libraries, Sonarr, Radarr);
#                          the Homepage dashboard config; a hostname check.
# What stays yours:        indexers (Prowlarr, incl. tagging the ones that need
#                          FlareSolverr) and subtitle providers (Bazarr) - each
#                          needs one of your accounts.
#
# Needs: docker compose, curl, jq. No root. Run after `docker compose up -d`.
# Each section lives in its own file under lib/; this one holds the shared
# settings, the two steps that come first and the order everything runs in.
#
#   ./configure.sh              apply / re-apply everything
#   ./configure.sh --set-login  choose a new Web UI username/password first
set -euo pipefail
cd "$(dirname "$0")"

SET_LOGIN=0
LOGIN_CHANGED=0
case "${1:-}" in
  "") ;;
  --set-login) SET_LOGIN=1 ;;
  *) echo "usage: $0 [--set-login]" >&2; exit 2 ;;
esac

# python3 parses .env and writes the Recyclarr config (which needs PyYAML), so a
# missing module has to fail here rather than half way through a run.
python3 -c 'import yaml' 2>/dev/null || { echo "missing: python3 with PyYAML (pacman -S python-yaml / apt install python3-yaml)" >&2; exit 1; }
for tool in docker curl jq python3; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
[[ -f .env ]] || { echo ".env missing - run ./setup.sh first" >&2; exit 1; }
# .env is read the way Compose reads it (a raw value may hold &, (, spaces;
# optional matching quotes are stripped) - bash's source would misparse those.
eval "$(python3 - <<'PY'
import pathlib, shlex
for line in pathlib.Path('.env').read_text().splitlines():
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line: continue
    k, v = line.split('=', 1); k = k.strip(); v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'": v = v[1:-1]
    print(f'export {k}={shlex.quote(v)}')
PY
)"

# Host-side URLs (published ports) and the names the apps use for each other.
# qBittorrent lives in Gluetun's network namespace
# and is reached under Gluetun's name.
# Dubbed audio (DUB_LANGUAGE in .env): the arr apps name languages in English.
DUB_CODE=${DUB_LANGUAGE:-}
dub_name() {
  case "$1" in
    nl) echo Dutch ;;    de) echo German ;;   fr) echo French ;;     es) echo Spanish ;;
    it) echo Italian ;;  pt) echo Portuguese ;; pl) echo Polish ;;   sv) echo Swedish ;;
    da) echo Danish ;;   fi) echo Finnish ;;  cs) echo Czech ;;      hu) echo Hungarian ;;
    tr) echo Turkish ;;  ru) echo Russian ;;  ja) echo Japanese ;;   ko) echo Korean ;;
    zh) echo Chinese ;;  en) echo English ;;  *) echo "" ;;
  esac
}
iso639_2() {                     # iso639_2 nl -> nld   (Jellyfin stores ISO 639-2 codes)
  case "${1,,}" in
    nl) echo nld ;; en) echo eng ;; de) echo deu ;; fr) echo fra ;; es) echo spa ;; it) echo ita ;;
    pt) echo por ;; sv) echo swe ;; da) echo dan ;; nb|no) echo nor ;; fi) echo fin ;; pl) echo pol ;;
    tr) echo tur ;; ja) echo jpn ;; zh) echo zho ;; ko) echo kor ;; ru) echo rus ;; cs) echo ces ;;
    *) echo "$1" ;;
  esac
}
# The arr parsers read a language from tags they know (DUTCH, GERMAN, ...) but
# not from every spelling a dub carries: NLD and "NL Gesproken" parse as
# Unknown. This adds those, deliberately without the bare language word, which
# the language condition already covers and which would also match a film
# *called* "The Dutch Job". Empty = language condition only.
dub_title_regex() {
  # Only the spellings the parser itself cannot read. Checked against
  # /api/v3/parse: GERMAN, GER, German.DL, FRENCH, TRUEFRENCH, VFF, VF, VFQ,
  # SPANISH, Castellano, ITA, POLISH, PL, PLDUB, Dubbing.PL, CZ, CZ.Dabing,
  # HUN, RUS, DANISH, FINNISH, JAPANESE, KOREAN, CHINESE and the bare language
  # words all resolve on their own and need nothing here. What follows is what
  # came back as Unknown. Polish "Lektor" is deliberately absent: it is a
  # single voice reading over the original audio, not a dub, and a child needs
  # the dub.
  case "$1" in
    nl) echo '\b(NLD|NL[ ._-]?(Gesproken|Audio|Dub|Dubbed)|Nagesynchroniseerd|Dutch[ ._-]?(Audio|Dub|Dubbed))\b' ;;
    pt) echo '\b(PT[ ._-]?BR|DUBLADO)\b' ;;
    sv) echo '\b(SWE([ ._-]?(Dub|Dubbed|Tal))?|Svenskt[ ._-]?Tal)\b' ;;
    tr) echo '\b(DUBLAJ|TR[ ._-]?Dub(bed)?)\b' ;;
    cs) echo '\b(CZECH|DABING|CZ[ ._-]?Dab(ing)?)\b' ;;
    *) echo "" ;;
  esac
}

# A regional dub is a language of its own in both apps: a Brazilian dub parses
# as "Portuguese (Brazil)", never "Portuguese", and a Latin-American one as
# "Spanish (Latino)". Both belong in the same twin, so the language format
# carries one condition per name and they OR. A name the app does not know is
# skipped, which is why Sonarr's shorter list is not a problem.
dub_languages() {                # dub_languages pt -> Portuguese, Portuguese (Brazil)
  local main; main=$(dub_name "$1")
  [[ -n "$main" ]] || return 0
  printf '%s\n' "$main"
  case "$1" in
    pt) printf '%s\n' "Portuguese (Brazil)" ;;
    es) printf '%s\n' "Spanish (Latino)" ;;
  esac
}

# From .env, not from `docker compose config`: a transient Compose failure
# once made this script treat the VPN as absent and point every download
# client at the wrong host.
# qBittorrent, Prowlarr and FlareSolverr live in Gluetun's network namespace,
# so from another container they all answer on Gluetun's name. The host still
# reaches them on the ports Gluetun publishes.
QBT_URL=http://localhost:8081;   QBT_INTERNAL_HOST=gluetun;  QBT_INTERNAL_PORT=8081
SAB_URL=http://localhost:8080;   SAB_INTERNAL_HOST=sabnzbd;      SAB_INTERNAL_PORT=8080
SONARR_URL=http://localhost:8989
LIDARR_URL=http://localhost:8686
FLARESOLVERR_INTERNAL=http://gluetun:8191/
RADARR_URL=http://localhost:7878
PROWLARR_URL=http://localhost:9696
PROWLARR_INTERNAL=http://gluetun:9696
BAZARR_URL=http://localhost:6767
SEERR_URL=http://localhost:5055
SPOTWEB_URL=http://localhost:8087
SPOTWEB_INTERNAL=http://spotweb
PLEX_URL=http://localhost:32400
JELLYFIN_URL=http://localhost:8096
# Plex runs on the host network (compose.yml explains why), so the other
# containers reach it at the host's LAN address.
PLEX_INTERNAL_HOST=$LAN_IP
log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok   %s\n' "$*"; }
skip() { printf '   kept %s\n' "$*"; }
die()  { printf '   FAIL %s\n' "$*" >&2; exit 1; }

ensure_webui_credentials() {
  log "Web UI login (qBittorrent, Sonarr, Radarr, Lidarr, Prowlarr, Bazarr, SABnzbd)"
  WEBUI_USERNAME=${WEBUI_USERNAME:-admin}
  if [[ -n "${WEBUI_PASSWORD:-}" && $SET_LOGIN -eq 0 ]]; then
    skip "using WEBUI_USERNAME/WEBUI_PASSWORD from .env (change with --set-login)"; return
  fi
  if [[ $SET_LOGIN -eq 1 && ! -t 0 ]]; then
    die "--set-login needs a terminal to ask for the new login"
  fi
  if [[ -t 0 ]]; then
    local answer
    read -r -p "   Username [$WEBUI_USERNAME]: " answer
    [[ -n "$answer" ]] && WEBUI_USERNAME=$answer
    read -r -s -p "   Password [Enter = generate]: " answer; echo
    WEBUI_PASSWORD=$answer
  fi
  if [[ -z "$WEBUI_PASSWORD" ]]; then
    WEBUI_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    ok "generated a password"
  fi
  set_env WEBUI_USERNAME "$WEBUI_USERNAME"; set_env WEBUI_PASSWORD "$WEBUI_PASSWORD"
  # Until services.yaml is rewritten at the end, Homepage would keep polling
  # qBittorrent with the old login - five failures earn a one-hour IP ban.
  LOGIN_CHANGED=1
  docker compose stop homepage >/dev/null 2>&1 || true
  chmod 600 .env
  ok "stored in .env as WEBUI_USERNAME / WEBUI_PASSWORD"
}

wait_healthy() {
  log "Waiting for all containers to be healthy"
  local tries=0
  while :; do
    local unhealthy
    # A service without a health check reports an empty Health; only the ones
    # that declare one can be waited for (Recyclarr is a cron container).
    unhealthy=$(docker compose ps --format json | jq -r 'select(.Health != "" and .Health != "healthy") | .Name' | paste -sd, -)
    [[ -z "$unhealthy" ]] && { ok "all healthy"; return; }
    (( tries++ >= 60 )) && die "still not healthy after 3 minutes: $unhealthy"
    sleep 3
  done
}

# ---------------------------------------------------------------- sections
# One file per section under lib/. They only define functions and constants,
# so the order they are read in does not matter.
[[ -f lib/common.sh ]] || { echo "lib/ is missing - configure.sh needs it next to itself" >&2; exit 1; }
for part in lib/*.sh; do . "$part"; done

# ---------------------------------------------------------------- run
# A dependency order, not a list. quality_plan names the profiles everything
# downstream asks for (and fills SEERR_QUALITY_PROFILE); configure_sabnzbd and
# configure_jellyfin leave SAB_KEY and JELLYFIN_TOKEN behind for the arr apps,
# and a missing token fails silently rather than loudly; the guide profiles
# must exist before the dubbed twins copy them and before Seerr is pointed at
# one. Homepage is stopped near the top and started again by
# configure_homepage at the end.
ensure_webui_credentials
wait_healthy
quality_plan
ensure_dub_dirs
configure_qbittorrent
check_vpn
configure_sabnzbd
configure_plex
configure_jellyfin
configure_arr sonarr "$SONARR_URL" /data/media/tv     tv    tv
configure_arr radarr "$RADARR_URL" /data/media/movies  movie movies
configure_arr lidarr "$LIDARR_URL" /data/media/music   music music v1
configure_recyclarr
configure_dub_profiles radarr "$RADARR_URL" "/data/media/movies-$DUB_CODE" "$DATA_ROOT/media/movies-$DUB_CODE"
configure_dub_profiles sonarr "$SONARR_URL" "/data/media/tv-$DUB_CODE"     "$DATA_ROOT/media/tv-$DUB_CODE"
configure_spotweb
configure_prowlarr
configure_seed_criteria
configure_bazarr
configure_seerr
configure_seerr_prefs
# After the apps, whose API keys it needs; before the dashboard, whose ntfy
# tile wants the topic this may have just generated.
configure_notify
configure_homepage
check_hostnames
check_host_firewall

log "Done. Still yours to do"
echo "   1. Prowlarr: add the indexers you have accounts with; they sync to Sonarr/Radarr."
echo "   2. Bazarr: subtitle providers (your accounts)."
[[ -n "${USENET_HOST:-}" && -n "${USENET_USERNAME:-}" ]] ||
  echo "   3. Usenet provider, if any: USENET_* in .env, then re-run this script."
echo "   Dashboard: http://media.$SITE_DOMAIN   Web UI login: WEBUI_USERNAME / WEBUI_PASSWORD in .env"
echo "   (change it any time with ./configure.sh --set-login)"
