#!/usr/bin/env bash
# Replace, strictly one film at a time, every film whose audio layout breaks
# playback on the televisions here. Two faults, both read from the *file* rather
# than from the release name:
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
# ---------------------------------------------------------------- why it picks
# This does NOT ask Radarr to search and let it choose. Radarr chooses by score,
# and the score cannot be made to prefer a decodable release reliably: the guides'
# release-group tiers run 1600-1800 while the audio and source preference tops out
# at 470, so a DTS release that happens to sit in a tier beats an EAC3 one that does
# not. Measured on Inside Out: "Inside.Out.2015.1080p.BluRay.x264.DTS-iFT" scored
# 1750 on HD Bluray Tier 02 against 450 for a DD+ WEB-DL. An auto-search would have
# replaced DTS with DTS.
#
# So the candidate is chosen here, by what the release *names* about its audio, and
# grabbed by hand. A manual grab also overrides the rejection that blocks the whole
# exercise otherwise: Radarr compares quality and *revision* before custom-format
# score, so a PROPER file (15 of these 60) refuses every v1 release no matter how
# much better its audio is. POST /api/v3/release answers 200 anyway, which is why
# nothing here has to delete a file first.
#
# ---------------------------------------------------------------- the pacing
# Several films in flight at once - REGRAB_MAX_INFLIGHT, matching the download
# client's own slots - because the thing to avoid is not parallelism, it is the disk
# filling with replacements while the originals are still on it.
#
# So the gate is free space, and when space is short this *runs the mover itself*
# rather than waiting for its hourly timer. That is only safe because mover.sh now
# takes a lock: a run started here while the timer's run is going declines and says
# so, instead of two movers each helping themselves to ARCHIVE_MAX_GIB_PER_RUN.
# Without that, pushing to the cloud on demand would be the bug this stack already
# had once, when the VFS cache went 17 percent past its ceiling.
#
# The list is recomputed every pass, so a film that has been fixed drops out by
# itself and the run is resumable: stop it, start it again, nothing repeats.
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
# A film with no decodable release available would otherwise be retried for ever,
# because the fault never clears. Three attempts, then it is left alone and named.
MAX_TRIES=${REGRAB_MAX_TRIES:-3}
STATE=${REGRAB_STATE:-backups/audio-regrab-tries.tsv}
DRY_RUN=${DRY_RUN:-0}
# How many of our replacements may be downloading at once. Defaults to the client's
# own download slots, so the script does not queue work the client will not start.
MAX_INFLIGHT=${REGRAB_MAX_INFLIGHT:-${TORRENT_MAX_ACTIVE_DOWNLOADS:-3}}
POLL=${REGRAB_POLL_SECONDS:-60}
WANT_LANG=${REGRAB_WANT_LANG:-eng}
BAD_CODECS=${REGRAB_BAD_CODECS:-"dts truehd"}
# Radarr's names for audio the televisions decode, and the ones they cannot. A
# candidate must name one of the first and none of the second: a release that names
# no codec at all is skipped, because unknown is exactly what got us here.
SAFE_FORMATS=${REGRAB_SAFE_FORMATS:-"DD+ ATMOS|DD+|DD|AAC"}
UNSAFE_FORMATS=${REGRAB_UNSAFE_FORMATS:-"DTS|DTS-ES|DTS-HD HRA|DTS-HD MA|DTS X|TrueHD|TrueHD ATMOS|FLAC|PCM"}

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
free_gib() { df -BG --output=avail ./data/local | tail -1 | tr -dc '0-9'; }

rad() {                           # rad PATH  -> body on stdout
  curl -fsS -m 120 -H "X-Api-Key: $KEY" "$RADARR/api/v3/$1" 2>/dev/null
}

