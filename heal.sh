#!/usr/bin/env bash
# Keeps the running stack in the shape it was configured in, unattended:
# restarts containers whose health check fails, throws away downloads the
# apps rejected, and puts torrents back on the global share limit.
#
#   ./heal.sh              run all three checks once
#   ./heal.sh install      systemd user timer, every 2 minutes
#   ./heal.sh status       last result, next run, recent log
#
# Why: `restart: unless-stopped` only covers a crashed process, not a running
# one that lost what it needs. The case this exists for: qBittorrent runs in
# Gluetun's network namespace; when the Gluetun container
# restarts it gets a new namespace and qBittorrent stays in the dead old one,
# looking alive to itself. Its health check probes Gluetun's
# control API through the shared namespace, so that state shows as unhealthy,
# and a restart of qBittorrent re-attaches it. Docker has no "restart when
# unhealthy" of its own; this fills that gap for every service with a check.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
UNIT=media-stack-heal
STATUS=backups/last-heal.txt
FAILED_STATE=backups/failed-alerts.json
DISK_STATE=backups/disk-alerts.json
SPOTWEB_STATE=backups/spotweb-alerts.json

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
note() { mkdir -p backups; printf '%s  %s\n' "$(date '+%F %T')" "$*" > "$STATUS"; }

heal() {
  local unhealthy svc restarted=()
  unhealthy=$(docker compose ps --format json 2>/dev/null | jq -r 'select(.Health == "unhealthy") | .Service')
  [[ -n "$unhealthy" ]] || { note "OK - all healthy"; return 0; }
  # Gluetun first: restarting qBittorrent while Gluetun is still down is wasted.
  for svc in $(printf '%s\n' "$unhealthy" | sort | sed -n '/^gluetun$/p;/^gluetun$/!H;${x;s/\n/ /g;p}'); do
    log "restarting $svc (unhealthy)"
    docker compose restart "$svc" >/dev/null 2>&1 && restarted+=("$svc")
  done
  # A restarted Gluetun strands its dependants even when they looked fine.
  if printf '%s\n' "${restarted[@]}" | grep -qx gluetun; then
    for svc in $(docker compose ps --format json | jq -r 'select(.Service != "gluetun") | .Service' | while read -r s; do
        [[ $(docker inspect -f '{{.HostConfig.NetworkMode}}' "$s" 2>/dev/null) == container:* ]] && echo "$s"; done); do
      log "restarting $svc (shares Gluetun's network)"
      docker compose restart "$svc" >/dev/null 2>&1 && restarted+=("$svc")
    done
  fi
  note "restarted: ${restarted[*]:-nothing}"
}

# True when .env asks for this kind of alert. The vocabulary is the one
# documented in .env.example and applied to the apps by lib/notify.sh; it has
# to mean the same thing here.
alerts_on() {
  [[ -n "${NTFY_TOPIC:-}" ]] && [[ ",${NTFY_EVENTS:-}," == *,"$1",* ]]
}

