#!/usr/bin/env bash
# Moves titles from the local library to the archive tier when the disk fills:
#
#   ./mover.sh             archive the oldest titles until there is room again
#   ./mover.sh --now       the same, but do not wait for the quiet window
#   ./mover.sh install     systemd user timer, hourly
#   ./mover.sh status      last result, next run
#
# Why: /data/media lives on one disk that /data/torrents and /data/usenet share,
# and a full filesystem takes the whole stack down rather than degrading. The
# disk brakes in heal.sh stop new downloads at DISK_FLOOR_GIB, which keeps the
# machine alive but also stops the library growing. This is the other half:
# below DISK_WARN_GIB it moves the least recently added titles to the archive
# until ARCHIVE_REMOTE_PERCENT of it is in the cloud, so the floor is approached less
# often in the first place.
#
# The move goes through Sonarr's and Radarr's own API with moveFiles, never by
# moving files behind their backs: they own the database that says where a title
# lives, and a file moved underneath them is a file they report as missing.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
UNIT=media-stack-mover
STATUS=backups/last-mover.txt

# To stderr, not stdout. archive_files returns its byte count by printing it, and
# the caller reads that with $(...) - so a log line on stdout arrives inside the
# number and the arithmetic dies on it ("value too great for base", the date
# being read as octal). systemd captures both streams, so the journal is
# unchanged. The first real archive run found this; no earlier run had ever
# moved a byte, so the line that adds up the total had never executed.
log()  { printf '%s  %s\n' "$(date '+%F %T')" "$*" >&2; }
note() { mkdir -p backups; printf '%s  %s\n' "$(date '+%F %T')" "$*" > "$STATUS"; }

