#!/usr/bin/env bash
# Where the disk went, and which of it is real.
#
#   ./scripts/audit-space.sh
#
# Because imports are hardlinks, a file can appear under both data/torrents and
# data/media while occupying one set of blocks. Summing the two trees therefore
# overcounts, and deleting the library copy of a still-seeding torrent frees
# nothing. This separates the three cases that matter:
#
#   shared    two names, one set of blocks - costs nothing, leave it alone
#   orphaned  one name under a download tree, no library copy - real space that
#             nothing owns any more, which is what heal.sh reclaims
#   live      a torrent the client still holds, whatever its link count
#
# Written after an investigation that found 57 GB of orphans by hand: 31 GB of
# it one remux that an upgrade replaced hours after it imported, its library
# name deleted while the torrent kept its own.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && { set -a; source .env; set +a; }
root=${DATA_ROOT:-./data}
gib() { awk -v b="${1:-0}" 'BEGIN {printf "%.2f GiB", b/1073741824}'; }

echo "== filesystem"
if [[ "$(df --output=target "$root/media" "$root/torrents" 2>/dev/null | tail -n +2 | sort -u | wc -l)" -gt 1 ]]; then
  echo "   WARNING media and torrents are on different filesystems - hardlinks cannot work"
else
  df -h --output=target,size,avail,pcent "$root" | tail -n +2 | sed 's/^/  /'
fi

echo
echo "== space, deduplicated"
printf '   %-26s %s\n' "$root (unique)" "$(du -sh "$root" 2>/dev/null | cut -f1)"
for d in media torrents usenet; do
  [[ -d "$root/$d" ]] && printf '   %-26s %s\n' "$root/$d" "$(du -sh "$root/$d" 2>/dev/null | cut -f1)"
done
echo "   (the parts sum to more than the unique total by however much is hardlinked)"

echo
echo "== data/torrents, folder by folder"
shared_total=0; orphan_total=0
for d in "$root"/torrents/*/; do
  [[ -d "$d" ]] || continue
  name=$(basename "$d"); [[ "$name" == incomplete ]] && continue
  sh=$(find "$d" -type f -links +1 -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
  or=$(find "$d" -type f -links 1  -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
  (( sh + or == 0 )) && continue
  shared_total=$(( shared_total + sh )); orphan_total=$(( orphan_total + or ))
  printf '   %-44s shared %-11s orphaned %s\n' "${name:0:44}" "$(gib "$sh")" "$(gib "$or")"
done
loose=$(find "$root/torrents" -maxdepth 1 -type f -links 1 -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
(( loose > 0 )) && { printf '   %-44s shared %-11s orphaned %s\n' "(loose files at the root)" "$(gib 0)" "$(gib "$loose")"; orphan_total=$(( orphan_total + loose )); }

echo
echo "== usenet leftovers (nothing imports the prowlarr category by design)"
if [[ -d "$root/usenet/complete" ]]; then
  du -sh "$root"/usenet/complete/* 2>/dev/null | sed 's/^/   /' || echo "   empty"
fi

echo
echo "== what the client still holds"
if docker compose ps --services --status running 2>/dev/null | grep -qx qbittorrent; then
  info=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8081/api/v2/torrents/info 2>/dev/null || echo '[]')
  if [[ "$(jq length <<<"$info")" -eq 0 ]]; then
    echo "   no torrents - so every folder above is abandoned"
  else
    jq -r '.[] | "   \(.state | .[0:11] | . + (" " * (11-length)))  ratio \(.ratio*100|floor/100)  \((.size/1073741824*100|floor)/100) GiB  \(.name[0:44])"' <<<"$info"
  fi
else
  echo "   qBittorrent is not running"
fi

echo
echo "== summary"
printf '   shared with the library (costs nothing) %s\n' "$(gib "$shared_total")"
printf '   orphaned under data/torrents            %s\n' "$(gib "$orphan_total")"
keep=${HEAL_ORPHAN_KEEP:-prowlarr,music}; hours=${HEAL_ORPHAN_HOURS:-24}
ready=$(find "$root/torrents" -type f -links 1 -mmin "+$(( hours * 60 ))" -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')
printf '   of that, older than %sh and sweepable    %s\n' "$hours" "$(gib "$ready")"
echo "   heal.sh reclaims those on its next pass, skipping: $keep"