# ntfy_level INTENT -> 1-5, reading NTFY_PRIORITY exactly as lib/notify.sh
# does: either a single level for everything, or a per-intent list such as
# "ready:2,failed:5". The two have to agree, or .env would mean one thing to
# the apps and another here.
ntfy_level() {
  local intent=$1 spec=${NTFY_PRIORITY:-4} pair k lvl
  spec=${spec// /}
  [[ $spec =~ ^[1-5]$ ]] && { printf '%s' "$spec"; return 0; }
  local IFS=,
  for pair in $spec; do
    k=${pair%%:*} lvl=${pair##*:}
    [[ $k == "$intent" && $lvl =~ ^[1-5]$ ]] || continue
    printf '%s' "$lvl"; return 0
  done
  printf '4'
}

# ntfy_push TITLE BODY INTENT
# No Tags header: ntfy turns every tag name into an emoji in the notification.
# Best effort by design: this runs on a timer every couple of minutes, and a
# push that cannot be delivered must never take the rest of the run down with
# it. The host reaches ntfy on its published port; the click target is the
# proxied name, because that is what a phone can open.
ntfy_push() {
  [[ -n "${NTFY_TOPIC:-}" ]] || return 0
  local prio; prio=$(ntfy_level "${3:-failed}")
  curl -fsS -m 10 -o /dev/null \
    -u "${NTFY_USER:-media-stack}:${NTFY_PASSWORD:-}" \
    -H "Title: $1" -H "Priority: $prio" \
    -H "Click: http://ntfy.${SITE_DOMAIN:-localhost}/$NTFY_TOPIC" \
    --data-binary "$2" "http://localhost:8090/$NTFY_TOPIC" 2>/dev/null || true
  return 0
}

# ----------------------------------------------------------------- spotweb
# Spotweb retrieves on its own cron inside the container, and reports a crash by
# printing "crashed" and exiting 0 - so a broken retrieval is invisible from
# outside. What is observable is whether spots keep arriving, so that is what is
# watched: the newest spot's timestamp. Nothing arriving for hours means either
# the Usenet account stopped working or retrieval is failing, and both want a
# human. See README "Spotweb, the Spotnet indexer".
check_spotweb_stale() {
  local hours=${SPOTWEB_STALE_HOURS:-0}
  [[ "$hours" =~ ^[0-9]+$ ]] || { log "SPOTWEB_STALE_HOURS must be a whole number of hours (got \"$hours\")"; return 0; }
  (( hours > 0 )) || return 0
  docker compose ps --services --status running 2>/dev/null | grep -qx spotweb || return 0

  # The count has to come with it: getMaxMessageTime() returns time() when the
  # spots table is empty (Dao_Base_Spot:959-961), so an empty database would look
  # perfectly fresh forever. No spots yet is not staleness - the first pass takes
  # minutes - so that case returns without judging anything.
  local both count newest age state was
  both=$(docker compose exec -T -u abc spotweb php -r \
    'chdir("/app"); require "vendor/autoload.php";
     $b = new Bootstrap(); list($s, $d) = $b->boot(); $sd = $d->getSpotDao();
     printf("%d %d", (int) $sd->getSpotCount("", ""), (int) $sd->getMaxMessageTime());' 2>/dev/null)
  read -r count newest <<<"$both"
  [[ "$count" =~ ^[0-9]+$ && "$newest" =~ ^[0-9]+$ ]] || return 0
  (( count > 0 )) || return 0
  age=$(( ( $(date +%s) - newest ) / 3600 ))

  mkdir -p backups
  [[ -f "$SPOTWEB_STATE" ]] || echo '{"stale":false}' > "$SPOTWEB_STATE"
  state=$(cat "$SPOTWEB_STATE")
  was=$(jq -r '.stale // false' <<<"$state")

  if (( age >= hours )) && [[ "$was" != true ]]; then
    if alerts_on disk; then
      ntfy_push "spotweb: no new spots for ${age}h" \
        "Retrieval may be failing - it reports a crash and still exits 0, so nothing else would say so." disk
    fi
    log "spotweb: newest spot is ${age}h old (stale after ${hours}h)"
    state=$(jq -c '.stale = true' <<<"$state")
  elif (( age < hours )) && [[ "$was" == true ]]; then
    if alerts_on disk; then
      ntfy_push "spotweb: spots arriving again" "Newest spot is ${age}h old." disk
    fi
    log "spotweb: retrieval recovered, newest spot ${age}h old"
    state=$(jq -c '.stale = false' <<<"$state")
  fi

  printf '%s' "$state" > "$SPOTWEB_STATE.tmp" && mv "$SPOTWEB_STATE.tmp" "$SPOTWEB_STATE"
  return 0
}

# ------------------------------------------------------------ disk space
# A full filesystem does not degrade gracefully: journald, Docker and every
# container fail together, and here one 849G filesystem carries the OS, the
# Docker state, the config and all of the data. So there are brakes, and this
# is the half of them that has to be polled - see README "Keeping the disk from
# filling".
#
# SABnzbd polices DISK_FLOOR_GIB itself, continuously, and the *arrs refuse an
# import that would cross it. qBittorrent has no free-space setting at all, so
# it is stopped from here. That is a poll, which means it needs headroom: at
# TORRENT_MAX_KIB for one HEAL_INTERVAL a download can take another few GiB
# between two runs, and the floor has to survive that. Hence a brake point of
# floor + headroom rather than floor.
#
# NTFY_EVENTS decides what gets said, never whether the machine is protected:
# dropping "disk" from it silences these alerts and leaves the brakes on. Only
# DISK_FLOOR_GIB=0 takes the brakes off.
heal_seconds() {                  # HEAL_INTERVAL "2min" -> 120
  local span=${HEAL_INTERVAL:-2min} n u
  n=${span%%[a-z]*} u=${span#"$n"}
  [[ "$n" =~ ^[0-9]+$ ]] || { echo 120; return 0; }
  case "$u" in
    s|sec)  echo "$n" ;;
    m|min)  echo $(( n * 60 )) ;;
    h|hour) echo $(( n * 3600 )) ;;
    *)      echo 120 ;;
  esac
}

