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

run_update() {
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
