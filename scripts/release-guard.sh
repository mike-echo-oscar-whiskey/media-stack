#!/usr/bin/env bash
# Release guard, run by Radarr and Sonarr as a "Custom Script" connection
# (mounted read-only at /scripts, wired by configure.sh). Two checks:
#
#   On Grab      a film whose digital/physical release is still ahead, or an
#                episode that has not aired, cannot have a genuine release:
#                the grab is removed from the queue and blocklisted before
#                a byte is downloaded.
#   On Import    the file's duration is compared with the runtime TMDb/TVDB
#                give. Far off (shorter than 65 % or longer than 160 %) means
#                a fake or mislabelled upload: the grab is marked as failed
#                (blocklisted), the file deleted, and a new search started.
#
# Everything goes through the app's own API on localhost with the key from
# its config.xml. GUARD_DRY_RUN=1 prints the decision without acting.
set -euo pipefail

# The arr apps build the variables as Radarr_EventType etc. but hand them over
# lower-cased (a .NET StringDictionary), so they must be read as such.
if [[ -n "${radarr_eventtype:-}" ]]; then
  APP=radarr; API=http://localhost:7878/api/v3; EVENT=$radarr_eventtype
elif [[ -n "${sonarr_eventtype:-}" ]]; then
  APP=sonarr; API=http://localhost:8989/api/v3; EVENT=$sonarr_eventtype
else
  echo "release-guard: not started by Radarr or Sonarr"; exit 0
fi
KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' /config/config.xml)
DRY=${GUARD_DRY_RUN:-0}
LOGFILE=/config/release-guard.log
MIN_RATIO=${GUARD_MIN_RATIO:-0.65}
MAX_RATIO=${GUARD_MAX_RATIO:-1.60}

