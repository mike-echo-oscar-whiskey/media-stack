#!/usr/bin/env bash
# Ask Radarr or Sonarr what it makes of a release title, and optionally what a
# regex of yours would match, using the app's own parser instead of guessing.
#
#   ./scripts/probe-parser.sh radarr "Some.Movie.2026.1080p.BluRay.x264-GRP"
#   ./scripts/probe-parser.sh sonarr -r '\b(NLD|NL[ ._-]?Gesproken)\b' title...
#
# Without -r it prints the parsed quality, languages and the custom formats the
# app already matches. With -r it also creates a throwaway custom format holding
# that regex, reports which titles it catches, and deletes it again - which is
# the only honest way to test a pattern, because the engine is .NET's and not
# grep's.
#
# Why this exists: written by hand twice while building the junk guards and the
# dubbed-audio formats, and wrong the first time - this shell is zsh on the host,
# where `echo '\b'` eats the escape, so the regexes under test arrived mangled
# and matched nothing. A file with a bash shebang cannot make that mistake.
set -euo pipefail
cd "$(dirname "$0")/.."

app=${1:-}; shift || true
regex=""
if [[ "${1:-}" == -r ]]; then regex=${2:-}; shift 2 || true; fi

case "$app" in
  radarr) port=7878; v=v3 ;;
  sonarr) port=8989; v=v3 ;;
  *) echo "usage: $0 radarr|sonarr [-r REGEX] TITLE [TITLE...]" >&2; exit 2 ;;
esac
(( $# > 0 )) || { echo "usage: $0 radarr|sonarr [-r REGEX] TITLE [TITLE...]" >&2; exit 2; }

key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "config/$app/config.xml")
[[ -n "$key" ]] || { echo "no API key in config/$app/config.xml" >&2; exit 1; }
api() { curl -fsS -m 30 -H "X-Api-Key: $key" "http://localhost:$port/api/$v$1" "${@:2}"; }

probe_id=""
cleanup() { [[ -n "$probe_id" ]] && api "/customformat/$probe_id" -X DELETE -o /dev/null || true; }
trap cleanup EXIT

if [[ -n "$regex" ]]; then
  # One ReleaseTitleSpecification carrying the regex, scored nowhere, deleted on
  # the way out. del(.presets ...) because the schema ships tens of KB of them
  # and the POST does not want any of it.
  probe_id=$(api /customformat/schema | jq -c --arg re "$regex" '
      {name: "ZZ probe", includeCustomFormatWhenRenaming: false,
       specifications: [ first(.[] | select(.implementation == "ReleaseTitleSpecification"))
         | del(.presets, .infoLink, .implementationName)
         | .name = "probe" | .negate = false | .required = false
         | .fields |= map(if .name == "value" then .value = $re else . end) ]}' \
    | api /customformat -X POST -H 'Content-Type: application/json' --data-binary @- | jq -r .id)
  echo "probe format $probe_id holds: $regex"
  echo
fi

for title in "$@"; do
  parsed=$(api /parse -G --data-urlencode "title=$title")
  printf '%s\n' "$title"
  if [[ "$app" == radarr ]]; then
    printf '   quality   %s\n' "$(jq -r '.parsedMovieInfo.quality.quality.name // "?"' <<<"$parsed")"
    printf '   languages %s\n' "$(jq -r '[.parsedMovieInfo.languages[]?.name] | join(", ") // "-"' <<<"$parsed")"
  else
    printf '   quality   %s\n' "$(jq -r '.parsedEpisodeInfo.quality.quality.name // "?"' <<<"$parsed")"
    printf '   languages %s\n' "$(jq -r '[.parsedEpisodeInfo.languages[]?.name] | join(", ") // "-"' <<<"$parsed")"
  fi
  printf '   formats   %s\n' "$(jq -r '[.customFormats[]?.name] | join(", ") | if . == "" then "(none)" else . end' <<<"$parsed")"
  if [[ -n "$regex" ]]; then
    printf '   regex     %s\n' "$(jq -r 'if ([.customFormats[]?.name] | index("ZZ probe")) then "MATCHES" else "no match" end' <<<"$parsed")"
  fi
  echo
done