tries_of() {
  [[ -f "$STATE" ]] || { echo 0; return 0; }
  awk -F'\t' -v k="$1" '$1 == k { print $2; f=1 } END { if (!f) print 0 }' "$STATE" | head -1
}
bump_tries() {
  local n; n=$(tries_of "$1"); n=$(( n + 1 ))
  mkdir -p "$(dirname "$STATE")"
  if [[ -f "$STATE" ]]; then
    awk -F'\t' -v k="$1" -v n="$n" 'BEGIN{OFS="\t"} $1 == k { next } { print } END { print k, n }' \
      "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  else
    printf '%s\t%s\n' "$1" "$n" > "$STATE"
  fi
}

# Films needing replacement, most-watched first by TMDB vote count so the ones the
# family actually plays are fixed first. "RADARRID<TAB>TMDBID<TAB>WHY<TAB>TITLE".
eligible() {                      # eligible JELLYFIN_TOKEN
  local token=$1 tmp jf rad_f
  # Both answers go through files and --slurpfile, never --argjson: one argument
  # caps at 128 KB and the Jellyfin probe is 1.8 MB here, which hangs rather than
  # failing cleanly. Same rule as the arr bodies in lib/common.sh.
  tmp=$(mktemp -d); jf=$tmp/jf.json; rad_f=$tmp/rad.json
  curl -fsS -m 120 -H "Authorization: MediaBrowser Token=\"$token\"" \
       "$JELLYFIN/Items?Recursive=true&IncludeItemTypes=Movie&Fields=MediaStreams,Path&Limit=5000" \
       -o "$jf" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  curl -fsS -m 60 -H "X-Api-Key: $KEY" "$RADARR/api/v3/movie" -o "$rad_f" 2>/dev/null \
    || { rm -rf "$tmp"; return 1; }
  jq -e 'type == "object" and (.Items | type == "array")' >/dev/null 2>&1 < "$jf" \
    || { rm -rf "$tmp"; return 1; }
  jq -e 'type == "array"' >/dev/null 2>&1 < "$rad_f" || { rm -rf "$tmp"; return 1; }
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
    | .[] | "\(.id)\t\(.tmdb)\t\(.why)\t\(.title)"' < "$rad_f"
  rm -rf "$tmp"
}

