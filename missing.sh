#!/usr/bin/env bash
# Retries what Radarr and Sonarr still lack, unattended:
#
#   ./missing.sh           ask both apps to search every missing film and episode
#   ./missing.sh install   systemd user timer, nightly at 02:00
#   ./missing.sh status    last result, next run
#
# Why: after a failed download the apps blocklist the release and try the
# next candidate at once, but when they run out they stop for good. From
# then on a missing title only returns if a brand-new release shows up in
# the hourly RSS feed. This asks for a fresh search once a night, inside the
# UNRESTRICTED_HOURS window, with the profiles, the fake-release format and
# the release guard applied as on any other grab.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
UNIT=media-stack-missing
STATUS=backups/last-missing.txt

apikey() { sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$1/config.xml"; }

search() {
  local line ids
  # Radarr's own "search missing" ignores release dates and would fetch fakes
  # of unreleased films, so the films are picked here: monitored, released,
  # no file.
  ids=$(curl -fsS -m 20 -H "X-Api-Key: $(apikey radarr)" http://localhost:7878/api/v3/movie | jq -c '[.[] | select(.monitored and .isAvailable and (.hasFile | not)) | .id]')
  line="radarr: $(jq length <<<"$ids") released films missing, "
  if [[ $(jq length <<<"$ids") -gt 0 ]]; then
    curl -fsS -m 20 -o /dev/null -H "X-Api-Key: $(apikey radarr)" -H 'Content-Type: application/json' \
      -X POST --data "{\"name\":\"MoviesSearch\",\"movieIds\":$ids}" http://localhost:7878/api/v3/command
  fi
  line+="search started; sonarr: $(curl -fsS -m 20 -H "X-Api-Key: $(apikey sonarr)" http://localhost:8989/api/v3/wanted/missing?pageSize=1 | jq -r '.totalRecords') episodes missing, "
  curl -fsS -m 20 -o /dev/null -H "X-Api-Key: $(apikey sonarr)" -H 'Content-Type: application/json' \
    -X POST --data '{"name":"MissingEpisodeSearch"}' http://localhost:8989/api/v3/command
  line+="search started"
  mkdir -p backups; printf '%s  %s\n' "$(date '+%F %T')" "$line" | tee "$STATUS"
}

install_timer() {
  local dir=~/.config/systemd/user at
  [[ -f .env ]] && { set -a; source .env; set +a; }
  at=${MISSING_SEARCH_TIME:-02:00}
  [[ "$at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "MISSING_SEARCH_TIME must be HH:MM (got \"$at\")" >&2; exit 1; }
  mkdir -p "$dir"
  cat > "$dir/$UNIT.service" <<UNIT
[Unit]
Description=media-stack: search missing films and episodes
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$HERE
ExecStart=$HERE/missing.sh
UNIT
  cat > "$dir/$UNIT.timer" <<UNIT
[Unit]
Description=media-stack nightly missing search ($at)

[Timer]
OnCalendar=*-*-* $at:00
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer" >/dev/null
  echo "timer enabled:"; systemctl --user list-timers "$UNIT.timer" --no-pager | head -2
  if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) != yes ]]; then
    echo "NOTE: run once as root so the timer also fires when you are not logged in:"
    echo "      sudo loginctl enable-linger $USER"
  fi
}

show_status() {
  echo "last run: $(cat "$STATUS" 2>/dev/null || echo 'never')"
  systemctl --user list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -2 || echo "timer not installed (./missing.sh install)"
}

case "${1:-}" in
  "")       search ;;
  install)  install_timer ;;
  status)   show_status ;;
  *) echo "usage: $0 [install|status]" >&2; exit 2 ;;
esac
