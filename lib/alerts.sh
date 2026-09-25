# Pushing an alert to ntfy, shared by the scripts that run on timers.
#
# Sourced by heal.sh, watch.sh and mover.sh rather than copied into each: the
# vocabulary in NTFY_EVENTS and NTFY_PRIORITY has to mean the same thing
# everywhere, and three copies of it would drift. configure.sh also picks this
# up from lib/*.sh and simply does not use it - it has lib/notify.sh for
# setting the apps up, which is a different job.
#
# Nothing here writes to a log or a status file: each caller has its own.

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
# True when there is an archive to overflow into: a crypt remote exists and the
# compose profile that carries the mount is switched on. Both matter - a remote
# nothing mounts is no more use than no remote at all.
archive_enabled() {
  local conf=${CONFIG_ROOT:-./config}/rclone/rclone.conf
  [[ -s "$conf" ]] || return 1
  docker compose config --services 2>/dev/null | grep -qx rclone || return 1
  # rclone writes this file as root with mode 600, so an unprivileged caller -
  # which is every one of these timers, they are systemd *user* units - cannot
  # read it. grep then exits 2, meaning "cannot tell", not 1 for "no such
  # remote", and the old `2>/dev/null || return 1` read the two as the same
  # thing: every archive branch below went silently dead for the owner of the
  # stack while the mount was up and working.
  # Unreadable, non-empty, and the profile switched on means configured. Err
  # towards enabled: watch.sh then runs its own mount check and alerts if the
  # mount is really gone, where erring towards disabled makes that silent.
  [[ -r "$conf" ]] || return 0
  grep -q '^\[media\]' "$conf"
}