# Whole GiB that the next orphan sweep would free - the same predicate
# reclaim_orphaned_downloads uses, so the number in an alert matches what will
# actually happen. It is the difference between "act now" and "this sorts
# itself out".
reclaimable_gib() {
  local root="${DATA_ROOT:-./data}/torrents" hours=${HEAL_ORPHAN_HOURS:-24} b
  [[ -d "$root" ]] || { echo 0; return 0; }
  [[ "$hours" =~ ^[0-9]+$ ]] || hours=24
  b=$(find "$root" -type f -links 1 -mmin "+$(( hours * 60 ))" -printf '%s\n' 2>/dev/null \
      | awk '{s+=$1} END {print s+0}')
  echo $(( b / 1073741824 ))
}

# Stops every downloading torrent and prints their hashes, one per line, so the
# release only ever starts the ones this stopped - a torrent stopped by hand
# stays stopped. Seeders are left alone: they cost no space, and stopping them
# would cost ratio on the private trackers TORRENT_PRIVATE_SEED_HOURS exists
# for. qBittorrent 5.x calls it stop/start; pause/resume is gone.
qbt_stop_downloading() {
  docker compose ps --services --status running 2>/dev/null | grep -qx qbittorrent || return 0
  local h
  h=$(docker compose exec -T qbittorrent curl -fsS -m 10 \
        "http://localhost:8081/api/v2/torrents/info?filter=downloading" 2>/dev/null \
      | jq -r '.[].hash') || return 0
  [[ -n "$h" ]] || return 0
  docker compose exec -T qbittorrent curl -fsS -m 10 -o /dev/null -X POST \
    --data "hashes=$(tr '\n' '|' <<<"$h" | sed 's/|$//')" \
    http://localhost:8081/api/v2/torrents/stop 2>/dev/null || return 0
  printf '%s\n' "$h"
}

