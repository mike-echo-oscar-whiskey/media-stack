#!/usr/bin/env bash
# Recreate the rclone container safely. Needs root, because the union is a
# systemd *system* unit and the archive branch is root-owned.
#
# Why this cannot be done casually: recreating rclone while the union is
# assembled leaves a dead FUSE endpoint - listed in /proc/mounts, answering
# "Transport endpoint is not connected", invisible to mountpoint -q - and the
# replacement container restart-loops on "failed to access mountpoint ... Socket
# not connected". fusermount3 -u cannot clear it. mergerfs holds the branch open
# for as long as the union exists, so there is no idle moment: the union has to
# come down first. See AGENTS.md, "Never recreate the rclone container while the
# union is assembled".
#
# Run it as:  ! sudo ./scripts/rclone-recreate.sh
# Add --dry-run to see the steps without touching anything.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
OWNER=$(stat -c %U compose.yml)
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1

say()  { printf '\n== %s\n' "$*"; }
run()  { if (( DRY )); then printf '   would run: %s\n' "$*"; else printf '   %s\n' "$*"; "$@"; fi; }
dc()   { run runuser -u "$OWNER" -- docker compose "$@"; }

if (( ! DRY )) && [[ $EUID -ne 0 ]]; then
  echo "This needs root (systemctl on a system unit, and umount of a root-owned mount)."
  echo "Run:  ! sudo ./scripts/rclone-recreate.sh"
  exit 1
fi

say "0. refuse to run while the mover is mid-copy"
# Two ways the mover can be running: its timer, or someone invoking it by hand
# with --now. The bracket keeps pgrep from matching its own command line, which
# would make this test unable to ever return false.
if systemctl --user --machine="$OWNER@" is-active media-stack-mover.service >/dev/null 2>&1 \
   || pgrep -f 'move[r]\.sh' >/dev/null 2>&1; then
  echo "   the mover is RUNNING - a bounce now could leave a half-copied file."
  echo "   Wait for it to finish and run this again."
  exit 1
fi
# rclone still writing is the same hazard, by a different route.
q=$(runuser -u "$OWNER" -- docker compose exec -T rclone sh -c \
      'rclone rc --rc-addr 127.0.0.1:5572 core/stats 2>/dev/null' 2>/dev/null \
    | jq -r '(.transferring // []) | length' 2>/dev/null)
if [[ -n "${q:-}" && "$q" != 0 ]]; then
  echo "   rclone is uploading $q file(s) - wait for them to finish."
  exit 1
fi
echo "   mover idle, no uploads in flight"

say "1. what will change"
echo "   --rc-addr          127.0.0.1:5572  ->  0.0.0.0:5572   (so Homepage can read it)"
echo "   --rc-user/--rc-pass  absent        ->  set            (the rc authenticates)"
echo "   --vfs-cache-max-size         20G   ->  50G            (durable, not just runtime)"

say "2. stop every container, releasing their /data handles"
dc stop

say "3. bring the union down (this is the step that needs root)"
run systemctl stop media-stack-union.service
if mountpoint -q "$ROOT/data/union"; then
  echo "   union still mounted - forcing a lazy unmount"
  run umount -l "$ROOT/data/union"
fi

say "4. clear the archive branch if it lingers as a dead endpoint"
if grep -q " $ROOT/data/archive/media " /proc/mounts; then
  echo "   branch still listed in /proc/mounts - lazy unmount"
  run umount -l "$ROOT/data/archive/media"
else
  echo "   branch already clear"
fi

say "5. recreate rclone with the compose.yml configuration"
dc up -d --force-recreate rclone

say "6. wait for the mount to answer (the healthcheck tests the mount, not the process)"
if (( ! DRY )); then
  for i in $(seq 1 60); do
    s=$(runuser -u "$OWNER" -- docker inspect -f '{{.State.Health.Status}}' rclone 2>/dev/null)
    [[ "$s" == healthy ]] && { echo "   healthy after ${i}0s"; break; }
    sleep 10
  done
  [[ "${s:-}" == healthy ]] || { echo "   rclone did not become healthy - NOT starting the union"; exit 1; }
fi

say "7. bring the union back up"
run systemctl start media-stack-union.service

say "8. start the rest of the stack"
dc up -d

say "9. verify"
if (( ! DRY )); then
  for p in data/archive/media data/union; do
    mountpoint -q "$ROOT/$p" && echo "   $p: mounted" || echo "   $p: NOT MOUNTED"
  done
  runuser -u "$OWNER" -- ./scripts/union-verify.sh || echo "   union-verify reported a problem"
  echo "   rc reachable from Homepage:"
  runuser -u "$OWNER" -- docker compose exec -T homepage sh -c \
    'wget -qO- --timeout=5 --post-data="" --user="$1" --password="$2" http://rclone:5572/core/stats >/dev/null 2>&1 && echo "      yes" || echo "      no"' \
    _ "$(sed -n 's/^WEBUI_USERNAME=//p' .env)" "$(sed -n 's/^WEBUI_PASSWORD=//p' .env)" 2>/dev/null || true
fi
say "done"
