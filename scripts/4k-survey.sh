#!/usr/bin/env bash
# Rank the migration set by how easily each film can actually be fetched, rather
# than by how popular it is. Writes backups/4k-order.tsv for 4k-migrate.sh.
#
# A usenet release outranks any torrent: it needs no peers, it cannot stall at
# 94%, and SABnzbd has the faster cap here (500 Mbit/s against 200). Among
# torrents the best available seeder count decides. A film with no 4K release at
# all scores -1 and is skipped, so the run never waits on something that is not
# there.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
[[ -f .env ]] && { set -a; . ./.env; set +a; }

RK=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/radarr/config.xml)
PK=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/prowlarr/config.xml)
[[ -n "$RK" && -n "$PK" ]] || { echo "missing an API key"; exit 1; }
PROFILE=${MIGRATE_PROFILE_ID:-17}
OUT=backups/4k-order.tsv
GAP=${SURVEY_GAP_SECONDS:-6}
# 1337x excluded: it is 70-80% of the latency and adds almost nothing.
ARGS=(); for i in ${SURVEY_INDEXERS:-13 2 14 11 6}; do ARGS+=(--data-urlencode "indexerIds=$i"); done

log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }

movies=$(curl -fsS -m 60 -H "X-Api-Key: $RK" http://127.0.0.1:7878/api/v3/movie)
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$movies" || { echo "could not read Radarr"; exit 1; }

mapfile -t rows < <(jq -r --argjson p "$PROFILE" '
  [.[] | select(.qualityProfileId == $p and .hasFile
                and ((.movieFile.quality.quality.resolution // 0) < 2160))]
  | .[] | [(.id|tostring), .title, (.year|tostring)] | @tsv' <<<"$movies")

log "surveying ${#rows[@]} films"
tmp=$OUT.tmp; : > "$tmp"
done_n=0
for row in "${rows[@]}"; do
  IFS=$'\t' read -r id title year <<<"$row"
  r=$(curl -fsS -m 120 -G -H "X-Api-Key: $PK" http://127.0.0.1:9696/api/v1/search \
       --data-urlencode "query=$title $year" --data-urlencode 'categories=2000' \
       --data-urlencode 'type=search' "${ARGS[@]}" 2>/dev/null)
  if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$r"; then
    read -r score proto seeds nus < <(jq -r '
      [.[] | select(.title | test("2160p|\\b4K\\b"; "i"))] as $u
      | [$u[] | select(.protocol == "usenet")] as $un
      | [$u[] | select(.protocol != "usenet") | (.seeders // 0)] as $se
      | if ($u|length) == 0 then "-1 none 0 0"
        elif ($un|length) > 0 then "\(1000000 + ($un|length)) usenet \(($se|max) // 0) \($un|length)"
        else "\(($se|max) // 0) torrent \(($se|max) // 0) 0" end' <<<"$r")
  else
    score=-1 proto=err seeds=0 nus=0
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$score" "$id" "$title" "$proto" "$seeds" "$nus" >> "$tmp"
  done_n=$(( done_n + 1 ))
  (( done_n % 10 == 0 )) && log "surveyed $done_n of ${#rows[@]}"
  sleep "$GAP"
done
sort -t$'\t' -k1,1nr "$tmp" > "$OUT" && rm -f "$tmp"
log "wrote $OUT"
awk -F'\t' '$1 >= 1000000 {u++} $1 >= 0 && $1 < 1000000 {t++} $1 < 0 {n++}
END {printf "usenet-reachable=%d torrent-only=%d no-4K=%d\n", u+0, t+0, n+0}' "$OUT"