qbt_start() {                     # qbt_start hash hash ...
  (( $# )) || return 0
  docker compose ps --services --status running 2>/dev/null | grep -qx qbittorrent || return 0
  docker compose exec -T qbittorrent curl -fsS -m 10 -o /dev/null -X POST \
    --data "hashes=$(printf '%s|' "$@" | sed 's/|$//')" \
    http://localhost:8081/api/v2/torrents/start 2>/dev/null || return 0
}

check_disk_space() {
  local floor=${DISK_FLOOR_GIB:-0} warn=${DISK_WARN_GIB:-0} v
  for v in "$floor" "$warn"; do
    [[ "$v" =~ ^[0-9]+$ ]] || {
      log "DISK_FLOOR_GIB and DISK_WARN_GIB must be whole numbers of GiB (got \"$v\")"; return 0; }
  done
  (( floor > 0 || warn > 0 )) || return 0

  local rate=${TORRENT_MAX_KIB:-0} secs head_gib stop_at
  [[ "$rate" =~ ^[0-9]+$ ]] || rate=0
  secs=$(heal_seconds)
  head_gib=$(( (rate * secs + 1048575) / 1048576 ))
  (( head_gib < 2 )) && head_gib=2
  stop_at=$(( floor + head_gib ))

  mkdir -p backups
  [[ -f "$DISK_STATE" ]] || echo '{"low":{},"braked":{}}' > "$DISK_STATE"
  local state; state=$(cat "$DISK_STATE")

  local mounts m avail free_gib free_min=999999 below=0
  mounts=$(df --output=target "${DATA_ROOT:-./data}/media" "${DATA_ROOT:-./data}/torrents" \
           2>/dev/null | tail -n +2 | sort -u)
  [[ -n "$mounts" ]] || return 0

  while read -r m; do
    [[ -n "$m" ]] || continue
    avail=$(df -k --output=avail "$m" 2>/dev/null | tail -n1 | tr -d ' ') || continue
    [[ "$avail" =~ ^[0-9]+$ ]] || continue
    free_gib=$(( avail / 1048576 ))
    (( free_gib < free_min )) && free_min=$free_gib
    if (( warn > 0 )); then
      if (( free_gib < warn )) && [[ $(jq -r --arg m "$m" '.low[$m] // false' <<<"$state") != true ]]; then
        if alerts_on disk; then
          ntfy_push "disk: $free_gib GiB left on $m" \
            "Below the $warn GiB mark. $(reclaimable_gib) GiB is reclaimable on the next sweep; torrents stop at $stop_at GiB." disk
        fi
        log "disk: $m down to $free_gib GiB (warn at $warn)"
        state=$(jq -c --arg m "$m" '.low[$m] = true' <<<"$state")
      elif (( free_gib >= warn + warn / 10 )) && [[ $(jq -r --arg m "$m" '.low[$m] // false' <<<"$state") == true ]]; then
        if alerts_on disk; then
          ntfy_push "disk: $free_gib GiB free on $m" "Back above the $warn GiB mark." disk
        fi
        log "disk: $m recovered to $free_gib GiB"
        state=$(jq -c --arg m "$m" 'del(.low[$m])' <<<"$state")
      fi
    fi
    (( floor > 0 && free_gib < stop_at )) && below=1
  done <<<"$mounts"

  if (( floor > 0 )); then
    local engaged stopped n held
    engaged=$(jq -r '.braked.engaged // false' <<<"$state")
    if (( below )) && [[ $engaged != true ]]; then
      stopped=$(qbt_stop_downloading)
      n=$(printf '%s' "$stopped" | grep -c . || true)
      state=$(jq -c --argjson h "$(printf '%s' "$stopped" | jq -R -s 'split("\n") | map(select(length > 0))')" \
              '.braked = {engaged: true, hashes: $h}' <<<"$state")
      if alerts_on disk; then
        ntfy_push "disk: torrents stopped, $free_min GiB left" \
          "Inside the $stop_at GiB brake point ($floor GiB floor plus $head_gib GiB of headroom). Stopped ${n:-0} downloading torrent(s); usenet pauses itself." disk
      fi
      log "disk: brake engaged at $free_min GiB, stopped ${n:-0} downloading torrent(s)"
    elif (( ! below )) && [[ $engaged == true ]] && (( free_min >= stop_at + stop_at / 4 )); then
      mapfile -t held < <(jq -r '.braked.hashes[]? // empty' <<<"$state")
      qbt_start ${held[@]+"${held[@]}"}
      state=$(jq -c '.braked = {engaged: false}' <<<"$state")
      if alerts_on disk; then
        ntfy_push "disk: torrents resumed, $free_min GiB free" \
          "Clear of the $stop_at GiB brake point. Started ${#held[@]} torrent(s) back up." disk
      fi
      log "disk: brake released at $free_min GiB, started ${#held[@]} torrent(s)"
    fi
  fi

  printf '%s' "$state" > "$DISK_STATE.tmp" && mv "$DISK_STATE.tmp" "$DISK_STATE"
  return 0
}

# Sonarr and Radarr have no failure notification event of any kind - not on the
# ntfy connection, not on any implementation in their /notification/schema - so
# a download that fails reaches nobody. Their history records it as eventType 4
# (downloadFailed) and this script already polls those APIs, so the alert is
# pushed from here instead.
#
# One history row is NOT one failure worth waking someone for. The release
# guard marks every fake it rejects as failed, so a single film can produce
# thirty rows in twenty minutes while the search is working exactly as
# intended. What matters is the item, not the release, and only once the app
# has stopped trying: a failure is worth reporting when the item has no file
# and nothing for it is left in the queue. Anything still queued stays pending
# and is judged again on the next run, a couple of minutes later.
notify_failed_downloads() {
  alerts_on failed || return 0
  local apps=",${NTFY_EVENT_APPS:-},"; apps=${apps// /}
  local app name port v key rows queue mark state seeding=0 ids id title
  mkdir -p backups
  [[ -f $FAILED_STATE ]] || { echo '{"marks":{},"pending":{}}' > "$FAILED_STATE"; seeding=1; }
  state=$(cat "$FAILED_STATE")
  for app in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
    IFS=: read -r name port v <<<"$app"
    [[ $apps == *,"$name",* ]] || continue
    key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null) || continue
    [[ -n "$key" ]] || continue
    rows=$(curl -fsS -m 15 -H "X-Api-Key: $key" \
      "http://localhost:$port/api/$v/history?pageSize=100&eventType=4" 2>/dev/null) || continue
    queue=$(curl -fsS -m 15 -H "X-Api-Key: $key" \
      "http://localhost:$port/api/$v/queue?pageSize=500" 2>/dev/null) || continue
    mark=$(jq -r --arg a "$name" '.marks[$a] // 0' <<<"$state")

    # Everything failed since the last look joins the pending set, keyed by the
    # thing that is missing rather than by the release that did not work.
    state=$(jq -c --arg a "$name" --argjson m "$mark" --argjson h "$rows" '
      ($h.records // []) as $r
      | .marks[$a] = ([$r[].id] + [$m] | max)
      | .pending[$a] = ((.pending[$a] // {}) + (
          [ $r[] | select(.id > $m)
            | { key: ((.episodeId // .movieId // .albumId // 0) | tostring),
                value: (.sourceTitle // "a release") }
            | select(.key != "0") ] | from_entries))' <<<"$state")

    # A pending item resolves silently when the file turns up, stays pending
    # while anything for it is still downloading, and is reported when neither
    # is true - the app has given up and the thing is simply not there.
    ids=$(jq -r --arg a "$name" '.pending[$a] // {} | keys[]' <<<"$state")
    for id in $ids; do
      [[ $id =~ ^[0-9]+$ ]] || continue
      if jq -e --argjson i "$id" \
           '(.records // []) | any((.episodeId // .movieId // .albumId) == $i)' <<<"$queue" >/dev/null; then
        continue
      fi
      if item_has_file "$name" "$port" "$v" "$key" "$id"; then
        state=$(jq -c --arg a "$name" --arg i "$id" 'del(.pending[$a][$i])' <<<"$state")
        continue
      fi
      title=$(jq -r --arg a "$name" --arg i "$id" '.pending[$a][$i] // "a release"' <<<"$state")
      (( seeding )) || {
        ntfy_push "$name: download failed" "Nothing left to try for: ${title:0:70}" failed
        log "$name: alerted on a failed download ($title)"
      }
      state=$(jq -c --arg a "$name" --arg i "$id" 'del(.pending[$a][$i])' <<<"$state")
    done
  done
  printf '%s' "$state" > "$FAILED_STATE.tmp" && mv "$FAILED_STATE.tmp" "$FAILED_STATE"
  return 0
}

# True when the episode, film or album behind a failed download now has a file
# after all. Lidarr counts tracks rather than carrying a single hasFile, so it
# is asked a different question.
item_has_file() {
  local name=$1 port=$2 v=$3 key=$4 id=$5 path q
  case $name in
    sonarr) path=episode; q='.hasFile == true' ;;
    radarr) path=movie;   q='.hasFile == true' ;;
    lidarr) path=album;   q='(.statistics.trackFileCount // 0) > 0' ;;
    *) return 1 ;;
  esac
  curl -fsS -m 15 -H "X-Api-Key: $key" "http://localhost:$port/api/$v/$path/$id" 2>/dev/null \
    | jq -e "$q" >/dev/null 2>&1
}

# A release carrying an executable is refused at import and then sits in the
# queue as a warning forever: the download itself succeeded, so nothing marks
# it failed, autoRedownloadFailed never fires, and the episode stays missing
# while the queue claims it is being handled. That message is terminal - no
# retry will ever import it - so the item is blocklisted (the release will not
# be grabbed again) and removed with its files. Deliberately narrow: only this
# message, never "stuck for a while", which would throw away a season pack
# that is merely slow.
evict_poisoned_downloads() {
  local app name port v key queue id title msgs removed=0
  for app in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
    IFS=: read -r name port v <<<"$app"
    key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null) || continue
    [[ -n "$key" ]] || continue
    queue=$(curl -fsS -m 15 -H "X-Api-Key: $key" \
      "http://localhost:$port/api/$v/queue?pageSize=200&includeUnknownSeriesItems=true&includeUnknownMovieItems=true&includeUnknownArtistItems=true" 2>/dev/null) || continue
    while IFS=$'\x1f' read -r id title; do
      [[ -n "$id" ]] || continue
      curl -fsS -m 20 -o /dev/null -X DELETE -H "X-Api-Key: $key" \
        "http://localhost:$port/api/$v/queue/$id?removeFromClient=true&blocklist=true&skipRedownload=false" \
        && { log "$name: blocklisted a release carrying an executable ($title)"
             if alerts_on failed; then
               ntfy_push "$name: release blocklisted" "Carried an executable, will not be grabbed again: $title" failed
             fi
             removed=$((removed + 1)); }
    done < <(jq -r '.records[]? | select(any(.statusMessages[]?.messages[]?; test("executable file with extension"; "i")))
                    | "\(.id)\u001f\(.title[0:60])"' <<<"$queue")
  done
  (( removed )) && note "blocklisted $removed download(s) carrying an executable"
  return 0
}

# A download the apps marked failed after import (the release guard does that
# for fakes) is blocklisted, but the torrent itself keeps seeding: the app no
# longer tracks it once imported. Match the failed downloads' ids (torrent
# hashes) against what qBittorrent holds and delete those with their files.
evict_failed_torrents() {
  docker compose ps --services --status running 2>/dev/null | grep -qx qbittorrent || return 0
  local have failed h
  have=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/torrents/info 2>/dev/null | jq -r '.[].hash | ascii_downcase') || return 0
  [[ -n "$have" ]] || return 0
  failed=$(for app in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
    IFS=: read -r name port v <<<"$app"
    key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null); [[ -n "$key" ]] || continue
    curl -fsS -m 10 -H "X-Api-Key: $key" "http://localhost:$port/api/$v/history?pageSize=200&eventType=4" 2>/dev/null \
      | jq -r '.records[] | select(.downloadId != null and (.downloadId | length) == 40) | .downloadId | ascii_downcase'
  done | sort -u)
  for h in $(comm -12 <(sort -u <<<"$have") <(printf '%s\n' "$failed")); do
    docker compose exec -T qbittorrent curl -fsS -m 10 -o /dev/null -X POST --data "hashes=$h&deleteFiles=true" http://localhost:8081/api/v2/torrents/delete \
      && log "evicted a torrent the apps marked failed ($h)"
  done
}

# A torrent can carry its own share limit, set when it was added; it then
# ignores the global ratio and seeding time from .env and would seed on long
# after the rule says to stop. configure.sh resets those when it runs - this
# catches the ones that turn up in between.
enforce_share_limits() {
  docker compose ps --services --status running 2>/dev/null | grep -qx qbittorrent || return 0
  # A torrent from a private tracker carries its own seeding time on purpose -
  # Radarr and Sonarr stamp it from TORRENT_PRIVATE_SEED_HOURS when they grab,
  # because a public tracker's ratio 1 would be a hit and run there. Leave
  # those; everything else goes back on the global pair.
  local stamped private_minutes=$(( ${TORRENT_PRIVATE_SEED_HOURS:-72} * 60 ))
  stamped=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/torrents/info 2>/dev/null \
            | jq -r --argjson p "$private_minutes" '.[]
                | select(.ratio_limit != -2 or .seeding_time_limit != -2)
                | select(.seeding_time_limit != $p) | .hash') || return 0
  [[ -n "$stamped" ]] || return 0
  docker compose exec -T qbittorrent curl -fsS -m 10 -o /dev/null -X POST \
    --data "hashes=$(tr '\n' '|' <<<"$stamped")&ratioLimit=-2&seedingTimeLimit=-2&inactiveSeedingTimeLimit=-2&shareLimitAction=Default" \
    http://localhost:8081/api/v2/torrents/setShareLimits \
    && log "put $(wc -l <<<"$stamped") torrent(s) back on the global share limit"
}

# Empty leftovers go, but never a directory the download client saves into:
# deleting an empty data/torrents/movies made Radarr report its save path as
# missing inside the container. The categories come from the client itself, so a
# new one is protected the moment it exists.
prune_empty_download_dirs() {
  local root=$1 cats d base protected c
  cats=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/torrents/categories 2>/dev/null \
         | jq -r 'keys[]' 2>/dev/null) || cats=""
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    base=$(basename "$d"); protected=0
    [[ "$base" == incomplete ]] && protected=1
    while IFS= read -r c; do [[ -n "$c" && "$base" == "$c" ]] && protected=1; done <<<"$cats"
    (( protected )) || rmdir "$d" 2>/dev/null || true
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -empty 2>/dev/null)
  find "$root" -mindepth 2 -type d -empty -delete 2>/dev/null
  return 0
}

