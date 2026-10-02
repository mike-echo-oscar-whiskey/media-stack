#!/usr/bin/env bash
# Updates the stack the way README "Updating containers" describes, unattended:
#
#   ./update.sh            pull; if anything changed: stop, snapshot config,
#                          recreate, wait for health, prune old images
#   ./update.sh install    weekly systemd user timer (Sunday 04:00 + <15 min)
#   ./update.sh status     last result, next run, recent log
#
# Snapshots (config + .env, Plex cache excluded) land in ./backups, the last
# KEEP are kept. Rollback: restore a snapshot, pin the previous tag from the
# matching images-*.txt in .env, docker compose up -d.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
# archive_enabled lives here and is the single source of truth for "is the cloud
# tier in use". It is deliberately not reimplemented: it handles rclone.conf being
# root-owned 0600, where grep exits 2 for "cannot tell" rather than 1 for "no",
# and three separate checks have already been caught by reading those as the same.
. lib/alerts.sh

BACKUPS=backups
KEEP=4
STATUS=$BACKUPS/last-update.txt
UNIT=media-stack-update

log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
note() { mkdir -p "$BACKUPS"; printf '%s  %s\n' "$(date '+%F %T')" "$*" > "$STATUS"; }

wait_healthy() {
  local tries=0 unhealthy
  while :; do
    unhealthy=$(docker compose ps --format json | jq -r 'select(.Health != "healthy" and .Health != "") | .Name' | paste -sd, -)
    [[ -z "$unhealthy" ]] && return 0
    (( tries++ >= 60 )) && { echo "$unhealthy"; return 1; }
    sleep 3
  done
}

