# Recyclarr: the TRaSH Guides sync that owns quality in Radarr and Sonarr.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.
#
# What it owns: the quality definitions (how big a release may be per minute of
# runtime), the custom-format collection with the guide's own scores, and the
# four quality profiles per app this stack offers. configure.sh must not touch
# any of those; it keeps the dubbed twins, which profile is the default, and the
# guards against fakes and cams, which the guides do not cover.
#
# One config file per app, written from the guide's own templates and given this
# stack's URL and API key. Put "# keep" on the first line to take one over; it is
# then never rewritten.
RECYCLARR_RADARR_TEMPLATES='hd-bluray-web remux-web-1080p uhd-bluray-web remux-web-2160p'
RECYCLARR_SONARR_TEMPLATES='web-1080p remux-web-1080p web-2160p remux-web-2160p'

# The profile each template creates, and so what MEDIA_QUALITY maps to.
recyclarr_profile() {             # recyclarr_profile APP VARIANT -> profile name
  case "$1:$2" in
    radarr:1080p-encode) echo "HD Bluray + WEB" ;;
    radarr:2160p-encode) echo "UHD Bluray + WEB" ;;
    sonarr:1080p-encode) echo "WEB-1080p" ;;
    sonarr:2160p-encode) echo "WEB-2160p" ;;
    *:1080p-remux)       echo "Remux + WEB 1080p" ;;
    *:2160p-remux)       echo "Remux + WEB 2160p" ;;
    *) die "no guide profile for $2 in $1" ;;
  esac
}

configure_recyclarr() {
  log "Recyclarr (TRaSH Guides)"
  local dir=$CONFIG_ROOT/recyclarr cache app url key dst written=0
  mkdir -p "$dir/configs"
  # Recyclarr clones the guide and its templates into its own directory on the
  # first run of any command; that clone is where these come from, so the
  # profiles and the scores are the guide's own.
  cache=$dir/resources/config-templates/git/official
  if [[ ! -d "$cache" ]]; then
    docker compose run --rm -T recyclarr config list templates >/dev/null 2>&1 || true
  fi
  [[ -d "$cache" ]] || die "Recyclarr has not fetched the guide templates yet - check: docker compose logs recyclarr"

  for app in radarr sonarr; do
    case $app in
      radarr) url=http://radarr:7878; key=$(xml_apikey radarr); set -- $RECYCLARR_RADARR_TEMPLATES ;;
      sonarr) url=http://sonarr:8989; key=$(xml_apikey sonarr); set -- $RECYCLARR_SONARR_TEMPLATES ;;
    esac
    dst=$dir/configs/$app.yml
    if [[ -f "$dst" ]] && head -n1 "$dst" | grep -qx '# keep'; then
      skip "$app.yml (# keep)"
      continue
    fi
    # The writer exits 9 when the file is already right; without catching that,
    # set -e would end the run here.
    local rc=0
    RECYCLARR_APP=$app RECYCLARR_DST=$dst RECYCLARR_URL=$url RECYCLARR_KEY=$key \
    RECYCLARR_CACHE=$cache RECYCLARR_TEMPLATES="$*" \
      python3 "$(dirname "${BASH_SOURCE[0]}")/recyclarr-config.py" || rc=$?
    case $rc in
      0) chmod 600 "$dst"; ok "$app.yml: $*"; written=1 ;;
      9) skip "$app.yml: $*" ;;
      *) die "could not write $dst" ;;
    esac
  done

  # The sync itself: quality definitions, the custom formats and the profiles.
  local out changes
  if ! out=$(docker compose run --rm -T recyclarr sync 2>&1); then
    printf '%s\n' "$out" | tail -20 >&2
    die "the Recyclarr sync failed (output above)"
  fi
  changes=$(printf '%s\n' "$out" | grep -cE "\[INF\].*(Created|Updated|Deleted)" || true)
  if (( changes > 0 )); then
    ok "sync done, $changes changes in Radarr and Sonarr"
  else
    skip "sync done, nothing to change"
  fi
  (( written )) && echo "        (the container re-syncs on RECYCLARR_SCHEDULE=${RECYCLARR_SCHEDULE:-@daily})"
  return 0
}
