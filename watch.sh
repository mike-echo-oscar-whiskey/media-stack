#!/usr/bin/env bash
# Watches the things that fail quietly, and says so. Changes nothing.
#
#   ./watch.sh             run every check once
#   ./watch.sh install     systemd user timer, every WATCH_INTERVAL
#   ./watch.sh status      last result, next run, recent alerts
#
# Split from heal.sh, which acts on what it finds - restarts containers, applies
# the disk brakes, evicts downloads. These four only look and report, and they
# want a different cadence for it: asking plex.tv about a port mapping or
# Spotweb for its newest spot every two minutes is hundreds of pointless calls a
# day, where a container that lost its network namespace really does want
# catching within two minutes.
#
# Each check latches, so a lasting fault is one message rather than one per run,
# and each sends a second message when it clears. The ones that can be briefly
# and legitimately false - a mount during a container restart, a port mapping
# while Plex starts - want several runs to agree before they are believed.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
UNIT=media-stack-watch
STATUS=backups/last-watch.txt
FAILED_STATE=backups/failed-alerts.json
SPOTWEB_STATE=backups/spotweb-alerts.json
PLEX_STATE=backups/plex-alerts.json
ARCHIVE_STATE=backups/archive-alerts.json

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
note() { mkdir -p backups; printf '%s  %s\n' "$(date '+%F %T')" "$*" > "$STATUS"; }

# alerts_on, ntfy_push and archive_enabled - shared with heal.sh and mover.sh.
. lib/alerts.sh

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

# ------------------------------------------------------------ archive tier
# The archive is a FUSE mount the rclone container makes and propagates into
# Sonarr and Radarr. When it goes, those apps do not see an error: they see an
# empty directory where a root folder used to be, report every archived title as
# missing, and - if nothing says otherwise - missing.sh starts searching for
# releases of files that are sitting safely in the cloud. mover.sh refuses to
# run without it, but nothing else would say so.
#
# Only checked when an archive is actually configured, so a stack without one
# stays silent. Three runs have to agree before it is believed, because the
# mount is briefly absent while the rclone container restarts.
ARCHIVE_STRIKES=3
check_archive_mount() {
  # Two conditions, not one: a remote has to exist, and the archive profile has
  # to be switched on. Turning the profile off is how you say you do not want an
  # archive right now, and that should be silent rather than alarming.
  archive_enabled || return 0

  # What can break is no longer a missing /data/archive - the apps have no such
  # path now. It is the union failing to assemble: /data/media then resolves to
  # the bare local branch, which looks completely normal and is quietly missing
  # every archived title. So the test is that /data/media really is a FUSE mount
  # inside the apps, and that the cloud branch under it is mounted on the host.
  local mounted=1 c state was strikes
  for c in sonarr radarr; do
    docker compose exec -T "$c" sh -c 'stat -f -c %T /data/media 2>/dev/null | grep -q fuse' \
      || mounted=0
  done
  # A dead FUSE endpoint is its own case and needs its own advice. When a
  # container is recreated while the mountpoint is still in use, the mount stays
  # listed in /proc/mounts but answers ENOTCONN: mountpoint says "no", rclone
  # restart-loops on "failed to access mountpoint ... Socket not connected", and
  # the unit and the container logs both look fine. Only root can detach it, so
  # pointing at systemctl and docker logs sends you the wrong way.
  local archive_dir stale=0
  archive_dir="$(readlink -f "${DATA_ROOT:-./data}/archive")/media"
  if ! mountpoint -q "$archive_dir"; then
    mounted=0
    if grep -qF " $archive_dir " /proc/mounts 2>/dev/null && ! stat "$archive_dir" >/dev/null 2>&1; then
      stale=1
    fi
  fi

  mkdir -p backups
  [[ -f "$ARCHIVE_STATE" ]] || echo '{"broken":false,"strikes":0}' > "$ARCHIVE_STATE"
  state=$(cat "$ARCHIVE_STATE")
  was=$(jq -r '.broken // false' <<<"$state")
  strikes=$(jq -r '.strikes // 0' <<<"$state")

  if (( mounted )); then
    if [[ "$was" == true ]]; then
      alerts_on health && ntfy_push "Archive is back" \
        "The union is assembled again; archived titles are readable and mover.sh can run." health
      log "archive: mount recovered"
    fi
    state=$(jq -c '.broken = false | .strikes = 0' <<<"$state")
  else
    strikes=$(( strikes + 1 ))
    state=$(jq -c --argjson n "$strikes" '.strikes = $n' <<<"$state")
    if (( strikes >= ARCHIVE_STRIKES )) && [[ "$was" != true ]]; then
      local why
      if (( stale )); then
        why="The cloud branch is a dead FUSE endpoint: still listed in /proc/mounts but answering \"Transport endpoint is not connected\". rclone cannot mount over it and will restart-loop. Only root can detach it: sudo umount -l $archive_dir, then docker compose restart rclone. systemctl and docker logs will both look healthy - they are not where the fault is."
      else
        why="/data/media is not the union in Sonarr or Radarr, or the cloud branch is unmounted, so everything archived reads as missing. Check: systemctl status media-stack-union, then docker compose logs rclone"
      fi
      alerts_on health && ntfy_push "The archive is not readable" "$why" health
      log "archive: the union is not assembled after $strikes runs$( (( stale )) && echo " (dead FUSE endpoint - needs a root umount -l)" )"
      state=$(jq -c '.broken = true' <<<"$state")
    fi
  fi

  printf '%s' "$state" > "$ARCHIVE_STATE.tmp" && mv "$ARCHIVE_STATE.tmp" "$ARCHIVE_STATE"
  return 0
}

