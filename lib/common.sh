# Small utilities every section uses.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- helpers
set_env() {                       # set_env KEY VALUE  -> updates .env in place (any characters)
  KEY=$1 VALUE=$2 python3 - <<'PY'
import os, pathlib
p = pathlib.Path('.env'); key, val = os.environ['KEY'], os.environ['VALUE']
lines = p.read_text().splitlines(); done = False
for i, l in enumerate(lines):
    if l.startswith(key + '='): lines[i] = f'{key}={val}'; done = True
if not done: lines.append(f'{key}={val}')
p.write_text('\n'.join(lines) + '\n')
PY
}
xml_apikey() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$CONFIG_ROOT/$1/config.xml"; }
yq() { printf "'%s'" "${1//\'/\'\'}"; }   # single-quoted YAML scalar, safe for any characters
urlenc() { python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
arr() {                           # arr KEY METHOD URL [JSON]
  local key=$1 method=$2 url=$3 body=${4:-}
  if [[ -n "$body" ]]; then
    # The body goes in on stdin, never as an argument: one argument is capped
    # at 128 KB, and a quality profile carrying a hundred custom formats gets
    # close enough to that to matter.
    printf '%s' "$body" | curl -fsS -X "$method" -H "X-Api-Key: $key" \
      -H 'Content-Type: application/json' --data-binary @- "$url"
  else
    curl -fsS -X "$method" -H "X-Api-Key: $key" "$url"
  fi
}
# UNRESTRICTED_HOURS "01:00-06:00" -> the four numbers, or nothing when unset.
unrestricted_window() {           # prints "FROM_H FROM_M TO_H TO_M"
  [[ ${UNRESTRICTED_HOURS:-} =~ ^([0-9]{1,2}):([0-9]{2})-([0-9]{1,2}):([0-9]{2})$ ]] || return 1
  printf '%d %d %d %d' "$((10#${BASH_REMATCH[1]}))" "$((10#${BASH_REMATCH[2]}))" "$((10#${BASH_REMATCH[3]}))" "$((10#${BASH_REMATCH[4]}))"
}

# The family file drives both servers - Jellyfin's accounts and which libraries
# a Plex Home user may see - so it is no longer Jellyfin's alone. The old
# Jellyfin-only name is still accepted, because an install that has one should
# not need renaming to keep working.
family_file() {
  local f
  for f in users.json jellyfin-users.json; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# Dates and clock in an arr app's web UI (Sonarr, Radarr, Lidarr and
# Prowlarr share the same config/ui shape). UI_LOCALE decides whether to touch
# them at all - en-US or empty leaves the apps at their own defaults - and the
# three UI_* format keys decide what to set. Only the formats change, never
# the language.
configure_ui_dates() {            # configure_ui_dates KEY URL VERSION
  local key=$1 url=$2 v=$3 current wanted short long week time first
  [[ ${UI_LOCALE:-} == en-US* || -z ${UI_LOCALE:-} ]] && return 0
  # The apps accept only the combinations their own dropdowns offer, so each
  # key maps to one of those rather than passing a format string through.
  case ${UI_DATE_FORMAT:-YYYY-MM-DD} in
    YYYY-MM-DD) short="YYYY-MM-DD"; long="dddd, D MMMM YYYY"; week="ddd DD/MM" ;;
    DD/MM/YYYY) short="DD/MM/YYYY"; long="dddd, D MMMM YYYY"; week="ddd DD/MM" ;;
    MM/DD/YYYY) short="MM/DD/YYYY"; long="dddd, MMMM D YYYY"; week="ddd M/D" ;;
    *) die "UI_DATE_FORMAT must be YYYY-MM-DD, DD/MM/YYYY or MM/DD/YYYY (got \"${UI_DATE_FORMAT:-}\")" ;;
  esac
  case ${UI_TIME_FORMAT:-24h} in
    24h) time="HH:mm" ;;
    12h) time="h(:mm)a" ;;
    *) die "UI_TIME_FORMAT must be 24h or 12h (got \"${UI_TIME_FORMAT:-}\")" ;;
  esac
  case ${UI_FIRST_DAY_OF_WEEK:-monday} in
    monday) first=1 ;;
    sunday) first=0 ;;
    *) die "UI_FIRST_DAY_OF_WEEK must be monday or sunday (got \"${UI_FIRST_DAY_OF_WEEK:-}\")" ;;
  esac
  current=$(arr "$key" GET "$url/api/$v/config/ui" | jq -c .)
  wanted=$(jq -c --argjson first "$first" --arg short "$short" --arg long "$long" \
                 --arg week "$week" --arg time "$time" \
    '.firstDayOfWeek = $first | .calendarWeekColumnHeader = $week
     | .shortDateFormat = $short | .longDateFormat = $long | .timeFormat = $time' <<<"$current")
  local told="dates $short, ${UI_TIME_FORMAT:-24h} clock, weeks start on ${UI_FIRST_DAY_OF_WEEK:-monday}"
  if [[ "$wanted" == "$current" ]]; then
    skip "$told"
  else
    arr "$key" PUT "$url/api/$v/config/ui/$(jq -r .id <<<"$current")" "$wanted" >/dev/null
    ok "$told"
  fi
}

# add_root_folder KEY URL PATH [APIVERSION] [BODY_JSON]
# Two sections add root folders now - the app itself and
# the archive tier - so the GET/compare/POST lives here rather than a third
# time. BODY_JSON is for Lidarr, whose root folders carry the defaults applied
# to new artists; everything else needs only the path.
add_root_folder() {
  local key=$1 url=$2 root=$3 v=${4:-v3} body=${5:-}
  if arr "$key" GET "$url/api/$v/rootfolder" | jq -e --arg p "$root" 'any(.[]; .path == $p)' >/dev/null; then
    skip "root folder $root"; return 0
  fi
  [[ -n "$body" ]] || body=$(jq -cn --arg p "$root" '{path:$p}')
  arr "$key" POST "$url/api/$v/rootfolder" "$body" >/dev/null
  ok "root folder $root"
}

# rating_for <entry-json> -> the parental rating a user should have today.
#
# `born` (YYYY-MM-DD) is preferred over a fixed `rating`, because a number
# written once goes stale in silence: a child given 9 keeps 9 on their twelfth
# birthday and nobody notices until they ask why something is missing. The
# rating is the Kijkwijzer step they have actually reached, recomputed on every
# run, so it moves on its own.
#
# `rating` still wins when both are present - an explicit number is someone
# overriding the ladder on purpose, which is the one case the age must not
# second-guess.
rating_for() {
  local entry=$1 born age
  local r; r=$(jq -r '.rating // empty' <<<"$entry")
  [[ -n "$r" ]] && { printf '%s' "$r"; return 0; }
  born=$(jq -r '.born // empty' <<<"$entry")
  [[ -n "$born" ]] || return 0
  if ! [[ "$born" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "   WARN born \"$born\" is not YYYY-MM-DD - no rating applied" >&2; return 0
  fi
  # Whole years only: date arithmetic in days then divided would make a child
  # 9 for a few hours before their birthday.
  age=$(( ( $(date +%Y%m%d) - ${born//-/} ) / 10000 ))
  (( age >= 0 )) || { echo "   WARN born \"$born\" is in the future - no rating applied" >&2; return 0; }
  # The Kijkwijzer ladder: the highest step they are old enough for.
  local step
  for step in 18 16 14 12 9 6; do
    (( age >= step )) && { printf '%s' "$step"; return 0; }
  done
  printf '0'
}
