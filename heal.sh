#!/usr/bin/env bash
# Puts the running stack back into the shape it was configured in, unattended:
# restarts containers whose health check fails, applies the disk brakes when
# space runs short, throws away downloads the apps rejected and torrents that
# were superseded, reclaims orphaned files, and puts share limits back on
# torrents that lost them.
#
#   ./heal.sh              run every step once
#   ./heal.sh install      systemd user timer, every 2 minutes
#   ./heal.sh status       last result, next run, recent log
#
# Everything here changes something. The checks that only look and report live
# in watch.sh, on a slower timer - they were split out because two minutes is
# the right cadence for catching a container that lost its network namespace
# and the wrong one for asking plex.tv about a port mapping.
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
DISK_STATE=backups/disk-alerts.json
RENAME_STATE=backups/last-rename.txt

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
note() { mkdir -p backups; printf '%s  %s\n' "$(date '+%F %T')" "$*" > "$STATUS"; }

# alerts_on, ntfy_push and archive_enabled - shared with watch.sh and mover.sh.
# The disk brakes are the one thing here that both acts and reports.
. lib/alerts.sh

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
  local root="${DATA_ROOT:-./data}/local/torrents" hours=${HEAL_ORPHAN_HOURS:-24} b
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
  mounts=$(df --output=target "${DATA_ROOT:-./data}/local/media" "${DATA_ROOT:-./data}/local/torrents" \
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
          # Name what actually stops, and where. Imports are not on the list:
          # they cost no space on one filesystem, so they keep running - and
          # importing is what frees the download folder. Once there is an
          # archive the mover is already acting on this, so the alert says so
          # rather than reading as a problem nobody is handling.
          local doing=""
          archive_enabled && doing="The mover is archiving towards ${ARCHIVE_REMOTE_PERCENT:-0}% of the library in the cloud. "
          ntfy_push "disk: $free_gib GiB left on $m" \
            "Below the $warn GiB mark. ${doing}$(reclaimable_gib) GiB is reclaimable on the next sweep. Downloading pauses at $floor GiB, torrents at $stop_at." disk
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
    elif (( below )) && [[ $engaged == true ]]; then
      # Engaging once is not enough. The brake stops what is running at that
      # instant, and an arr app goes on grabbing: a release that arrives a minute
      # later starts downloading against a disk that is already past its floor,
      # and the brake - being "on" - never looks again. Three such grabs pulled
      # 22 MiB/s for an hour while the state file said engaged, and took the disk
      # from 53 GiB to 24. So keep stopping, and remember the hashes too, or they
      # are not among the ones started again on release.
      stopped=$(qbt_stop_downloading)
      n=$(printf '%s' "$stopped" | grep -c . || true)
      if (( ${n:-0} > 0 )); then
        state=$(jq -c --argjson h "$(printf '%s' "$stopped" | jq -R -s 'split("\n") | map(select(length > 0))')" \
                '.braked.hashes = ((.braked.hashes // []) + $h | unique)' <<<"$state")
        log "disk: brake still on at $free_min GiB, stopped $n download(s) started since"
      fi
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
# A magnet whose swarm has nobody holding the metadata sits in metaDL forever.
# qBittorrent has no timeout for it (its timers cover slow and inactive
# *seeding*, not this), Sonarr and Radarr have no stalled-download handling at
# all, and the state is neither failed nor finished - so nothing above touches
# it. Meanwhile it counts as an active download and holds one of the client's
# queue slots, which is how three dead magnets stopped 38 healthy torrents from
# ever starting.
#
# Removal goes through the app that asked for it, so the release is blocklisted
# and a different one is searched for. A torrent no app owns is dropped straight
# from the client.
evict_stalled_metadata() {
  local mins=${HEAL_METADATA_STALL_MINUTES:-60}
  [[ "$mins" =~ ^[0-9]+$ ]] || { log "HEAL_METADATA_STALL_MINUTES must be a whole number of minutes (got \"$mins\")"; return 0; }
  (( mins > 0 )) || return 0
  docker compose ps --services --status running 2>/dev/null | grep -qx qbittorrent || return 0

  local raw stuck h app name port v key ids removed=0
  raw=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/torrents/info 2>/dev/null) || return 0
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || return 0
  # time_active, not "now - added_on": the latter is wall clock since the torrent
  # was added, and a magnet that sat stopped for four hours under the disk brake
  # is older than the limit the instant it resumes - condemned before it has had
  # a second to find a peer. That is this stack evicting its own downloads for a
  # stall it caused: the brake released at 17:29 and the evictions logged at
  # 17:29:24. time_active counts only the time the torrent was actually running,
  # so a magnet added 329 minutes ago but active for one is judged on the one.
  stuck=$(jq -r --argjson age "$(( mins * 60 ))" \
            '.[] | select(.state == "metaDL" and (.time_active // 0) > $age) | .hash | ascii_downcase' <<<"$raw")
  [[ -n "$stuck" ]] || return 0

  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    local owned=0
    for app in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
      IFS=: read -r name port v <<<"$app"
      key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null)
      [[ -n "$key" ]] || continue
      ids=$(curl -fsS -m 15 -H "X-Api-Key: $key" \
              "http://localhost:$port/api/$v/queue?pageSize=200&includeUnknownSeriesItems=true&includeUnknownMovieItems=true&includeUnknownArtistItems=true" 2>/dev/null \
            | jq -r --arg h "$h" '[.records[]? | select((.downloadId // "" | ascii_downcase) == $h) | .id] | join(",")')
      [[ -n "$ids" ]] || continue
      # A season pack is several queue records on one download, so they go together.
      curl -fsS -m 30 -o /dev/null -X DELETE -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
        --data-binary "$(jq -cn --argjson i "[$ids]" '{ids:$i}')" \
        "http://localhost:$port/api/$v/queue/bulk?removeFromClient=true&blocklist=true&skipRedownload=false" \
        && { owned=1; removed=$(( removed + 1 ))
             log "$name: no metadata after $mins min, blocklisted and searching again ($h)"; }
      break
    done
    if (( ! owned )); then
      docker compose exec -T qbittorrent curl -fsS -m 15 -o /dev/null -X POST \
        --data "hashes=$h&deleteFiles=true" http://localhost:8081/api/v2/torrents/delete 2>/dev/null \
        && { removed=$(( removed + 1 )); log "evicted a magnet with no metadata after $mins min ($h)"; }
    fi
  done <<<"$stuck"

  if (( removed )); then
    note "removed $removed download(s) stuck without metadata"
    alerts_on failed && ntfy_push "downloads: $removed stuck magnet(s) removed" \
      "No metadata after $mins minutes - blocklisted, and the apps are searching for another release." failed
  fi
  return 0
}

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

  local root="${DATA_ROOT:-./data}/local/torrents" keep=${HEAL_ORPHAN_KEEP:-prowlarr,music}
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




