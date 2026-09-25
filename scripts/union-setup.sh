#!/usr/bin/env bash
# Host preparation for the union library. See README "The archive tier".
#
# mergerfs is not in the Arch repositories, so it comes from the AUR - but that
# is an ordinary user command that escalates on its own, so it is NOT done here:
# running makepkg from a root context means working around its refusal to build
# as root, and it bypasses yay, which is this machine's AUR tool. Install it
# first, then run this for the two things only root can do:
#
#   1. user_allow_other in /etc/fuse.conf, without which a union mounted by your
#      user is invisible to the container processes that must read it;
#   2. a systemd unit that mounts the union before docker starts, so a container
#      can never come up against an empty library.
#
# Idempotent: each step checks first. Nothing here touches media files.
set -euo pipefail

say() { printf '  %s\n' "$*"; }

if ! command -v mergerfs >/dev/null; then
  cat <<'NEED'
  mergerfs is not installed. Install it as yourself first (yay escalates on its own):

      yay -S mergerfs          # 48 votes, builds from upstream source
      yay -S mergerfs-bin      # 1 vote, prebuilt - faster, far less used

  The source package is the one to prefer: it sits in the read path of the whole
  library, so the better-maintained of the two is worth two minutes of compiling.
  Then run this script again with sudo.
NEED
  exit 1
fi

(( EUID == 0 )) || { echo "  mergerfs is present; now run this with sudo for fuse.conf and the mount unit" >&2; exit 1; }
OWNER=${SUDO_USER:-}
[[ -n "$OWNER" ]] || { echo "run this through sudo, not as root directly" >&2; exit 1; }
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UID_N=$(id -u "$OWNER"); GID_N=$(id -g "$OWNER")
say "mergerfs $(mergerfs -V 2>&1 | head -1 | tr -d '\n')"

# ---------------------------------------------------------------- 1. fuse.conf
if grep -qs '^user_allow_other' /etc/fuse.conf; then
  say "/etc/fuse.conf already has user_allow_other"
else
  printf 'user_allow_other\n' >> /etc/fuse.conf
  say "added user_allow_other to /etc/fuse.conf"
fi

# ---------------------------------------------------------------- 2. the mount
# allow_other          the container processes are not $OWNER
# use_ino              one inode per file across branches, so the hardlink
#                      counts the mover relies on (-links +1) stay truthful
# category.create=ff   a new file lands on the first branch holding the
#                      directory - the local one - so an import stays on the
#                      disk and can still be hardlinked from the download folder
# moveonenospc         a write that runs out of room locally retries elsewhere
# dropcacheonclose     FUSE page cache is not shared between branches
UNIT=/etc/systemd/system/media-stack-union.service
# The unit path is fixed but ROOT is baked into it, so a second clone on the same
# host would silently repoint the first one's union at itself - and the first
# stack would come back after a reboot with its library in someone else's
# directory. Refuse instead; two installs cannot share a host anyway, because
# compose.yml pins the project name.
if [[ -f $UNIT ]] && ! grep -qF "$ROOT/data/union" "$UNIT"; then
  existing=$(sed -n 's|.*mergerfs .* \([^ ]*\)/data/union$|\1|p' "$UNIT" | head -1)
  echo "  $UNIT already exists and points at ${existing:-another directory}, not $ROOT." >&2
  echo "  Overwriting it would move that install's library out from under it." >&2
  echo "  Remove the unit by hand if you really mean to move the stack here." >&2
  exit 1
fi
cat > "$UNIT" <<UNITEOF
[Unit]
Description=media-stack union library (mergerfs over the local disk and the cloud archive)
After=local-fs.target
Before=docker.service
RequiresMountsFor=$ROOT/data

[Service]
Type=forking
User=$OWNER
ExecStartPre=/usr/bin/mkdir -p $ROOT/data/union $ROOT/data/local $ROOT/data/archive
ExecStart=/usr/bin/mergerfs -o allow_other,use_ino,category.create=ff,moveonenospc=true,dropcacheonclose=true,uid=$UID_N,gid=$GID_N,umask=002 $ROOT/data/local:$ROOT/data/archive $ROOT/data/union
ExecStop=/usr/bin/fusermount -u $ROOT/data/union
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNITEOF
say "wrote $UNIT"
systemctl daemon-reload
systemctl enable media-stack-union.service >/dev/null

# On a fresh install setup.sh has already written the union layout and there is
# nothing to move, so the mount can simply start. On a host still carrying the
# old flat layout it must not: mounting now would overlay an empty local branch
# on the archive and hand every app a half library. data/media existing beside
# data/local is what tells the two apart.
if [[ -d $ROOT/data/media && ! -d $ROOT/data/local ]]; then
  say "enabled media-stack-union.service - NOT started: this host still has the old"
  say "flat layout, so run scripts/union-migrate.sh to move it first"
else
  systemctl start media-stack-union.service
  if mountpoint -q "$ROOT/data/union"; then
    say "media-stack-union.service started; $ROOT/data/union is mounted"
  else
    echo "   the unit did not mount - check: systemctl status media-stack-union" >&2
    exit 1
  fi
fi

cat <<'NEXT'

  Host preparation done. Nothing has moved. If this was a fresh install the union
  is mounted and you can carry on with: docker compose up -d && ./configure.sh
NEXT
