#!/usr/bin/env bash
# Replace, one film at a time, every film whose audio layout breaks playback on
# the televisions here. Two faults, both read from the *file* rather than from the
# release name:
#
#   - the first audio track is DTS or TrueHD, which a Samsung Tizen set cannot
#     decode, so Plex transcodes the audio while passing the video through
#   - the first audio track is some other language with English behind it, which
#     the set cannot select, so Plex transcodes to put English first
#
# Either way the result is video-direct-plus-audio-transcode, which freezes - see
# the Plex entry under Traps in AGENTS.md. Encanto ran 64 minutes that way and died.
#
# Why the file and not the release title: the audio custom formats match the title,
# and measured over these 196 films 36% of titles name no codec at all - 17 of those
# silent ones turned out to be DTS or TrueHD, Encanto among them. Jellyfin probes
# every file on import and keeps the ordered stream list, so it is the only source
# that knows the truth, and reading it costs one API call and no media reads. That
# matters: most of this library lives on the archive branch and probing it directly
# would pull it back off the cloud.
#
# One at a time, because a blanket search would grab sixty films at once - 575 GiB
# of new downloads beside the copies already on disk - which is the thing the
# download caps and the disk brake exist to prevent. The list is recomputed every
# pass, so a film that has been fixed drops out by itself and the run is resumable:
# stop it, start it again, nothing repeats.
#
# Radarr only. Sonarr holds none of the audio custom formats and its profiles are
# WEB, where DTS does not appear; 17 of 319 episodes carry TrueHD and that is left
# for now (see lib/profiles.sh).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[[ -f .env ]] && { set -a; . ./.env; set +a; }

RADARR=http://127.0.0.1:7878
JELLYFIN=http://127.0.0.1:8096
KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/radarr/config.xml)
[[ -n "$KEY" ]] || { echo "no Radarr API key"; exit 1; }

WARN=${DISK_WARN_GIB:-150}
MAX_QUEUE=${REGRAB_MAX_QUEUE:-2}
GAP=${REGRAB_GAP_SECONDS:-180}
# A film with no decodable release available would otherwise be searched for ever,
# because the fault never clears. Three attempts, then it is left alone and named
# at the end: nothing here can fix a film nobody has released properly.
MAX_TRIES=${REGRAB_MAX_TRIES:-3}
STATE=${REGRAB_STATE:-backups/audio-regrab-tries.tsv}
DRY_RUN=${DRY_RUN:-0}
# ISO 639-2, as Jellyfin stores it. The language the audio should be in.
WANT_LANG=${REGRAB_WANT_LANG:-eng}
# Codecs the televisions cannot decode, lowercase, space separated.
BAD_CODECS=${REGRAB_BAD_CODECS:-"dts truehd"}

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

free_gib() { df -BG --output=avail ./data/local | tail -1 | tr -dc '0-9'; }

queue_len() {
  local q
  q=$(curl -fsS -m 30 -H "X-Api-Key: $KEY" "$RADARR/api/v3/queue?pageSize=200" 2>/dev/null)
  # An empty answer is not a negative one: cannot-tell must not read as empty, or
  # the hold below is skipped exactly when the queue is in trouble.
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$q" || { echo 9999; return 0; }
  jq -r '.totalRecords' <<<"$q"
}

jf_token() {
  curl -fsS -m 30 -X POST -H 'Content-Type: application/json' \
    -H 'Authorization: MediaBrowser Client="audio-regrab", Device="script", DeviceId="audio-regrab", Version="1"' \
    -d "$(jq -cn --arg u "${WEBUI_USERNAME:-}" --arg p "${WEBUI_PASSWORD:-}" '{Username:$u, Pw:$p}')" \
    "$JELLYFIN/Users/AuthenticateByName" 2>/dev/null | jq -r '.AccessToken // empty'
}

tries_of() {                      # tries_of TMDBID -> count
  [[ -f "$STATE" ]] || { echo 0; return 0; }
  awk -F'\t' -v k="$1" '$1 == k { print $2; found=1 } END { if (!found) print 0 }' "$STATE" | head -1
}

bump_tries() {                    # bump_tries TMDBID
  local n; n=$(tries_of "$1"); n=$(( n + 1 ))
  mkdir -p "$(dirname "$STATE")"
  if [[ -f "$STATE" ]]; then
    awk -F'\t' -v k="$1" -v n="$n" 'BEGIN{OFS="\t"} $1 == k { next } { print } END { print k, n }' \
      "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  else
    printf '%s\t%s\n' "$1" "$n" > "$STATE"
  fi
}