# The same sweep for the usenet side, which had none: reclaim_orphaned_downloads
# walks DATA_ROOT/torrents only, so a download that completed and never imported
# sat in SABnzbd's complete folder forever. 26 GiB had collected that way.
#
# The guard is different from the torrent one and has to be. There is no client
# holding these, so what protects a file is an app still pointing at it: an
# episode whose title is TBA waits up to 48 hours with its download finished and
# its queue item parked on a warning, and the torrent sweep's "every queue is
# empty" test does not count a warning - so only matching the queue's own
# outputPath keeps that file alive.
reclaim_orphaned_usenet() {
  local hours=${HEAL_ORPHAN_HOURS:-24}
  [[ "$hours" =~ ^[0-9]+$ ]] || return 0
  (( hours > 0 )) || return 0
  local root="${DATA_ROOT:-./data}/local/usenet/complete"
  [[ -d "$root" ]] || return 0

  # Every path any app still expects to import, as seen inside the containers.
  local app name port v key wanted
  wanted=$(for app in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
    IFS=: read -r name port v <<<"$app"
    key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null)
    [[ -n "$key" ]] || continue
    curl -fsS -m 15 -H "X-Api-Key: $key" \
      "http://localhost:$port/api/$v/queue?pageSize=200&includeUnknownSeriesItems=true&includeUnknownMovieItems=true&includeUnknownArtistItems=true" 2>/dev/null \
      | jq -r '.records[]?.outputPath // empty | sub("^/data/usenet/complete/"; "")'
  done) || return 0

  local keep=${HEAL_ORPHAN_KEEP:-prowlarr,music} freed=0 count=0 f rel top k w skip
  while IFS= read -r -d '' f; do
    rel=${f#"$root"/}; top=${rel%%/*}
    skip=0
    while IFS= read -r k; do [[ -n "$k" && "$top" == "$k" ]] && skip=1; done <<<"${keep//,/$'\n'}"
    (( skip )) && continue
    while IFS= read -r w; do [[ -n "$w" && "$rel" == "$w"* ]] && skip=1; done <<<"$wanted"
    (( skip )) && continue
    freed=$(( freed + $(stat -c %s "$f" 2>/dev/null || echo 0) ))
    rm -f -- "$f" && count=$(( count + 1 ))
  done < <(find "$root" -type f -links 1 -mmin "+$(( hours * 60 ))" -print0 2>/dev/null)

  if (( count )); then
    prune_empty_download_dirs "$root"
    log "reclaimed $count finished usenet download(s) nothing imported, $(( freed / 1024 / 1024 )) MiB"
    note "reclaimed $count finished usenet download(s), $(( freed / 1024 / 1024 )) MiB"
  fi
  return 0
}

