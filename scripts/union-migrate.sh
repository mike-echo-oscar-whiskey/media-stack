#!/usr/bin/env bash
# One-time move to the union layout. See README "The archive tier".
#
#   before                        after
#   data/media                    data/local/media      <- the local branch
#   data/torrents                 data/local/torrents
#   data/usenet                   data/local/usenet
#   data/archive   (rclone mount) data/archive/media    <- the cloud branch,
#                                                          rclone mounts deeper
#                                 data/union            <- mergerfs over both
#
# The renames are within one filesystem, so they are instant and nothing is
# copied. Needs root only to start the system mount unit; the moves run as you.
# Idempotent: if data/local already exists it says so and stops.
set -euo pipefail

(( EUID == 0 )) || { echo "run this with sudo - it has to start the mount unit" >&2; exit 1; }
OWNER=${SUDO_USER:-}; [[ -n "$OWNER" ]] || { echo "run through sudo, not as root" >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
D=$ROOT/data
say() { printf '  %s\n' "$*"; }
as_owner() { sudo -u "$OWNER" "$@"; }

command -v mergerfs >/dev/null || { echo "mergerfs missing - run scripts/union-setup.sh" >&2; exit 1; }
[[ -f /etc/systemd/system/media-stack-union.service ]] || { echo "the mount unit is missing - run scripts/union-setup.sh" >&2; exit 1; }
if [[ -d $D/local ]]; then say "data/local already exists - already migrated, nothing to do"; exit 0; fi

say "stopping the stack so the cloud mount is released"
as_owner docker compose down

# The mount has to be gone before data/archive can be reshaped, and a stale FUSE
# mount survives the container that made it.
if mountpoint -q "$D/archive"; then
  say "data/archive is still a mountpoint - unmounting"
  fusermount -u "$D/archive" 2>/dev/null || umount -l "$D/archive"
fi
mountpoint -q "$D/archive" && { echo "data/archive is still mounted; stopping here" >&2; exit 1; }

# After the unmount this is the plain directory underneath. Anything in it was
# written while the mount was down and would be shadowed by the remount, so it
# is a finding, not something to move silently.
leftover=$(find "$D/archive" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)
if (( leftover > 0 )); then
  echo "  data/archive is not empty under the mount ($leftover entries):" >&2
  find "$D/archive" -mindepth 1 -maxdepth 1 -printf '    %p\n' >&2
  echo "  those would be hidden once rclone remounts. Move or delete them, then re-run." >&2
  exit 1
fi

say "moving the local libraries under data/local/"
as_owner mkdir -p "$D/local"
for d in media torrents usenet; do
  [[ -d $D/$d ]] || { say "  data/$d does not exist, skipping"; continue; }
  mv "$D/$d" "$D/local/$d"
  say "  data/$d -> data/local/$d"
done
as_owner mkdir -p "$D/archive/media" "$D/union"

say "starting the union"
systemctl start media-stack-union.service
sleep 1
mountpoint -q "$D/union" || { echo "the union did not mount - check: systemctl status media-stack-union" >&2; exit 1; }
say "  union mounted, showing: $(ls -1 "$D/union" | tr '\n' ' ')"
say "  media: $(ls -1 "$D/union/media" 2>/dev/null | tr '\n' ' ')"

say "bringing the stack back up"
as_owner docker compose up -d

cat <<'NEXT'

  Layout migrated. The apps are up but their archived titles still point at
  /data/archive, which no longer exists inside them - tell Claude, and it will
  repoint those records onto /data/media without moving a byte.
NEXT