# Films needing replacement, worst-watched-first so the ones the family actually
# plays are fixed first. Prints "RADARRID<TAB>TMDBID<TAB>WHY<TAB>TITLE".
eligible() {                      # eligible JELLYFIN_TOKEN
  local token=$1 tmp jf rad
  # Both answers go through files and --slurpfile, never --argjson: one argument
  # caps at 128 KB and the Jellyfin probe is 1.8 MB here, which hangs rather than
  # failing cleanly. Same rule as the arr bodies in lib/common.sh.
  tmp=$(mktemp -d); jf=$tmp/jf.json; rad=$tmp/rad.json
  curl -fsS -m 120 -H "Authorization: MediaBrowser Token=\"$token\"" \
       "$JELLYFIN/Items?Recursive=true&IncludeItemTypes=Movie&Fields=MediaStreams,Path&Limit=5000" \
       -o "$jf" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  curl -fsS -m 60 -H "X-Api-Key: $KEY" "$RADARR/api/v3/movie" -o "$rad" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  jq -e 'type == "object" and (.Items | type == "array")' >/dev/null 2>&1 < "$jf" \
    || { rm -rf "$tmp"; return 1; }
  jq -e 'type == "array"' >/dev/null 2>&1 < "$rad" || { rm -rf "$tmp"; return 1; }
  jq -r --slurpfile probe "$jf" --arg want "$WANT_LANG" --arg bad "$BAD_CODECS" '
    ($bad | split(" ") | map(select(length > 0))) as $badlist
    | ( [ $probe[0].Items[]
          | { tmdb: ((.Path // "") | capture("\\{tmdb-(?<i>[0-9]+)\\}").i | tonumber?),
              au:   [ .MediaStreams[]? | select(.Type == "Audio") ] }
          | select(.tmdb != null and (.au | length) > 0)
          | { tmdb: .tmdb,
              codec: ((.au[0].Codec // "") | ascii_downcase),
              lang:  (.au[0].Language // "und"),
              haswant: ([ .au[] | select((.Language // "") == $want) ] | length > 0) } ]
        | INDEX(.tmdb | tostring) ) as $pr
    | [ .[]
        | select(.hasFile)
        | . as $m
        | ($pr[$m.tmdbId | tostring]) as $p
        | select($p != null)
        | ( if ($badlist | index($p.codec)) then "codec:" + $p.codec
            elif ($p.lang != $want and $p.haswant) then "first-track:" + $p.lang
            else null end ) as $why
        | select($why != null)
        | { id: $m.id, tmdb: $m.tmdbId, why: $why, title: $m.title,
            votes: ($m.ratings.tmdb.votes // 0) } ]
    | sort_by(.votes) | reverse
    | .[] | "\(.id)\t\(.tmdb)\t\(.why)\t\(.title)"' < "$rad"
  rm -rf "$tmp"
}

token=$(jf_token)
[[ -n "$token" ]] || { echo "could not authenticate to Jellyfin (WEBUI_USERNAME/WEBUI_PASSWORD)"; exit 1; }

log "audio-regrab starting: want $WANT_LANG first, refusing [$BAD_CODECS]"
log "  queue cap $MAX_QUEUE, warn mark $WARN GiB, gap ${GAP}s, at most $MAX_TRIES tries per film"
(( DRY_RUN )) && log "  DRY_RUN=1 - listing only, nothing will be searched"

pass=0 skipped=''
while :; do
  pass=$(( pass + 1 ))
  list=$(eligible "$token") || { log "could not read the library - retrying in 5m"; sleep 300; continue; }
  n=$(printf '%s' "$list" | grep -c . || true)
  (( n == 0 )) && { log "nothing left to replace - done after $pass passes"; break; }
  log "pass $pass: $n films still have audio the televisions cannot play"

  acted=0
  while IFS=$'\t' read -r id tmdb why title; do
    [[ -z "${id:-}" ]] && continue
    tries=$(tries_of "$tmdb")
    if (( tries >= MAX_TRIES )); then
      case "$skipped" in *"|$tmdb|"*) ;; *) skipped+="|$tmdb|"; log "giving up on $title ($why) after $tries tries" ;; esac
      continue
    fi
    if (( DRY_RUN )); then
      printf '  would search: %-48s %-22s tries=%s\n' "${title:0:48}" "$why" "$tries"
      acted=1; continue
    fi
    # Hold while the queue is deep or the disk is under the warn mark. The mover
    # runs hourly and clears the local branch; this only waits for it.
    while :; do
      q=$(queue_len); f=$(free_gib)
      (( q <= MAX_QUEUE )) && (( f > WARN )) && break
      log "holding: queue=$q (cap $MAX_QUEUE) free=${f}GiB (warn $WARN)"
      sleep 300
    done
    code=$(curl -fsS -m 60 -o /dev/null -w '%{http_code}' -X POST \
            -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
            -d "$(jq -cn --argjson i "$id" '{name:"MoviesSearch", movieIds:[$i]}')" \
            "$RADARR/api/v3/command" 2>/dev/null)
    bump_tries "$tmdb"
    log "searched [$code] $title ($why, try $(tries_of "$tmdb") of $MAX_TRIES)"
    acted=1
    sleep "$GAP"
  done <<<"$list"

  # Every remaining film is over its try limit, so another pass would do nothing
  # but spin. Without this the loop never ends on a library holding one film that
  # has no decodable release anywhere.
  (( acted )) || { log "every remaining film is over its try limit - stopping"; break; }
  (( DRY_RUN )) && break
done
log "audio-regrab finished"