apikey() { sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' "config/$1/config.xml"; }

# alerts_on and ntfy_push - shared with heal.sh and watch.sh.
. lib/alerts.sh
# common.sh as well, for unrestricted_window - the same UNRESTRICTED_HOURS the
# download caps use, parsed in one place rather than a second copy here.
. lib/common.sh

# free_gib PATH - whole GiB available on the filesystem holding PATH.
# human_bytes BYTES - GiB once there is a gibibyte to speak of, MiB below that.
# "archived 0 GiB" after a run that moved 984 MiB reads as a failed run.
human_bytes() {
  if (( $1 >= 1073741824 )); then printf '%s GiB' "$(( $1 / 1073741824 ))"
  else printf '%s MiB' "$(( $1 / 1048576 ))"; fi
}

free_gib() {
  local avail
  avail=$(df -k --output=avail "$1" 2>/dev/null | tail -n1 | tr -d ' ') || return 1
  [[ "$avail" =~ ^[0-9]+$ ]] || return 1
  printf '%s' $(( avail / 1048576 ))
}

# segments_fit HOSTPATH - true when every path component under HOSTPATH is short
# enough to survive crypt's filename encryption. rclone's standard encryption
# with base64 caps a component at about 175 bytes of plaintext, and a name that
# does not fit fails at upload time, halfway through a title. Checked in bytes,
# not characters: a non-Latin title costs two or three bytes per character.
segments_fit() {
  local root=$1 over
  over=$(find "$root" -mindepth 1 -printf '%f\n' 2>/dev/null |
         awk '{ n = length($0); if (n > 175) c++ } END { print c + 0 }')
  (( over == 0 ))
}

# segment_fits RELATIVE/PATH - the same 175-byte rule for one file's own path.
# The per-file mover needs it because a title is no longer moved whole: one
# episode whose name will not encrypt must not disqualify the rest of the series.
segment_fits() {
  local seg
  local IFS=/
  for seg in $1; do
    (( ${#seg} <= 175 )) || return 1
  done
  return 0
}


# vfs_drain - wait until rclone has finished uploading what the moves wrote.
# A move into the mount returns as soon as the bytes are in rclone's local
# cache; the upload happens afterwards. Finishing a run with gigabytes still
# queued means the next run starts on top of it, so the queue is drained before
# the run reports what it did.
vfs_drain() {
  local q i
  for i in $(seq 1 360); do
    q=$(docker compose exec -T rclone rclone rc vfs/queue 2>/dev/null | jq '.queue | length' 2>/dev/null)
    [[ "$q" =~ ^[0-9]+$ ]] || return 0      # no rc, nothing to wait for
    (( q == 0 )) && return 0
    (( i % 6 == 1 )) && log "  waiting for $q upload(s) to finish"
    sleep 10
  done
  log "  uploads still queued after an hour - leaving them to rclone"
  return 0
}

in_quiet_window() {
  local fh fm th tm now from to spec
  # Via a variable, not a process substitution: unrestricted_window printf's
  # without a trailing newline, so `read` fills the variables and still returns
  # 1 at EOF - which made "|| return 0" answer "inside the window" at every hour
  # of the day.
  spec=$(unrestricted_window) || return 0
  read -r fh fm th tm <<<"$spec"
  now=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  from=$(( fh * 60 + fm )); to=$(( th * 60 + tm ))
  if (( from < to )); then (( now >= from && now < to ))
  else                     (( now >= from || now < to )); fi
}


archive_share() {                 # prints "LOCAL_BYTES REMOTE_BYTES"
  local l r
  l=$(du -sb "$LOCAL" 2>/dev/null | cut -f1); [[ "$l" =~ ^[0-9]+$ ]] || l=0
  r=$(docker compose exec -T rclone rclone size media: --json 2>/dev/null | jq -r '.bytes // 0')
  [[ "$r" =~ ^[0-9]+$ ]] || r=0
  printf '%s %s' "$l" "$r"
}

# RCLONE_CACHE_MAX as whole GiB. rclone's suffixes are binary, so 50G is 50 GiB
# - the same arithmetic as everywhere else here, and the reason a bare number is
# read as bytes rather than as anything friendlier.
rclone_cache_gib() {
  local v=${RCLONE_CACHE_MAX:-} n
  [[ -n "$v" ]] || { printf 0; return 0; }
  n=${v%%[!0-9]*}
  [[ "$n" =~ ^[0-9]+$ && -n "$n" ]] || { printf 0; return 0; }
  case "${v#"$n"}" in
    G|Gi|GiB|g)  printf '%s' "$n" ;;
    T|Ti|TiB|t)  printf '%s' "$(( n * 1024 ))" ;;
    M|Mi|MiB|m)  printf '%s' "$(( n / 1024 ))" ;;
    '')          printf '%s' "$(( n / 1073741824 ))" ;;
    *)           printf 0 ;;
  esac
}