# The best decodable release for one film, or nothing. Prints "GUID<TAB>INDEXERID<TAB>TITLE".
pick_release() {                  # pick_release MOVIEID
  local body; body=$(rad "release?movieId=$1") || return 1
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$body" || return 1
  jq -r --arg safe "$SAFE_FORMATS" --arg unsafe "$UNSAFE_FORMATS" '
    ($safe   | split("|")) as $S
    | ($unsafe | split("|")) as $U
    | [ .[]
        # Either clean, or refused only because a file is already there - which is
        # the whole point, and which a manual grab overrides.
        | select((.rejections | length) == 0
                 or all(.rejections[]; test("Existing file on disk")))
        | . as $r
        | ([ (.customFormats // [])[].name ]) as $f
        | select(($f | any(. as $n | $S | index($n))) and (($f | any(. as $n | $U | index($n))) | not))
        # A torrent nobody is seeding is not a candidate; usenet reports no seeders.
        | select(.protocol != "torrent" or ((.seeders // 0) > 0))
      ]
    | sort_by(.customFormatScore, (.seeders // 0)) | reverse
    | .[0] // empty
    | "\(.guid)\t\(.indexerId)\t\(.title)"' <<<"$body"
}

grab() {                          # grab GUID INDEXERID -> http code
  jq -cn --arg g "$1" --argjson i "$2" '{guid:$g, indexerId:$i}' \
  | curl -fsS -m 120 -o /dev/null -w '%{http_code}' -X POST -H "X-Api-Key: $KEY" \
      -H 'Content-Type: application/json' --data-binary @- "$RADARR/api/v3/release"
}

# How many downloads Radarr is holding right now. An empty or unreadable answer
# must read as "cannot tell", never as zero, or the gate opens exactly when the
# queue is in trouble.
in_flight() {
  local q; q=$(rad "queue?pageSize=200")
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$q" || { echo 9999; return 0; }
  jq -r '[.records[]? | select((.status // "") != "completed")] | length' <<<"$q"
}

file_id_of() {                    # file_id_of MOVIEID -> movieFileId or empty
  rad "movie/$1" | jq -r '.movieFile.id // empty'
}

token=$(curl -fsS -m 30 -X POST -H 'Content-Type: application/json' \
  -H 'Authorization: MediaBrowser Client="audio-regrab", Device="script", DeviceId="audio-regrab", Version="1"' \
  -d "$(jq -cn --arg u "${WEBUI_USERNAME:-}" --arg p "${WEBUI_PASSWORD:-}" '{Username:$u, Pw:$p}')" \
  "$JELLYFIN/Users/AuthenticateByName" 2>/dev/null | jq -r '.AccessToken // empty')
[[ -n "$token" ]] || { echo "could not authenticate to Jellyfin (WEBUI_USERNAME/WEBUI_PASSWORD)"; exit 1; }

log "audio-regrab starting: want $WANT_LANG first, refusing [$BAD_CODECS]"
log "  up to $MAX_INFLIGHT in flight, warn mark $WARN GiB, cloud pushed on every film; at most $MAX_TRIES tries per film"
(( DRY_RUN )) && log "  DRY_RUN=1 - choosing and reporting only, nothing is grabbed"

pass=0 skipped=''
while :; do
  pass=$(( pass + 1 ))
  list=$(eligible "$token") || { log "could not read the library - retrying in 5m"; sleep 300; continue; }
  n=$(printf '%s' "$list" | grep -c . || true)
  (( n == 0 )) && { log "nothing left to replace - done after $pass passes"; break; }
  log "pass $pass: $n films still have audio the televisions cannot play"

  acted=0
  while IFS=$'\t' read -r id tmdb why title; do
    [[ -n "${id:-}" ]] || continue
    tries=$(tries_of "$tmdb")
    if (( tries >= MAX_TRIES )); then
      case "$skipped" in *"|$tmdb|"*) ;; *) skipped+="|$tmdb|"; log "giving up on $title ($why) after $tries tries" ;; esac
      continue
    fi

    pick=$(pick_release "$id") || pick=''
    if [[ -z "$pick" ]]; then
      bump_tries "$tmdb"
      log "no decodable release offered for $title ($why) - try $(tries_of "$tmdb") of $MAX_TRIES"
      acted=1
      continue
    fi
    IFS=$'\t' read -r guid ixid rtitle <<<"$pick"

    if (( DRY_RUN )); then
      printf '  %-40s %-20s -> %s\n' "${title:0:40}" "$why" "${rtitle:0:62}"
      acted=1
      continue
    fi

    # The gate: room on the disk, and no more than MAX_INFLIGHT of our own
    # replacements already downloading. Whenever either is tight, push to the cloud
    # rather than sit and wait for the hourly timer - that is the difference between
    # a pipeline and a stall.
    while :; do
      free=$(free_gib); flight=$(in_flight)
      (( free > WARN )) && (( flight < MAX_INFLIGHT )) && break
      log "holding: free ${free} GiB (warn $WARN), $flight of $MAX_INFLIGHT in flight - pushing to the cloud"
      ./mover.sh >/dev/null 2>&1 || log "  mover declined or failed; will retry"
      sleep "$POLL"
    done

    before=$(file_id_of "$id")
    code=$(grab "$guid" "$ixid") || code=000
    bump_tries "$tmdb"
    log "grabbed [$code] $title ($why, try $(tries_of "$tmdb") of $MAX_TRIES)"
    log "  -> $rtitle"
    acted=1
    [[ "$code" == 2* ]] || { log "  grab refused - moving on"; continue; }

    # Keep the cloud moving on every film, not only when space runs short: the
    # originals are what is being replaced, so there is always something to send.
    ./mover.sh >/dev/null 2>&1 || true
  done <<<"$list"

  # Every remaining film is over its try limit, so another pass would only spin.
  (( acted )) || { log "every remaining film is over its try limit - stopping"; break; }
  (( DRY_RUN )) && break
done
log "audio-regrab finished"
