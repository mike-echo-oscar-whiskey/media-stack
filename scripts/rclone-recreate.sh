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

say "0. refuse if anything would be lost"
# The cache is in the container's writable layer, so a recreate empties it. With
# --vfs-cache-mode full a write is acknowledged as soon as it reaches the cache,
# so mover.sh sees success and deletes the local source while the upload is still
# queued. A file whose upload has not completed therefore exists in exactly one
# place: this cache. Recreating the container deletes it. That is the stake here -
# not a half-copied file.
#
# Two ways the mover can be running: its timer, or someone invoking it by hand
# with --now. The bracket keeps pgrep from matching its own command line - and
# note the plain name must not appear anywhere else in this command either, or
# the bracket is defeated and the test can never return false.
mover_running() {
  systemctl --user --machine="$OWNER@" is-active media-stack-mover.service >/dev/null 2>&1 && return 0
  # Exclude our own process tree: if this script is invoked from a command line
  # that happens to contain the pattern, pgrep matches the invoker and the test
  # can never return false. Walk up from $$ and ignore anything in that chain.
  local mine=() p=$$ hit
  while [[ -n "$p" && "$p" != 1 ]]; do mine+=("$p"); p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); done
  while read -r hit; do
    [[ -z "$hit" ]] && continue
    local skip=0 m
    for m in "${mine[@]}"; do [[ "$hit" == "$m" ]] && skip=1; done
    (( skip )) || return 0
  done < <(pgrep -f 'move[r]\.sh' 2>/dev/null)
  return 1
}
if mover_running; then
  echo "   the mover is RUNNING - it may be mid-copy. Wait for it and run this again."
  exit 1
fi

# runuser needs root. When this is a --dry-run as the owner, call docker directly
# instead, or the check silently fails and "cannot tell" reads as "nothing".
asowner() { if [[ $EUID -eq 0 ]]; then runuser -u "$OWNER" -- "$@"; else "$@"; fi; }

stats=$(asowner docker compose exec -T rclone sh -c \
          'rclone rc --rc-addr 127.0.0.1:5572 core/stats 2>/dev/null' </dev/null 2>/dev/null)
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$stats"; then
  echo "   REFUSING: could not read rclone's transfer state."
  echo "   An empty answer is not a negative one - this might mean nothing is pending,"
  echo "   or it might mean the rc is unreachable while nine files sit unuploaded."
  echo "   Fix the check before trusting it:"
  echo "     docker compose exec -T rclone rclone rc --rc-addr 127.0.0.1:5572 core/stats"
  exit 1
fi
pending=$(jq -r '(.transferring // [])[]? | .name' <<<"$stats" 2>/dev/null)
npend=$(printf '%s' "$pending" | grep -c . || true)

# core/stats only lists what is being transferred now. The cache can hold more
# that is merely queued, so enumerate the cache itself as well.
cached=$(asowner docker compose exec -T rclone sh -c \
           'find /root/.cache/rclone/vfs -type f 2>/dev/null' </dev/null 2>/dev/null \
         | sed 's|^/root/.cache/rclone/vfs/media/||')
ncache=$(printf '%s' "$cached" | grep -c . || true)
echo "   rclone cache holds $ncache file(s); $npend transferring"
pending=$(printf '%s\n%s' "$pending" "$cached" | grep -v '^$' | sort -u)
npend=$(printf '%s' "$pending" | grep -c . || true)

if (( npend == 0 )); then
  echo "   nothing in the cache - safe to proceed"
else
  speed=$(jq -r '((.speed // 0) / 125000) | floor' <<<"$stats" 2>/dev/null)
  err=$(jq -r '(.lastError // "none")' <<<"$stats" 2>/dev/null)
  echo "   $npend file(s) pending upload, current speed ${speed:-0} Mbit/s"
  echo "   last error: ${err:0:100}"
  echo
  echo "   checking whether any of them exists ONLY in the cache:"
  atrisk=0
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    base=${rel##*/}; dir=${rel%/*}
    on_drive=$(asowner docker compose exec -T rclone sh -c \
                 "rclone lsf --no-traverse \"media:$dir\" 2>/dev/null" </dev/null 2>/dev/null \
               | grep -cF -- "$base" || true)
    local_copy=no
    [[ -f "$ROOT/data/local/media/$rel" ]] && local_copy=yes
    if [[ "${on_drive:-0}" == 0 && "$local_copy" == no ]]; then
      echo "     CACHE-ONLY  $base"
      atrisk=$(( atrisk + 1 ))
    else
      echo "     safe (drive=${on_drive:-0} local=$local_copy)  $base"
    fi
  done <<<"$pending"

  if (( atrisk > 0 )); then
    echo
    echo "   REFUSING: $atrisk file(s) exist only in the cache this recreate would delete."
    echo "   They are not on Drive and not on the local branch."
    echo
    if [[ "$err" == *rateLimit* || "$err" == *403* || "$err" == *quota* ]]; then
      echo "   The uploads are blocked by the provider, not merely slow:"
      echo "     $err"
      echo "   Waiting will not clear it until the daily allowance resets."
    fi
    echo "   Copy them somewhere outside data/local and data/archive first, or wait"
    echo "   until the log shows a Copied line for each, then run this again."
    echo "   Override only if you accept losing them:  FORCE_LOSE_CACHE=1 $0"
    [[ "${FORCE_LOSE_CACHE:-0}" == 1 ]] || exit 1
    echo "   FORCE_LOSE_CACHE=1 set - continuing, those files will be lost."
  fi
fi

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
  # Homepage ships BusyBox wget, which has no --user/--password - and a password
  # in argv is readable by anyone running ps. Pass it in the environment and build
  # the header inside the container.
  asowner docker compose exec -T \
    -e RCU="$(sed -n 's/^WEBUI_USERNAME=//p' .env)" \
    -e RCP="$(sed -n 's/^WEBUI_PASSWORD=//p' .env)" \
    homepage sh -c '
      AUTH=$(printf "%s:%s" "$RCU" "$RCP" | base64 -w0)
      if wget -qO- --timeout=8 --post-data="" --header="Authorization: Basic $AUTH" \
           http://rclone:5572/core/stats >/dev/null 2>&1; then echo "      yes"
      else echo "      no - the Archive tile will still show an error"; fi' </dev/null 2>/dev/null || true
fi
say "done"