# One pass over the local branch, oldest file first, moving individual files to
# the cloud branch. Everything the per-title version needed an app for is gone:
#
#   - a hardlinked file is excluded by find itself (-links 1), so one episode
#     still seeding no longer pins the other thirty in the same series. That was
#     the whole-folder check, and it kept 40 GiB local for the sake of one file.
#   - no root folder changes, so no app call, no command queue to wait on and no
#     library rescan. To Sonarr, Plex and Jellyfin the file never moved: it is at
#     the same /data/media path through the union either way. That is what the
#     union is for.
#   - a file under ARCHIVE_MIN_FILE_MIB stays local. Subtitles and metadata cost
#     nothing on disk and Bazarr rewrites them; sending them to the cloud buys no
#     space and makes every write a round trip.
#
# Prints the bytes it moved.
archive_files() {
  local moved=0 ts bytes file rel dest dir
  while IFS=$'\t' read -r ts bytes file; do
    [[ -n "$file" ]] || continue
    if (( moved + bytes > MAX_BYTES_PER_RUN )); then
      (( moved > 0 )) && continue
      log "  $(basename "$file") is $(( bytes / 1048576 )) MiB, over the $MAX_GIB GiB cap - moving it alone"
    fi
    (( moved < NEED_BYTES )) || { log "  stop: this run's share is moved"; break; }

    rel=${file#"$LOCAL"/}
    if ! segment_fits "$rel"; then
      log "  skip $rel - a path component is too long to encrypt"
      continue
    fi
    dest=$CLOUD/$rel
    dir=$(dirname "$dest")
    mkdir -p "$dir" || { log "  FAILED to create $dir"; continue; }

    # Copy to a .part beside the destination, then rename on the cloud branch
    # before unlinking the original. A plain mv across the FUSE boundary is a
    # copy and an unlink with nothing between them, so an interrupted run would
    # leave a short file under the real name and the library would read a
    # truncated episode as if it were fine.
    if cp --preserve=timestamps "$file" "$dest.part" 2>/dev/null && mv "$dest.part" "$dest" 2>/dev/null; then
      rm -f "$file"
      moved=$(( moved + bytes ))
      log "  archived $rel ($(( bytes / 1048576 )) MiB)"
    else
      rm -f "$dest.part" 2>/dev/null || true
      log "  FAILED $rel - left where it is"
    fi
  # -mmin, not -mtime: find's -mtime counts in whole days, so `-mtime +0` means
  # "at least 24 hours" and ARCHIVE_MIN_AGE_DAYS=0 cannot express "no hold at
  # all" - which is what 0 reads as, and what someone setting it to 0 wants. In
  # minutes the arithmetic is exact and 0 means 0. Everything above a day behaves
  # as before: +1 is 1440 minutes either way.
  done < <(find "$LOCAL" -type f -links 1 -size +"${MIN_FILE_MIB}M" -mmin +"$(( MIN_AGE_DAYS * 1440 ))" \
             -printf '%T@\t%s\t%p\n' 2>/dev/null | sort -n)
  printf '%s' "$moved"
}

mover() {
  [[ -f .env ]] && { set -a; source .env; set +a; }
  DATA=${DATA_ROOT:-./data}
  REMOTE_PCT=${ARCHIVE_REMOTE_PERCENT:-0}
  MAX_GIB=${ARCHIVE_MAX_GIB_PER_RUN:-50}
  MIN_AGE_DAYS=${ARCHIVE_MIN_AGE_DAYS:-90}
  MIN_FILE_MIB=${ARCHIVE_MIN_FILE_MIB:-64}
  # The two branches of the union. The mover is the one thing in the stack that
  # addresses them directly instead of going through data/union: moving a file
  # from one branch to the other through the union would be a copy onto itself.
  LOCAL=$DATA/local/media
  CLOUD=$DATA/archive/media
  local warn=${DISK_WARN_GIB:-0} floor=${DISK_FLOOR_GIB:-0}

  for n in REMOTE_PCT MAX_GIB MIN_AGE_DAYS MIN_FILE_MIB; do
    [[ "${!n}" =~ ^[0-9]+$ ]] || { log "$n must be a whole number (got \"${!n}\")"; note "bad configuration: $n"; return 0; }
  done
  (( REMOTE_PCT <= 100 )) || { log "ARCHIVE_REMOTE_PERCENT is a share, 0 to 100 (got $REMOTE_PCT)"; note "bad configuration: ARCHIVE_REMOTE_PERCENT"; return 0; }
  # Both off is off. The share is the steady-state policy and the warn mark is
  # the emergency one; either alone is a working configuration.
  (( REMOTE_PCT > 0 || warn > 0 )) || { note "off (ARCHIVE_REMOTE_PERCENT=0 and DISK_WARN_GIB=0)"; return 0; }
  # Everything a run moves is written through rclone's cache before it uploads,
  # and a file still waiting to upload is the one thing rclone will not evict.
  # So the cap has to fit the cache - half of it, not all: vfs-cache-max-age is
  # an hour and the timer fires hourly, so two runs can be resident at once.
  # Clamped rather than refused, because a disk filling is the worse outcome.
  local cache_gib; cache_gib=$(rclone_cache_gib)
  if (( cache_gib > 0 && MAX_GIB * 2 > cache_gib )); then
    log "ARCHIVE_MAX_GIB_PER_RUN ($MAX_GIB) is over half of RCLONE_CACHE_MAX ($cache_gib GiB) - using $(( cache_gib / 2 )) this run"
    MAX_GIB=$(( cache_gib / 2 ))
  fi
  MAX_BYTES_PER_RUN=$(( MAX_GIB * 1073741824 ))

  # No archive at all is a normal state, not a fault: the tier is opt-in, and a
  # stack with a big enough disk never needs it.
  #
  # archive_enabled from lib/alerts.sh, never a copy of it. This test lived here
  # inline as well, and when the shared one was fixed - rclone.conf is root-owned
  # 0600, so grep exits 2 for "cannot read", which is not "no remote" - this copy
  # kept the old logic and went on answering no. The mover archived nothing at
  # all while the disk sat under its own warn mark, and said "no archive
  # configured" every hour to a stack whose archive was mounted and working.
  if ! archive_enabled; then
    note "no archive configured (see README \"The archive tier\")"
    return 0
  fi

  # Nothing is archived unless both branches are real. The mover addresses the
  # branches directly, so an unmounted cloud branch is not a read failure - it is
  # a plain directory on the local disk, and a "move to the cloud" would write the
  # bytes to the very disk the run is trying to free, then have them hidden
  # completely the moment rclone mounts over them. The apps cannot be asked about
  # this any more: /data/archive does not exist inside them.
  if ! mountpoint -q "$CLOUD"; then
    log "the cloud branch $CLOUD is not mounted - nothing moved"
    note "cloud branch not mounted"
    return 0
  fi
  if [[ ! -d "$LOCAL" ]]; then
    log "the local branch $LOCAL is missing - nothing moved"
    note "local branch missing"
    return 0
  fi
  if ! mountpoint -q "$DATA/union"; then
    log "the union is not mounted - the apps are reading a half library; nothing moved"
    note "union not mounted"
    return 0
  fi

  local free before
  # The local branch, not the union: the union's own statfs describes neither
  # disk, and freeing space is about the one the library sits on.
  free=$(free_gib "$LOCAL") || { log "cannot read free space on $LOCAL"; return 0; }
  before=$free

  # Two reasons to move, and they are not the same thing. The share is where the
  # library is meant to live: ARCHIVE_REMOTE_PERCENT of it in the cloud, counted
  # over local plus archived so the denominator does not shrink as it works and
  # leave the figure chasing itself. Disk pressure is the emergency, and it
  # overrides the share - below the warn mark it moves whatever the per-run cap
  # allows, whether the share is already met or not.
  local lb rb total want short=0
  read -r lb rb <<<"$(archive_share)"
  total=$(( lb + rb ))
  if (( REMOTE_PCT > 0 && total > 0 )); then
    want=$(( total / 100 * REMOTE_PCT ))
    (( rb < want )) && short=$(( want - rb ))
  fi

  local pressure=0
  (( warn > 0 && free < warn )) && pressure=1
  if (( short == 0 && ! pressure )); then
    note "nothing to do: $(( rb * 100 / (total > 0 ? total : 1) ))% of the library is already archived, $free GiB free"
    return 0
  fi
  # Under pressure the cap is the only limit; otherwise move only the shortfall.
  NEED_BYTES=$(( pressure ? MAX_BYTES_PER_RUN : short ))

  # Archiving is a bulk upload on the uplink Plex streams out on, and moving a
  # title is most disruptive while someone is watching it. So it waits for the
  # quiet window, where the line is uncapped anyway - except below
  # DISK_FLOOR_GIB, where downloading has already stopped and a full disk is a
  # worse problem than a slow evening.
  # --now is for clearing a backlog by hand: the hold below is about being a
  # good neighbour on the uplink, not about safety, and there is no way to ask
  # for "archive it all, I am watching it" without it. The timer never passes
  # it, so unattended runs still wait for the window.
  if (( ! FORCE )) && (( free > floor )) && ! in_quiet_window; then
    # Name the reason it wants to run, not the one it used to: with a share
    # policy the disk can be nowhere near the warn mark and there is still work.
    local why
    if (( pressure )); then why="$free GiB free, below the $warn GiB mark"
    else why="$(( rb * 100 / total ))% of the library archived, target $REMOTE_PCT%"; fi
    note "$why - waiting for ${UNRESTRICTED_HOURS:-the quiet window} to archive"
    log "$why - holding until ${UNRESTRICTED_HOURS:-the quiet window}"
    return 0
  fi

  if (( pressure )); then
    log "$free GiB free, below the $warn GiB mark - archiving up to $MAX_GIB GiB this run"
  else
    log "$(( rb * 100 / total ))% of the library archived, target $REMOTE_PCT% - $(( short / 1073741824 )) GiB to move"
  fi
  # One pass over the whole local branch rather than one per app: a file is a
  # file and the branch does not care which app owns it. Belt and braces on the
  # return value all the same - anything that is not a byte count is a fault in
  # archive_files, and losing the run's total is the smaller failure.
  local moved=0 m
  m=$(archive_files)
  if [[ "$m" =~ ^[0-9]+$ ]]; then moved=$m
  else log "  archive_files returned something that is not a byte count, ignoring it"; fi

  # No library rescan. The files are at the same /data/media paths through the
  # union as they were before, so there is nothing for Plex, Jellyfin or the arr
  # apps to notice - which is the reason the union exists.
  (( moved > 0 )) && vfs_drain
  free=$(free_gib "$LOCAL") || free=$before
  if (( moved > 0 )); then
    log "archived $(human_bytes "$moved"); $before -> $free GiB free"
    note "archived $(human_bytes "$moved"), $free GiB free"
    # Worth saying out loud: titles left the local disk. They still play, but
    # what is where has changed, and the disk alert that prompted this said the
    # mover was on it - this is the other half of that sentence.
    alerts_on disk && ntfy_push "archive: $(human_bytes "$moved") moved" \
      "Freed space on the local disk, $before -> $free GiB. The titles still play; they are read from the archive now." disk
  else
    log "nothing archived - no candidate older than $MIN_AGE_DAYS days"
    note "nothing to archive: $free GiB free, no candidate older than $MIN_AGE_DAYS days"
  fi
  return 0
}

install_timer() {
  local dir=~/.config/systemd/user
  mkdir -p "$dir"
  cat > "$dir/$UNIT.service" <<UNIT
[Unit]
Description=media-stack: move old titles to the archive tier
After=docker.service

[Service]
Type=oneshot
WorkingDirectory=$HERE
ExecStart=$HERE/mover.sh
UNIT
  cat > "$dir/$UNIT.timer" <<UNIT
[Unit]
Description=media-stack archive mover (hourly)

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer" >/dev/null
  echo "timer enabled:"; systemctl --user list-timers "$UNIT.timer" --no-pager | head -2
}

show_status() {
  echo "--- last run:"; cat "$STATUS" 2>/dev/null || echo "never run"
  echo "--- next run:"
  systemctl --user list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -2 || echo "timer not installed (./mover.sh install)"
  echo "--- archived in the last 30 days:"
  journalctl --user -u "$UNIT" --since '30 days ago' --no-pager -o cat 2>/dev/null | grep -E 'archiving|archived' || echo "nothing"
}

FORCE=0
case "${1:-}" in
  "")       mover ;;
  --now)    FORCE=1; mover ;;
  install)  install_timer ;;
  status)   show_status ;;
  *) echo "usage: $0 [--now|install|status]" >&2; exit 2 ;;
esac