# Recreating the rclone container empties its VFS cache, because the cache lives
# in the container's writable layer. With --vfs-cache-mode full a write is
# acknowledged as soon as it reaches that cache, so mover.sh sees the copy
# succeed and deletes the local source while the upload is still queued: a file
# whose upload has not completed exists in exactly one place. On 2026-10-02 nine
# did, 58 GiB of them, while Google refused every upload with a 403 - a weekly
# update would have deleted them silently and the first symptom would have been
# Plex failing to play a film Radarr still listed as present.
#
# Stopping rclone is safe; the cache survives a stop and a start. Only a recreate
# empties it, so this only bites when rclone itself has a new image.
#
# Prints the at-risk paths, one per line. Fails closed: if it cannot read the
# cache or reach the rc it says so on stderr and prints a sentinel, because
# "cannot tell" must not take the same branch as "nothing is at risk".
cache_only_files() {
  local probe cached rel base dir on_drive
  # Positively prove the container answers before trusting anything it says. An
  # empty cache listing and a failed one look identical, and the exit status of a
  # pipeline is the last command's, so testing $? after `exec ... | sed` reads
  # sed's success and tells you nothing.
  probe=$(docker compose exec -T rclone sh -c \
            'rclone rc --rc-addr 127.0.0.1:5572 core/stats 2>/dev/null' </dev/null 2>/dev/null)
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$probe"; then
    printf 'CANNOT-TELL\n'; return 0
  fi
  cached=$(docker compose exec -T rclone sh -c \
             'find /root/.cache/rclone/vfs -type f 2>/dev/null' </dev/null 2>/dev/null \
           | sed 's|^/root/.cache/rclone/vfs/media/||')
  [[ -z "$cached" ]] && return 0
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    base=${rel##*/}; dir=${rel%/*}
    # A failed lsf yields no output, grep counts 0, and the file is then treated
    # as not on Drive - which errs towards calling it at risk. That is the safe
    # direction here.
    on_drive=$(docker compose exec -T rclone sh -c \
                 "rclone lsf --no-traverse \"media:$dir\" 2>/dev/null" </dev/null 2>/dev/null \
               | grep -cF -- "$base" || true)
    (( ${on_drive:-0} > 0 )) && continue
    [[ -f "${DATA_ROOT:-./data}/local/media/$rel" ]] && continue
    printf '%s\n' "$rel"
  done <<<"$cached"
}

run_update() {
  # cache_only_files needs DATA_ROOT. .env was only read by install_timer.
  [[ -f .env ]] && { set -a; source .env; set +a; }
  mkdir -p "$BACKUPS"; chmod 700 "$BACKUPS"
  local stamp changed unhealthy
  stamp=$(date +%F-%H%M%S)

  log "pulling images"
  docker compose --progress quiet pull -q
  # Dry-run lines look like " Container sonarr Recreate " (trailing space).
  changed=$(docker compose --progress plain up -d --dry-run 2>&1 | { grep -oE 'Container [^ ]+ Recreated?( |$)' || true; } | awk '{print $2}' | sort -u | paste -sd' ' -)
  if [[ -z "$changed" ]]; then
    log "nothing to update"; note "OK - nothing to update"; docker image prune -f >/dev/null; return 0
  fi
  log "new images for: $changed"

  # Two conditions, and both matter. rclone sits behind the "archive" compose
  # profile, so without a cloud tier it is not a service and can never appear in
  # $changed - but say so explicitly rather than lean on that, and skip the rc
  # probe entirely when there is no remote configured. Only a *recreate* empties
  # the cache; a stop and start preserves it.
  if [[ " $changed " == *" rclone "* ]] && archive_enabled; then
    local atrisk n
    atrisk=$(cache_only_files)
    n=$(printf '%s' "$atrisk" | grep -c . || true)
    if [[ "$atrisk" == *CANNOT-TELL* ]]; then
      log "cannot read rclone's cache or reach Drive - deferring rather than risk the cache"
      note "DEFERRED - could not verify rclone's cache before recreating it"
      return 0
    fi
    if (( n > 0 )); then
      log "$n file(s) exist only in rclone's cache and would be destroyed by recreating it:"
      printf '%s\n' "$atrisk" | sed 's/^/    /'
      log "move them onto the local branch first, or wait for the uploads to finish"
      note "DEFERRED - $n file(s) exist only in rclone's cache (see the log for which)"
      return 0
    fi
    log "rclone's cache holds nothing unique - safe to recreate"
  fi

  docker compose images > "$BACKUPS/images-$stamp.txt"
  log "stopping the stack for a consistent snapshot"
  docker compose --progress quiet stop
  tar --exclude='config/plex/Library/Application Support/Plex Media Server/Cache' \
      -czf "$BACKUPS/config-$stamp.tar.gz" config .env
  chmod 600 "$BACKUPS/config-$stamp.tar.gz" "$BACKUPS/images-$stamp.txt"
  log "snapshot $BACKUPS/config-$stamp.tar.gz"

  log "recreating"
  docker compose --progress quiet up -d
  if unhealthy=$(wait_healthy); then
    log "all healthy"
  else
    note "FAILED - unhealthy after update: $unhealthy (snapshot config-$stamp.tar.gz, images-$stamp.txt)"
    log "FAILED: still unhealthy: $unhealthy"
    log "rollback: docker compose stop; tar -xzf $BACKUPS/config-$stamp.tar.gz; pin the tag from $BACKUPS/images-$stamp.txt in .env; docker compose up -d"
    return 1
  fi
  docker image prune -f >/dev/null

  # keep the last KEEP snapshots
  ls -1t "$BACKUPS"/config-*.tar.gz 2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
  ls -1t "$BACKUPS"/images-*.txt   2>/dev/null | tail -n +$((KEEP+1)) | xargs -r rm -f
  note "OK - updated: $changed"
  log "done"
}

install_timer() {
  local dir=~/.config/systemd/user day at
  [[ -f .env ]] && { set -a; source .env; set +a; }
  day=${UPDATE_DAY-Sun}; at=${UPDATE_TIME:-04:00}
  [[ -z "$day" || "$day" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$ ]] || { echo "UPDATE_DAY must be a weekday such as Sun, or empty for every day (got \"$day\")" >&2; exit 1; }
  [[ "$at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "UPDATE_TIME must be HH:MM (got \"$at\")" >&2; exit 1; }
  mkdir -p "$dir"
  cat > "$dir/$UNIT.service" <<UNIT
[Unit]
Description=media-stack: pull new images and recreate containers
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$HERE
ExecStart=$HERE/update.sh
UNIT
  cat > "$dir/$UNIT.timer" <<UNIT
[Unit]
Description=media-stack image update (${day:-every day} $at)

[Timer]
OnCalendar=${day:+$day }*-*-* $at:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer" >/dev/null
  echo "timer enabled:"; systemctl --user list-timers "$UNIT.timer" --no-pager | head -2
  # Without lingering, user timers only run while you are logged in.
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
  systemctl --user list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -2 || echo "timer not installed (./update.sh install)"
  echo "lingering: $(loginctl show-user "$USER" -p Linger --value 2>/dev/null)"
  echo "--- recent log:"; journalctl --user -u "$UNIT" -n 12 --no-pager -o cat 2>/dev/null || true
  echo "--- snapshots:"; ls -1 "$BACKUPS"/config-*.tar.gz 2>/dev/null || echo "none"
}

case "${1:-}" in
  "")       run_update ;;
  install)  install_timer ;;
  status)   show_status ;;
  *) echo "usage: $0 [install|status]" >&2; exit 2 ;;
esac