api() { curl -fsS -H "X-Api-Key: $KEY" "$@"; }
log() { local line; line="$(date '+%F %T')  $*"; echo "release-guard: $*"; (( DRY )) || echo "$line" >> "$LOGFILE"; }
act() { (( DRY )) && { echo "release-guard: (dry run) would: $*"; return 0; }; "$@"; }
to_seconds() {                    # "1:39:44" or "39:44" -> seconds; empty -> 0
  local t=$1 h=0 m=0 s=0
  [[ -n "$t" ]] || { echo 0; return; }
  IFS=: read -r a b c <<<"$t"
  if [[ -n "${c:-}" ]]; then h=$a; m=$b; s=${c%%.*}; else m=$a; s=${b%%.*}; fi
  echo $(( 10#$h * 3600 + 10#$m * 60 + 10#$s ))
}
future() { [[ -n "$1" && "$1" != null && "${1%%T*}" > "$(date -u +%F)" ]]; }

# --- queue removal + blocklist by download id (both apps) ------------------
drop_from_queue() {               # drop_from_queue DOWNLOAD_ID WHY
  local did=$1 why=$2 qid i
  # The grab event fires before the app has seen the download in its client;
  # ask for a refresh and give the queue up to two minutes to list it.
  act api -o /dev/null -X POST -H 'Content-Type: application/json' "$API/command" -d '{"name":"RefreshMonitoredDownloads"}'
  for i in $(seq 1 12); do
    qid=$(api "$API/queue?pageSize=200" | jq -r --arg d "$did" 'first(.records[] | select((.downloadId // "" | ascii_downcase) == ($d | ascii_downcase))) | .id // empty')
    [[ -n "$qid" ]] && break
    (( DRY )) && break
    sleep 10
  done
  if [[ -n "$qid" ]]; then
    act api -o /dev/null -X DELETE "$API/queue/$qid?removeFromClient=true&blocklist=true&skipRedownload=true"
    log "REMOVED and blocklisted: $why"
    return
  fi
  # Not in the queue after two minutes: blocklist through the grab record
  # instead. That may make the app search again; the next grab comes back
  # here, and the self-healing timer evicts the torrent from the client.
  local grab
  grab=$(api "$API/history?pageSize=50&eventType=1" | jq -r --arg d "$did" 'first(.records[] | select((.downloadId // "" | ascii_downcase) == ($d | ascii_downcase))) | .id // empty')
  if [[ -n "$grab" ]]; then
    act api -o /dev/null -X POST "$API/history/failed/$grab"
    log "BLOCKLISTED via history (never showed in the queue): $why"
  else
    log "could not blocklist $did: neither in the queue nor in history ($why)"
  fi
}

case "$EVENT" in
  Test) echo "release-guard: test ok ($APP)"; exit 0 ;;

  Grab)
    if [[ $APP == radarr ]]; then
      m=$(api "$API/movie/$radarr_movie_id")
      digital=$(jq -r '.digitalRelease // empty' <<<"$m"); physical=$(jq -r '.physicalRelease // empty' <<<"$m"); cinema=$(jq -r '.inCinemas // empty' <<<"$m")
      # Earliest home release known; otherwise the cinema date is the floor.
      floor=""
      for d in "$digital" "$physical"; do [[ -n "$d" ]] && { [[ -z "$floor" || "$d" < "$floor" ]] && floor=$d; }; done
      [[ -n "$floor" ]] || floor=$cinema
      if future "$floor"; then
        drop_from_queue "$radarr_download_id" "$radarr_movie_title ($radarr_movie_year): not out before ${floor%%T*}, so \"$radarr_release_title\" cannot be genuine"
      else
        log "grab ok: $radarr_movie_title ($radarr_movie_year) is released (${floor%%T*})"
      fi
    else
      unaired=""
      IFS=, read -r -a dates <<<"${sonarr_release_episodeairdatesutc:-}"
      for d in "${dates[@]}"; do future "$d" && unaired="$d"; done
      # An empty list is not "it has aired", it is "Sonarr told us nothing" -
      # and the loop above cannot tell those apart, which is how a release of
      # an episode four days in the future was grabbed on 2026-09-24. Ask the
      # API for the air dates instead, the same source the import check below
      # already trusts. Only when the variable was empty: a list that was
      # supplied has already been judged.
      if [[ -z "${dates[*]//[[:space:]]/}" && -n "${sonarr_series_id:-}" ]]; then
        eps=$(api "$API/episode?seriesId=$sonarr_series_id") || eps=""
        for n in ${sonarr_release_episodenumbers//,/ }; do
          d=$(jq -r --argjson s "${sonarr_release_seasonnumber:-0}" --argjson e "${n:-0}" \
                'first(.[] | select(.seasonNumber == $s and .episodeNumber == $e)) | .airDateUtc // empty' <<<"$eps" 2>/dev/null)
          future "$d" && unaired="$d"
        done
      fi
      if [[ -n "$unaired" ]]; then
        drop_from_queue "$sonarr_download_id" "$sonarr_series_title S${sonarr_release_seasonnumber}E${sonarr_release_episodenumbers}: airs ${unaired%%T*}, so \"$sonarr_release_title\" cannot be genuine"
      else
        log "grab ok: $sonarr_series_title S${sonarr_release_seasonnumber}E${sonarr_release_episodenumbers} has aired"
      fi
    fi ;;

  Download)                       # = import (the event Radarr/Sonarr call "On Import")
    released=1; unreleased_why=""
    if [[ $APP == radarr ]]; then
      m=$(api "$API/movie/$radarr_movie_id")
      expected=$(( $(jq -r '.runtime // 0' <<<"$m") * 60 ))
      file=$(api "$API/moviefile/$radarr_moviefile_id")
      what="$radarr_movie_title ($radarr_movie_year)"; did=$radarr_download_id; fileid=$radarr_moviefile_id
      if [[ $(jq -r '.isAvailable' <<<"$m") != true ]]; then
        released=0; unreleased_why=" not released yet (digital $(jq -r '.digitalRelease // "unknown" | .[:10]' <<<"$m")), so no genuine file can exist;"
      fi
    else
      expected=0; unaired=""
      IFS=, read -r -a ids <<<"${sonarr_episodefile_episodeids:-}"
      for id in "${ids[@]}"; do
        e=$(api "$API/episode/$id"); r=$(jq -r '.runtime // 0' <<<"$e"); expected=$(( expected + r * 60 ))
        future "$(jq -r '.airDateUtc // empty' <<<"$e")" && unaired=$(jq -r '.airDateUtc[:10]' <<<"$e")
      done
      (( expected > 0 )) || expected=$(( $(api "$API/series/$sonarr_series_id" | jq -r '.runtime // 0') * 60 * ${#ids[@]} ))
      file=$(api "$API/episodefile/$sonarr_episodefile_id")
      what="$sonarr_series_title S${sonarr_episodefile_seasonnumber}E${sonarr_episodefile_episodenumbers}"; did=$sonarr_download_id; fileid=$sonarr_episodefile_id
      [[ -n "$unaired" ]] && { released=0; unreleased_why=" airs $unaired, so no genuine file can exist;"; }
    fi
    [[ -n "${GUARD_EXPECTED_MINUTES:-}" ]] && expected=$(( GUARD_EXPECTED_MINUTES * 60 ))
    actual=$(to_seconds "$(jq -r '.mediaInfo.runTime // empty' <<<"$file")")
    # Radarr and Sonarr report the frame as "1920x804" in mediaInfo.resolution
    width=$(jq -r '(.mediaInfo.resolution // "0x0" | split("x")[0] | tonumber? // 0)' <<<"$file")
    height=$(jq -r '(.mediaInfo.resolution // "0x0" | split("x")[1] | tonumber? // 0)' <<<"$file")
    res=$(jq -r '.quality.quality.resolution // 0' <<<"$file")
    reason="$unreleased_why"
    # 0. date: before the release there is nothing to download; a cinema
    #    recording with the right length and frame passes the other two checks.
    # 1. length: a fan film or an AI "version" is never as long as the real thing
    if (( expected == 0 || actual == 0 )); then
      log "runtime unknown for $what (expected ${expected}s, file ${actual}s): no runtime verdict"
      ratio="?"
    else
      ratio=$(awk -v a="$actual" -v e="$expected" 'BEGIN{printf "%.2f", a/e}')
      awk -v r="$ratio" -v lo="$MIN_RATIO" -v hi="$MAX_RATIO" 'BEGIN{exit !(r < lo || r > hi)}' \
        && reason+=" runs $((actual/60)) min, expected $((expected/60)) min (ratio $ratio);"
    fi
    # 2. picture: the name said 1080p, so the frame must reach about 1920 wide
    # OR about 1080 high - cinemascope films are letterboxed (1920x800),
    # narrow ones pillarboxed (1620x1080). A 720p upscale sold as 1080p
    # (indexers tag some as REAL-720p) is 1280 wide and at most 720 high.
    if (( res > 0 && width > 0 && height > 0 )); then
      minw=$(( res * 16 / 9 * 85 / 100 )); minh=$(( res * 85 / 100 ))
      (( width < minw && height < minh )) && reason+=" picture is only ${width}x${height} for a ${res}p release;"
    fi
    if [[ -n "$reason" ]]; then
      # The grab record for this download: marking it failed blocklists the release.
      if [[ $APP == radarr ]]; then
        grab=$(api "$API/history/movie?movieId=$radarr_movie_id&eventType=1" | jq -r --arg d "$did" 'first(.[] | select((.downloadId // "" | ascii_downcase) == ($d | ascii_downcase))) | .id // empty')
      else
        grab=$(api "$API/history/series?seriesId=$sonarr_series_id&eventType=1" | jq -r --arg d "$did" 'first(.[] | select((.downloadId // "" | ascii_downcase) == ($d | ascii_downcase))) | .id // empty')
      fi
      [[ -n "$grab" ]] && act api -o /dev/null -X POST "$API/history/failed/$grab"
      # A new search only makes sense once the title is out; before that it
      # would just fetch the next fake. The nightly missing search takes over
      # after the release.
      if [[ $APP == radarr ]]; then
        act api -o /dev/null -X DELETE "$API/moviefile/$fileid"
        (( released )) && act api -o /dev/null -X POST -H 'Content-Type: application/json' "$API/command" -d "{\"name\":\"MoviesSearch\",\"movieIds\":[$radarr_movie_id]}"
      else
        act api -o /dev/null -X DELETE "$API/episodefile/$fileid"
        (( released )) && act api -o /dev/null -X POST -H 'Content-Type: application/json' "$API/command" -d "{\"name\":\"EpisodeSearch\",\"episodeIds\":[${sonarr_episodefile_episodeids}]}"
      fi
      log "REJECTED $what:$reason grab ${grab:-?} marked failed, file deleted, $( (( released )) && echo "new search started" || echo "no new search until the release" )"
    else
      log "import ok: $what runs $((actual/60)) min, expected $((expected/60)) min (ratio $ratio), ${width}x${height} for ${res}p"
    fi ;;

  *) echo "release-guard: ignoring event $EVENT" ;;
esac