# A torrent that has met its share limit has discharged the seed promised when
# it was grabbed. If by then no library file shares its bytes, we are seeding
# something we no longer keep - an upgrade replaced the file, or the release
# guard deleted it - so it goes, with its data.
#
# "Stopped" alone is not the test, though it reads like one: qBittorrent reports
# stoppedUP whether it stopped itself at the limit or somebody stopped it by
# hand, and deleting a torrent that was paused deliberately - a manual download
# waiting to be sorted, say - would destroy the only copy of it. So the limit
# has to be shown as reached: ratio at or above the effective ratio limit, or
# seeding time at or beyond the effective time limit, where -2 means "use the
# global value" and -1 means "no limit at all".
#
# A torrent still in an app's queue is never touched either, however long it has
# been stopped: its import may not have happened yet.
evict_superseded_torrents() {
  docker compose ps --services --status running 2>/dev/null | grep -qx qbittorrent || return 0
  local info
  info=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/torrents/info 2>/dev/null) || return 0
  [[ -n "$info" && "$info" != "[]" ]] || return 0

  # Hashes any app is still working on.
  local app name port v key busy
  busy=$(for app in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
    IFS=: read -r name port v <<<"$app"
    key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null)
    [[ -n "$key" ]] || continue
    curl -fsS -m 10 -H "X-Api-Key: $key" "http://localhost:$port/api/$v/queue?pageSize=200" 2>/dev/null \
      | jq -r '.records[]?.downloadId // empty | ascii_downcase'
  done | sort -u)

  # The global limits the per-torrent -2 refers to.
  local prefs gratio gtime
  prefs=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/app/preferences 2>/dev/null) || return 0
  gratio=$(jq -r 'if .max_ratio_enabled then .max_ratio else -1 end' <<<"$prefs")
  gtime=$(jq -r 'if .max_seeding_time_enabled then .max_seeding_time else -1 end' <<<"$prefs")

  local root="${DATA_ROOT:-./data}/torrents" keep=${HEAL_ORPHAN_KEEP:-prowlarr,music}
  # Fields separated by the unit separator, not a tab: tab counts as IFS
  # whitespace, so `IFS=$'\t' read` collapses two adjacent tabs and an empty
  # category silently shifted the path into the wrong variable - every torrent
  # was skipped, and the fixtures missed it because they all had a category.
  local h cat path rel shared bytes k skip freed=0 count=0
  while IFS=$'\x1f' read -r h cat path; do
    [[ -n "$h" ]] || continue
    grep -qxF "$(tr 'A-Z' 'a-z' <<<"$h")" <<<"$busy" && continue
    skip=0
    while IFS= read -r k; do [[ -n "$k" && "$cat" == "$k" ]] && skip=1; done <<<"${keep//,/$'\n'}"
    (( skip )) && continue
    rel=${path#/data/torrents/}
    [[ -n "$rel" && -e "$root/$rel" ]] || continue
    # One file still carrying a second name means the library kept this copy.
    shared=$(find "$root/$rel" -type f -links +1 -print -quit 2>/dev/null)
    [[ -n "$shared" ]] && continue
    bytes=$(du -sb "$root/$rel" 2>/dev/null | cut -f1) || bytes=0
    if docker compose exec -T qbittorrent curl -fsS -m 15 -o /dev/null -X POST \
         --data "hashes=$h&deleteFiles=true" http://localhost:8081/api/v2/torrents/delete 2>/dev/null; then
      freed=$(( freed + ${bytes:-0} )); count=$(( count + 1 ))
      log "stopped seeding a copy the library no longer keeps: ${rel:0:60}"
    fi
  done < <(jq -r --argjson gr "$gratio" --argjson gt "$gtime" '.[]
      | select(.state | test("^(stoppedUP|pausedUP)$"))
      # -2 defers to the global limit, -1 disables the limit entirely.
      | (if .ratio_limit == -2 then $gr else .ratio_limit end) as $rl
      | (if .seeding_time_limit == -2 then $gt else .seeding_time_limit end) as $tl
      | select(($rl > 0 and .ratio >= $rl) or ($tl > 0 and (.seeding_time / 60) >= $tl))
      | "\(.hash)\u001f\(.category // "")\u001f\(.content_path // "")"' <<<"$info")

  if (( count )); then
    prune_empty_download_dirs "$root"
    note "removed $count superseded torrent(s), $(( freed / 1024 / 1024 )) MiB"
  fi
  return 0
}

# Download data no app owns any more. An upgrade or a release-guard rejection
# deletes the library file, but the download client keeps its own name for the
# same bytes - by design, so seeding can finish. When the torrent later leaves
# the client without taking its data, nothing reclaims it: the apps only clean
# up downloads they can still see, and evict_failed_torrents needs a torrent to
# evict. Left alone it grows with every upgrade; 31 GB had built up by
# 2026-09-25, most of it one remux that had been replaced hours after import.
#
# A file is deleted only when every one of these holds, because a fresh
# download that is waiting to be imported looks identical on the first count:
#   * it sits under DATA_ROOT/torrents, outside incomplete/ and KEEP
#   * it has one link, so no library file shares the bytes
#   * no torrent in the client covers it
#   * no app has anything in its queue
#   * nothing has touched it for HEAL_ORPHAN_HOURS
reclaim_orphaned_downloads() {
  local hours=${HEAL_ORPHAN_HOURS:-24}
  [[ "$hours" =~ ^[0-9]+$ ]] || { log "HEAL_ORPHAN_HOURS must be a whole number of hours (got \"$hours\")"; return 0; }
  (( hours > 0 )) || return 0
  local root="${DATA_ROOT:-./data}/torrents"
  [[ -d "$root" ]] || return 0

  # Anything in a queue means an import may still be coming for some download;
  # that is not the moment to be deleting files underneath the apps.
  local app name port v key queued=0 n
  for app in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
    IFS=: read -r name port v <<<"$app"
    key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null)
    [[ -n "$key" ]] || continue
    n=$(curl -fsS -m 10 -H "X-Api-Key: $key" "http://localhost:$port/api/$v/queue?pageSize=200" 2>/dev/null | jq '.records | length' 2>/dev/null) || n=0
    queued=$(( queued + ${n:-0} ))
  done
  (( queued == 0 )) || return 0

  # What the client still holds, as paths relative to the torrent root, so a
  # live download is never a candidate however it is categorised.
  local held
  held=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/torrents/info 2>/dev/null \
         | jq -r '.[].content_path // empty | sub("^/data/torrents/"; "")') || return 0

  local keep=${HEAL_ORPHAN_KEEP:-prowlarr,music} freed=0 count=0 f rel top k skip
  while IFS= read -r -d '' f; do
    rel=${f#"$root"/}; top=${rel%%/*}
    [[ "$top" == incomplete ]] && continue
    skip=0
    while IFS= read -r k; do [[ -n "$k" && "$top" == "$k" ]] && skip=1; done <<<"${keep//,/$'\n'}"
    (( skip )) && continue
    if [[ -n "$held" ]]; then
      while IFS= read -r h; do [[ -n "$h" && "$rel" == "$h"* ]] && skip=1; done <<<"$held"
      (( skip )) && continue
    fi
    freed=$(( freed + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
    rm -f -- "$f" && count=$(( count + 1 ))
  done < <(find "$root" -type f -links 1 -mmin "+$(( hours * 60 ))" -print0 2>/dev/null)

  if (( count )); then
    prune_empty_download_dirs "$root"
    log "reclaimed $count orphaned download file(s), $(( freed / 1024 / 1024 )) MiB"
    note "reclaimed $count orphaned download file(s), $(( freed / 1024 / 1024 )) MiB"
  fi
  return 0
}

install_timer() {
  local dir=~/.config/systemd/user span
  [[ -f .env ]] && { set -a; source .env; set +a; }
  span=${HEAL_INTERVAL:-2min}
  [[ "$span" =~ ^[0-9]+(s|sec|m|min|h|hour)$ ]] || { echo "HEAL_INTERVAL must be a systemd time span such as 2min (got \"$span\")" >&2; exit 1; }
  mkdir -p "$dir"
  cat > "$dir/$UNIT.service" <<UNIT
[Unit]
Description=media-stack: restart unhealthy containers
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$HERE
ExecStart=$HERE/heal.sh
UNIT
  cat > "$dir/$UNIT.timer" <<UNIT
[Unit]
Description=media-stack self-healing (every $span)

[Timer]
OnBootSec=3min
OnUnitActiveSec=$span

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer" >/dev/null
  echo "timer enabled:"; systemctl --user list-timers "$UNIT.timer" --no-pager | head -2
  if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) != yes ]]; then
    if loginctl enable-linger "$USER" 2>/dev/null; then
      echo "lingering enabled: the timer also runs when you are not logged in"
    else
      echo "NOTE: run once as root so the timer also fires when you are not logged in:"
      echo "      sudo loginctl enable-linger $USER"
    fi
  fi
}

show_status() {
  echo "last result: $(cat "$STATUS" 2>/dev/null || echo 'never run')"
  systemctl --user list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -2 || echo "timer not installed (./heal.sh install)"
  echo "--- restarts in the last 7 days:"; journalctl --user -u "$UNIT" --since '7 days ago' --no-pager -o cat 2>/dev/null | grep -E 'restarting' || echo "none"
}

case "${1:-}" in
  "")       if [[ -f .env ]]; then set -a; source .env; set +a; fi
            heal; check_disk_space; check_spotweb_stale; notify_failed_downloads; evict_failed_torrents; evict_poisoned_downloads; evict_superseded_torrents; reclaim_orphaned_downloads; enforce_share_limits ;;
  install)  install_timer ;;
  status)   show_status ;;
  *) echo "usage: $0 [install|status]" >&2; exit 2 ;;
esac
