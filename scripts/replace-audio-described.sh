#!/usr/bin/env bash
# One-time repair: replace the files whose only audio track is the audio
# description - the narration of what is on screen, meant for blind and
# partially sighted viewers. There is no second track to switch to, so the file
# is simply the wrong one.
#
# The releases announce it ("... with Audio Description ...", "MULTi.AD."), and
# the guides' "WiTH AD" custom format now scores that -10000 in every managed
# profile, so nothing like it can be grabbed again. This only clears out what
# was taken before that format existed.
#
# Detection comes from Jellyfin rather than from the release name, because the
# apps rename on import and the file on disk no longer says anything. Jellyfin
# has already probed every file, so this reads no media - which matters, since
# a file on the archive branch would otherwise be pulled back off the cloud.
#
# DRY_RUN=1 prints the plan and changes nothing.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
DRY=${DRY_RUN:-0}

apikey() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "config/$1/config.xml"; }
son() { curl -fsS -H "X-Api-Key: $(apikey sonarr)" "$@"; }
rad() { curl -fsS -H "X-Api-Key: $(apikey radarr)" "$@"; }
SON=http://localhost:8989/api/v3
RAD=http://localhost:7878/api/v3
act() { (( DRY )) && { echo "      (dry run) would: $*"; return 0; }; "$@" >/dev/null; }

# Jellyfin's own probe. Authenticating with the shared Web UI login rather than
# an API key, because configure.sh does not store one for scripts to reuse.
jf_token() {
  curl -fsS -X POST -H 'Content-Type: application/json' \
    -H 'Authorization: MediaBrowser Client="media-stack", Device="script", DeviceId="replace-ad", Version="1"' \
    -d "{\"Username\":\"$WEBUI_USERNAME\",\"Pw\":\"$WEBUI_PASSWORD\"}" \
    http://localhost:8096/Users/AuthenticateByName | jq -r '.AccessToken // empty'
}

TOKEN=$(jf_token)
[[ -n "$TOKEN" ]] || { echo "could not authenticate to Jellyfin" >&2; exit 1; }

# One audio track, and its title says it is the description. Both conditions:
# a descriptive track beside a normal one is a choice, not a defect.
paths=$(curl -fsS -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
  'http://localhost:8096/Items?Recursive=true&IncludeItemTypes=Episode,Movie&Fields=MediaStreams,Path&Limit=5000' \
  | jq -r '.Items[]
           | select([.MediaStreams[] | select(.Type=="Audio")] | length == 1)
           | select([.MediaStreams[] | select(.Type=="Audio" and ((.Title // "") | test("descript"; "i")))] | length > 0)
           | .Path')

# An empty answer here is "nothing matched", but an empty answer from a failed
# query looks identical - so refuse to treat a missing library as a clean one.
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$(curl -fsS -H "Authorization: MediaBrowser Token=\"$TOKEN\"" \
     'http://localhost:8096/Items?Recursive=true&IncludeItemTypes=Episode&Limit=1' | jq -c '.Items')"; then
  echo "Jellyfin did not answer with an item list - refusing to act" >&2; exit 1
fi
[[ -n "$paths" ]] || { echo "nothing to replace"; exit 0; }
echo "$(wc -l <<<"$paths") file(s) whose only audio track is the description"

AD_RE='([Ww]ith[ ._-]Audio[ ._-]Description|MULTi[ ._-]AD|\bWiTH[ ._-]AD\b)'
episode_ids=(); movie_ids=()

while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  echo "  $(basename "$path")"
  if [[ $path == */tv/* ]]; then
    # The series root has to be bound before the comparison: inside
    # `$p | startswith(...)` the dot is the string, so `.path` there indexes a
    # string and jq dies with "Cannot index string with string".
    sid=$(son "$SON/series" | jq -r --arg p "$path" \
          'first(.[] | select(.path != null) | select(.path as $root | $p | startswith($root + "/")) | .id) // empty')
    [[ -n "$sid" ]] || { echo "      no Sonarr series owns that path - skipped"; continue; }
    fid=$(son "$SON/episodefile?seriesId=$sid" | jq -r --arg p "$path" 'first(.[] | select(.path == $p) | .id) // empty')
    [[ -n "$fid" ]] || { echo "      not found in Sonarr - skipped"; continue; }
    eids=$(son "$SON/episode?seriesId=$sid" | jq -c --argjson f "$fid" '[.[] | select(.episodeFileId == $f) | .id]')
    for eid in $(jq -r '.[]' <<<"$eids"); do
      episode_ids+=("$eid")
      hid=$(son "$SON/history?episodeId=$eid&eventType=1&pageSize=50" \
            | jq -r --arg re "$AD_RE" 'first(.records[] | select(.sourceTitle | test($re)) | .id) // empty')
      [[ -n "$hid" ]] && act son -X POST "$SON/history/failed/$hid"
    done
    act son -X DELETE "$SON/episodefile/$fid"
  else
    mid=$(rad "$RAD/movie" | jq -r --arg p "$path" 'first(.[] | select(.movieFile.path == $p) | .id) // empty')
    [[ -n "$mid" ]] || { echo "      not found in Radarr - skipped"; continue; }
    fid=$(rad "$RAD/movie/$mid" | jq -r '.movieFile.id')
    movie_ids+=("$mid")
    hid=$(rad "$RAD/history?movieId=$mid&eventType=1&pageSize=50" \
          | jq -r --arg re "$AD_RE" 'first(.records[] | select(.sourceTitle | test($re)) | .id) // empty')
    [[ -n "$hid" ]] && act rad -X POST "$RAD/history/failed/$hid"
    act rad -X DELETE "$RAD/moviefile/$fid"
  fi
done <<<"$paths"

# One search per app at the end, not one per file: each call wakes every
# indexer, and a search per episode is what earns a rate limit.
if (( ${#episode_ids[@]} )); then
  ids=$(printf '%s\n' "${episode_ids[@]}" | jq -R . | jq -sc 'map(tonumber)')
  act son -X POST -H 'Content-Type: application/json' \
    --data "{\"name\":\"EpisodeSearch\",\"episodeIds\":$ids}" "$SON/command"
  echo "sonarr: search started for ${#episode_ids[@]} episode(s)"
fi
if (( ${#movie_ids[@]} )); then
  ids=$(printf '%s\n' "${movie_ids[@]}" | jq -R . | jq -sc 'map(tonumber)')
  act rad -X POST -H 'Content-Type: application/json' \
    --data "{\"name\":\"MoviesSearch\",\"movieIds\":$ids}" "$RAD/command"
  echo "radarr: search started for ${#movie_ids[@]} film(s)"
fi