reclaim_orphaned_downloads() {
  local hours=${HEAL_ORPHAN_HOURS:-24}
  [[ "$hours" =~ ^[0-9]+$ ]] || { log "HEAL_ORPHAN_HOURS must be a whole number of hours (got \"$hours\")"; return 0; }
  (( hours > 0 )) || return 0
  local root="${DATA_ROOT:-./data}/local/torrents"
  [[ -d "$root" ]] || return 0

  # An import that may still be coming is not the moment to delete files from
  # underneath the apps - but only a download that is actually going somewhere
  # counts. An item parked with a warning is not: an episode whose title is
  # still TBA waits up to 48 hours, and a download the app has decided not to
  # import never leaves the queue at all. Counting those meant one stuck item
  # switched this sweep off for the whole stack, indefinitely.
  local app name port v key queued=0 n
  for app in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
    IFS=: read -r name port v <<<"$app"
    key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null)
    [[ -n "$key" ]] || continue
    n=$(curl -fsS -m 10 -H "X-Api-Key: $key" "http://localhost:$port/api/$v/queue?pageSize=200" 2>/dev/null \
        | jq '[.records[]? | select((.trackedDownloadStatus // "ok") == "ok")] | length' 2>/dev/null) || n=0
    queued=$(( queued + ${n:-0} ))
  done
  (( queued == 0 )) || return 0

  # What the client still holds, as paths relative to the torrent root, so a
  # live download is never a candidate however it is categorised.
  #
  # The answer is checked for being a list before any of it is believed. An
  # empty body parses to nothing and exits 0, so it used to arrive here as an
  # empty "held" - indistinguishable from a client holding nothing, and the
  # protection below was skipped entirely rather than the sweep stopping. That
  # deleted a complete torrent's files out from under qBittorrent, which then
  # reported missingFiles for a release the library had never imported. A
  # non-answer is not the same as "nothing is held", and only the second may
  # let a file be removed.
  local raw held
  raw=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/torrents/info 2>/dev/null) || return 0
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || return 0
  held=$(jq -r '.[].content_path // empty | sub("^/data/torrents/"; "")' <<<"$raw") || return 0

  local keep=${HEAL_ORPHAN_KEEP:-prowlarr,music} freed=0 count=0 f rel top k h skip
  while IFS= read -r -d '' f; do
    rel=${f#"$root"/}; top=${rel%%/*}
    [[ "$top" == incomplete ]] && continue
    skip=0
    while IFS= read -r k; do [[ -n "$k" && "$top" == "$k" ]] && skip=1; done <<<"${keep//,/$'\n'}"
    (( skip )) && continue
    # Unconditional: an empty "held" now means the client really holds nothing,
    # which this loop reads as "no match" on its own. Guarding the check with
    # a test for "held" being non-empty is what turned a missing answer into
    # permission to delete.
    while IFS= read -r h; do [[ -n "$h" && "$rel" == "$h"* ]] && skip=1; done <<<"$held"
    (( skip )) && continue
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

# Sonarr and Radarr apply the naming format when a file is imported and never
# again, so a title that was "TBA" or "Episode 1" on import keeps that name for
# ever - even once the metadata source fills it in. Both apps will say which
# files are out of date (/api/v3/rename), and both will do the renaming
# themselves; nothing here touches the filesystem.
#
# Two reasons this is daily rather than every two minutes. It is one call per
# series and per film - 185 here - and the answer changes about as often as
# TVDB gets edited. And a rename of an archived file is a server-side move on
# the remote (the backend reports Move and DirMove, so no bytes come down), but
# it must not race the mover: a title can be mid-flight between the branches,
# and renaming it then is how you get two half-files.
rename_stale_files() {
  local today; today=$(date '+%F')
  [[ "$(cat "$RENAME_STATE" 2>/dev/null)" == "$today" ]] && return 0
  pgrep -f '[m]over.sh' >/dev/null && return 0
  docker compose ps --services --status running 2>/dev/null | grep -qx sonarr || return 0

  # RenameFiles wants the file ids as well as the parent id. Passing an empty
  # `files` is accepted, reports success and renames nothing - which is exactly
  # what it did on the first attempt here.
  local app name port v idkey filekey listpath key ids id files n total=0
  for app in sonarr:8989:v3:seriesId:episodeFileId:series radarr:7878:v3:movieId:movieFileId:movie; do
    IFS=: read -r name port v idkey filekey listpath <<<"$app"
    key=$(sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$name/config.xml" 2>/dev/null)
    [[ -n "$key" ]] || continue
    ids=$(curl -fsS -m 20 -H "X-Api-Key: $key" "http://localhost:$port/api/$v/$listpath" 2>/dev/null \
          | jq -r '.[]?.id') || continue
    while IFS= read -r id; do
      [[ -n "$id" ]] || continue
      files=$(curl -fsS -m 20 -H "X-Api-Key: $key" "http://localhost:$port/api/$v/rename?$idkey=$id" 2>/dev/null \
              | jq -c --arg f "$filekey" 'if type == "array" then [.[] | .[$f]] else [] end') || continue
      n=$(jq 'length' <<<"$files")
      (( n > 0 )) || continue
      curl -fsS -m 30 -o /dev/null -X POST -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
        --data "$(jq -cn --arg k "$idkey" --argjson i "$id" --argjson f "$files" '{name: "RenameFiles", ($k): $i, files: $f}')" \
        "http://localhost:$port/api/$v/command" 2>/dev/null \
        && { total=$(( total + n )); log "$name: renamed $n file(s) whose title had changed since import ($listpath $id)"; }
    done <<<"$ids"
  done
  printf '%s' "$today" > "$RENAME_STATE"
  (( total > 0 )) && note "renamed $total file(s) to match their current metadata"
  return 0
}

show_status() {
  echo "last result: $(cat "$STATUS" 2>/dev/null || echo 'never run')"
  systemctl --user list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -2 || echo "timer not installed (./heal.sh install)"
  echo "--- restarts in the last 7 days:"; journalctl --user -u "$UNIT" --since '7 days ago' --no-pager -o cat 2>/dev/null | grep -E 'restarting' || echo "none"
}

case "${1:-}" in
  "")       if [[ -f .env ]]; then set -a; source .env; set +a; fi
            heal; check_disk_space; evict_failed_torrents; evict_poisoned_downloads; evict_stalled_metadata; evict_superseded_torrents; reclaim_orphaned_downloads; reclaim_orphaned_usenet; enforce_share_limits; rename_stale_files ;;
  install)  install_timer ;;
  status)   show_status ;;
  *) echo "usage: $0 [install|status]" >&2; exit 2 ;;
esac
