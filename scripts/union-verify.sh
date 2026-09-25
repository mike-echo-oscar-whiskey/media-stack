#!/usr/bin/env bash
# Is the union library actually working? Checks the things that would be silently
# wrong rather than loudly broken.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
set -a; . ./.env; set +a
CONFIG_ROOT=${CONFIG_ROOT:-./config}
D=${DATA_ROOT}
ok=0; bad=0
chk() { if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; ok=$((ok+1)); else printf '  FAIL %s\n' "$1"; bad=$((bad+1)); fi; }

chk "the union is mounted"                      "mountpoint -q '$D/union'"
chk "the cloud branch is mounted"               "mountpoint -q '$D/archive/media'"
chk "local branch holds the libraries"          "[ -d '$D/local/media/tv' ]"
chk "union shows tv"                            "[ -d '$D/union/media/tv' ]"
for c in sonarr radarr lidarr; do
  chk "$c sees /data/media as the union"        "docker compose exec -T $c sh -c 'stat -f -c %T /data/media | grep -q fuse'"
  chk "$c has no /data/archive"                 "! docker compose exec -T $c test -d /data/archive"
done
# The one that matters most: an import must still be able to hardlink from the
# download folder into the library, or every import silently becomes a copy.
chk "hardlink works across the union" "docker compose exec -T sonarr sh -c '
  set -e; d=/data/usenet/incomplete/.linktest; m=/data/media/tv/.linktest
  mkdir -p \$(dirname \$d) \$(dirname \$m); : > \$d
  ln \$d \$m && [ \"\$(stat -c %h \$m)\" -ge 2 ]; rm -f \$d \$m'"
printf '\n  %d ok, %d failed\n' "$ok" "$bad"
(( bad == 0 ))
