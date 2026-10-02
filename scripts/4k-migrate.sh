#!/usr/bin/env bash
# Walk the films that sit on a 2160p profile holding a 1080p file and search
# them one at a time, waiting for the queue to drain and the disk to recover
# between each. A blanket CutoffUnmetMoviesSearch would grab all 155 at once,
# which is the thing the download caps and the disk brake exist to prevent.
#
# The list is recomputed every pass, so an upgraded film drops out by itself and
# the run is resumable: stop it, start it again, nothing repeats.
#
# Ordered by TMDB vote count, not by TMDB popularity. Popularity is a
# current-trending metric: it ranks this year's releases top, and those are the
# ones whose 4K pool is still leaks and screeners rather than a retail master.
# Measured on this library, the top five by popularity averaged 12 available 4K
# releases against 32 for the top five by vote count, and the worst case was 2
# against 15. A film with no votes yet sorts to the back by itself, which is
# what we want: ask the indexers for it later, when a retail 4K release exists.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[[ -f .env ]] && { set -a; . ./.env; set +a; }

RADARR=http://127.0.0.1:7878
KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/radarr/config.xml)
[[ -n "$KEY" ]] || { echo "no Radarr API key"; exit 1; }

WARN=${DISK_WARN_GIB:-150}
MAX_QUEUE=${MIGRATE_MAX_QUEUE:-3}
GAP=${MIGRATE_GAP_SECONDS:-120}
PROFILE=${MIGRATE_PROFILE_ID:-17}

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

free_gib() { df -BG --output=avail ./data/local | tail -1 | tr -dc '0-9'; }

queue_len() {
  local q
  q=$(curl -fsS -m 30 -H "X-Api-Key: $KEY" "$RADARR/api/v3/queue?pageSize=200" 2>/dev/null)
  # An empty answer is not a negative one: cannot-tell must not read as empty.
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$q" || { echo 9999; return 0; }
  jq -r '.totalRecords' <<<"$q"
}

eligible() {
  local m
  m=$(curl -fsS -m 60 -H "X-Api-Key: $KEY" "$RADARR/api/v3/movie" 2>/dev/null)
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$m" || return 1
  jq -r --argjson p "$PROFILE" '
    [.[] | select(.qualityProfileId == $p and .hasFile
                  and ((.movieFile.quality.quality.resolution // 0) < 2160))]
    | sort_by((.ratings.tmdb.votes // 0), (.popularity // 0)) | reverse
    | .[] | "\(.id)\t\(.title)"' <<<"$m"
}

log "4k-migrate starting: profile $PROFILE, queue cap $MAX_QUEUE, warn mark $WARN GiB, gap ${GAP}s"
pass=0
while :; do
  pass=$(( pass + 1 ))
  list=$(eligible) || { log "could not read the film list - retrying in 5m"; sleep 300; continue; }
  n=$(printf '%s' "$list" | grep -c . || true)
  (( n == 0 )) && { log "nothing left to migrate - done after $pass passes"; break; }
  log "pass $pass: $n films still holding a sub-4K file"

  while IFS=$'\t' read -r id title; do
    [[ -z "$id" ]] && continue
    # Hold while the queue is deep or the disk is under the warn mark. The mover
    # runs hourly and clears the local branch; this just waits for it.
    while :; do
      q=$(queue_len); f=$(free_gib)
      (( q <= MAX_QUEUE )) && (( f > WARN )) && break
      log "holding: queue=$q (cap $MAX_QUEUE) free=${f}GiB (warn $WARN)"
      sleep 300
    done
    code=$(curl -fsS -m 60 -o /dev/null -w '%{http_code}' -X POST \
            -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
            -d "{\"name\":\"MoviesSearch\",\"movieIds\":[$id]}" \
            "$RADARR/api/v3/command" 2>/dev/null)
    log "searched [$code] $title (id $id)"
    sleep "$GAP"
  done <<<"$list"
done
log "4k-migrate finished"