# -------------------------------------------------------------- plex remote
# Remote access runs on a router port forward (PLEX_PUBLIC_PORT), and Plex's
# own Relay fallback is deliberately off, because the relay is capped hard
# enough to be reported as a playback problem. The cost of that choice is that
# a forward which stops working - a router reboot losing the rule, an ISP
# moving the line behind CGNAT - fails outright instead of degrading to a slow
# stream, and nothing says so until someone abroad cannot play anything.
#
# Plex already knows: it publishes the mapping to plex.tv and reports the
# verdict on its own root endpoint, so this asks locally rather than calling
# plex.tv every two minutes. "waiting" is a normal transient while the server
# starts, so a verdict has to hold for three runs before it is believed.
PLEX_REMOTE_STRIKES=3
check_plex_remote() {
  [[ -n "${PLEX_PUBLIC_PORT:-}" ]] || return 0
  docker compose ps --services --status running 2>/dev/null | grep -qx plex || return 0

  local prefs token body mapping err state was strikes
  prefs="${CONFIG_ROOT:-./config}/plex/Library/Application Support/Plex Media Server/Preferences.xml"
  token=$(sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$prefs" 2>/dev/null)
  [[ -n "$token" ]] || return 0

  body=$(curl -fsS -m 10 -H "X-Plex-Token: $token" -H 'Accept: application/json' \
         "http://localhost:32400/" 2>/dev/null) || return 0
  mapping=$(jq -r '.MediaContainer.myPlexMappingState // empty' <<<"$body")
  err=$(jq -r '.MediaContainer.myPlexMappingError // empty' <<<"$body")
  [[ -n "$mapping" ]] || return 0

  mkdir -p backups
  [[ -f "$PLEX_STATE" ]] || echo '{"broken":false,"strikes":0}' > "$PLEX_STATE"
  state=$(cat "$PLEX_STATE")
  was=$(jq -r '.broken // false' <<<"$state")
  strikes=$(jq -r '.strikes // 0' <<<"$state")

  if [[ "$mapping" == mapped ]]; then
    if [[ "$was" == true ]]; then
      alerts_on health && ntfy_push "Plex remote access is back" \
        "The port mapping is healthy again; playing from outside the LAN works." health
      log "plex: remote access recovered"
    fi
    state=$(jq -c '.broken = false | .strikes = 0' <<<"$state")
  else
    strikes=$(( strikes + 1 ))
    state=$(jq -c --argjson n "$strikes" '.strikes = $n' <<<"$state")
    if (( strikes >= PLEX_REMOTE_STRIKES )) && [[ "$was" != true ]]; then
      alerts_on health && ntfy_push "Plex remote access is down" \
        "Port mapping is \"$mapping\"${err:+ ($err)}. Playing from outside the LAN will fail - the relay fallback is off by design. Check that TCP $PLEX_PUBLIC_PORT is still forwarded to this host." health
      log "plex: remote access mapping is \"$mapping\"${err:+ ($err)} after $strikes runs"
      state=$(jq -c '.broken = true' <<<"$state")
    fi
  fi

  printf '%s' "$state" > "$PLEX_STATE.tmp" && mv "$PLEX_STATE.tmp" "$PLEX_STATE"
  return 0
}

install_timer() {
  local dir=~/.config/systemd/user span
  [[ -f .env ]] && { set -a; source .env; set +a; }
  span=${WATCH_INTERVAL:-10min}
  [[ "$span" =~ ^[0-9]+(s|sec|m|min|h|hour)$ ]] || { echo "WATCH_INTERVAL must be a systemd time span such as 10min (got \"$span\")" >&2; exit 1; }
  mkdir -p "$dir"
  cat > "$dir/$UNIT.service" <<UNIT
[Unit]
Description=media-stack: watch for failures that are otherwise silent
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$HERE
ExecStart=$HERE/watch.sh
UNIT
  cat > "$dir/$UNIT.timer" <<UNIT
[Unit]
Description=media-stack watcher (every $span)

[Timer]
OnBootSec=5min
OnUnitActiveSec=$span

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer" >/dev/null
  echo "timer enabled:"; systemctl --user list-timers "$UNIT.timer" --no-pager | head -2
}

show_status() {
  echo "--- last run:"; cat "$STATUS" 2>/dev/null || echo "never run"
  echo "--- currently raised:"
  local f
  for f in "$SPOTWEB_STATE" "$PLEX_STATE" "$ARCHIVE_STATE"; do
    [[ -f "$f" ]] || continue
    jq -e '.broken // .stale // false' "$f" >/dev/null 2>&1 && echo "  $(basename "$f" .json)"
  done
  echo "--- next run:"
  systemctl --user list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -2 || echo "timer not installed (./watch.sh install)"
  echo "--- alerts in the last 7 days:"
  journalctl --user -u "$UNIT" --since '7 days ago' --no-pager -o cat 2>/dev/null | grep -E 'stale|recovered|not a mount|mapping is' || echo "none"
}

case "${1:-}" in
  "")       if [[ -f .env ]]; then set -a; source .env; set +a; fi
            check_spotweb_stale; check_plex_remote; check_archive_mount; notify_failed_downloads
            note "OK - checked"
            ;;
  install)  install_timer ;;
  status)   show_status ;;
  *) echo "usage: $0 [install|status]" >&2; exit 2 ;;
esac
