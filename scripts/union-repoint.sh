#!/usr/bin/env bash
# One-time: move every title off the /data/archive root folders onto /data/media.
#
# Not a file move. Under the union a title that physically lives on the cloud
# branch is already reachable at /data/media/<lib>/<title>, so this only corrects
# the database - moveFiles is false and not a byte is read or written. The old
# root folders are then removed so nothing lands back on them.
#
# Idempotent: with nothing left on an archive root it says so and stops.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; . ./.env; set +a
CONFIG_ROOT=${CONFIG_ROOT:-./config}
say() { printf '  %s\n' "$*"; }
api() { curl -fsS -m 60 -H "X-Api-Key: $2" "${@:3}" "http://localhost:$1"; }

key_of() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$CONFIG_ROOT/$1/config.xml"; }

# app  port  apiver  resource  idfield  archive root        media root
while read -r app port v res idf from to; do
  [[ -n "$app" ]] || continue
  key=$(key_of "$app") || { say "$app: no api key, skipping"; continue; }
  ids=$(api "$port/api/$v/$res" "$key" | jq -c --arg r "$from" '[.[] | select(.rootFolderPath == $r) | .id]')
  n=$(jq length <<<"$ids")
  if (( n == 0 )); then
    say "$app: nothing left on $from"
  else
    api "$port/api/$v/$res/editor" "$key" -X PUT -H 'Content-Type: application/json' \
      -d "$(jq -cn --argjson ids "$ids" --arg k "$idf" --arg to "$to" \
            '{($k): $ids, rootFolderPath: $to, moveFiles: false}')" >/dev/null
    say "$app: repointed $n title(s) from $from to $to (no files moved)"
  fi
  # The archive root folder goes once nothing points at it.
  rid=$(api "$port/api/$v/rootfolder" "$key" | jq -r --arg r "$from" 'first(.[] | select(.path == $r)) | .id // empty')
  if [[ -n "$rid" ]]; then
    still=$(api "$port/api/$v/$res" "$key" | jq --arg r "$from" '[.[] | select(.rootFolderPath == $r)] | length')
    if (( still == 0 )); then
      api "$port/api/$v/rootfolder/$rid" "$key" -X DELETE >/dev/null && say "$app: removed the root folder $from"
    else
      say "$app: $still title(s) still on $from, leaving the root folder in place"
    fi
  fi
done <<'APPS'
sonarr 8989 v3 series  seriesIds /data/archive/tv     /data/media/tv
radarr 7878 v3 movie   movieIds  /data/archive/movies /data/media/movies
lidarr 8686 v1 artist  artistIds /data/archive/music  /data/media/music
APPS

# Radarr and Sonarr derive a file's path from rootFolderPath + relativePath, so
# the repoint above is enough for them. Lidarr stores absolute track paths and
# drops every record whose path has gone - the artists survive, their files do
# not, and it reports 0 of N tracks with no health error. The files are still
# there and readable, so a rescan re-imports them; without it the library looks
# empty and Lidarr will happily re-download what it already has.
say "rescanning Lidarr - it loses its track records when a root folder changes"
lkey=$(key_of lidarr) || lkey=""
if [[ -n "$lkey" ]]; then
  for id in $(api 8686/api/v1/artist "$lkey" | jq -r '.[].id'); do
    api 8686/api/v1/command "$lkey" -X POST -H 'Content-Type: application/json' \
      -d "$(jq -cn --argjson i "$id" '{name:"RefreshArtist", artistId:$i}')" >/dev/null
  done
  api 8686/api/v1/command "$lkey" -X POST -H 'Content-Type: application/json' \
    -d '{"name":"RescanFolders"}' >/dev/null
  say "  queued; Lidarr reports 0 of N tracks until it finishes"
fi

say "done - verify with: ./scripts/union-verify.sh"
