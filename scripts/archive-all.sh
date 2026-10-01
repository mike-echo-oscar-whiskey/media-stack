#!/usr/bin/env bash
# Archive every eligible title in one sitting, instead of waiting for the hourly
# timer to trickle them out.
#
#   ./scripts/archive-all.sh              passes until nothing is eligible
#   ./scripts/archive-all.sh --uncapped   and ignore ARCHIVE_UPLOAD_WINDOW
#
# Why: mover.sh moves at most RCLONE_CACHE_MAX/2 per run and only inside the
# quiet window, which is right for a stack ticking over and useless after a
# change frees a large batch at once. Dropping the public seeding limits to 0
# unpinned 197 GiB here in one go - the hardlinks were what kept the mover from
# seeing it - and at one capped pass an hour that is days of trickling.
#
# Each pass is a whole `mover.sh --now`, so this is safe to interrupt: the mover
# waits on rclone's vfs/queue before it unlinks anything, and a killed pass
# leaves the title on whichever branch it was already on.
#
# What this deliberately does NOT do is recreate the rclone container between
# passes to flush the VFS cache. That looks attractive - the cache holds what it
# just uploaded for --vfs-cache-max-age, so a pass can appear to free nothing -
# but mergerfs keeps the branch open for as long as the union is assembled, so
# the mountpoint is never idle and the recreate leaves a dead FUSE endpoint that
# only root can clear. See AGENTS.md. The cache reclaims itself through
# --vfs-cache-max-size and --vfs-cache-max-age; let it.
set -uo pipefail
cd "$(dirname "$0")/.."

UNCAPPED=0
case "${1:-}" in
  "")          ;;
  --uncapped)  UNCAPPED=1 ;;
  *) echo "usage: $0 [--uncapped]" >&2; exit 2 ;;
esac

MIN_MIB=$(sed -n 's/^ARCHIVE_MIN_FILE_MIB=//p' .env 2>/dev/null); MIN_MIB=${MIN_MIB:-64}
MIN_AGE=$(sed -n 's/^ARCHIVE_MIN_AGE_DAYS=//p' .env 2>/dev/null); MIN_AGE=${MIN_AGE:-3}

say() { printf '%s  %s\n' "$(date '+%F %T')" "$*"; }
rc()  { docker exec rclone rclone rc --rc-addr 127.0.0.1:5572 "$@" 2>/dev/null; }
eligible() {
  find data/local/media -type f -links 1 -size +"${MIN_MIB}"M -mtime +"$MIN_AGE" -printf '%s\n' 2>/dev/null \
    | awk '{s+=$1;n++} END {printf "%d %d\n", n+0, s+0}'
}
# Runtime only - .env keeps ARCHIVE_UPLOAD_WINDOW, so the cap comes back of its
# own accord the next time the container starts, even if this script is killed.
uncap() { (( UNCAPPED )) && rc core/bwlimit rate=off >/dev/null; return 0; }

while pgrep -f '[m]over.sh' >/dev/null; do sleep 30; done
uncap && (( UNCAPPED )) && say "upload uncapped for the duration (.env untouched)"

for pass in $(seq 1 200); do
  read -r n b < <(eligible)
  say "pass $pass: $n file(s) / $(( b / 1073741824 )) GiB still local, $(df -BG --output=avail data/local | tail -1 | tr -d ' ') free"
  (( n == 0 )) && { say "nothing left to archive"; break; }
  mountpoint -q data/archive/media || { say "archive branch not mounted - stopping"; break; }
  before=$b
  ./mover.sh --now
  uncap
  # A pass that moved nothing means the mover is declining for a reason this
  # loop cannot see, and without this it spins - calling mover.sh hundreds of
  # times a minute and logging a pass for each.
  read -r _ after < <(eligible)
  (( after == before )) && { say "pass $pass moved nothing - stopping rather than spinning"; break; }
done

read -r n b < <(eligible)
say "final: $n file(s) / $(( b / 1073741824 )) GiB still local, $(df -BG --output=avail data/local | tail -1 | tr -d ' ') free"
