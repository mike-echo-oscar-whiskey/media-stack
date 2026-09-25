#!/usr/bin/env bash
# Fetch older spots than Spotweb currently holds.
#
#   ./scripts/spotweb-backfill.sh         re-scan from SPOTWEB_SINCE_YEAR in .env
#   ./scripts/spotweb-backfill.sh 2015    re-scan from a year given here instead
#   ./scripts/spotweb-backfill.sh -n      say what it would do, change nothing
#
# Why this is not just a settings change: retrieve_newer_than is a floor on what
# gets STORED, and Spotweb separately tracks how far it has READ. The reader
# only moves forward, and it re-derives its position from the newest spots
# already in the database (the last 5000 message ids), so lowering the floor -
# or rewinding usenetstate by hand - changes nothing at all.
#
# retrieve.php --retro is the mechanism that does work: it starts at the first
# article in the group and ignores the stored position entirely. So this lowers
# the floor and runs a retro pass. Spots already held are skipped, not
# duplicated.
#
# The whole group is walked either way - there is no "start at article N" - so
# the year only decides what is KEPT, never how much is read. Budget the same
# time whichever year you pick.
#
# How far back is worth going depends on the provider, not on Spotweb: a spot is
# only an index entry, and whether it still DOWNLOADS depends on article
# retention. That number is often much larger than people assume - Newshosting
# spools everything since 2008 and advertises 6600+ days, growing by a day each
# day - so check it before deciding a year is too old to bother with.
set -euo pipefail
cd "$(dirname "$0")/.."
[[ -f .env ]] && { set -a; source .env; set +a; }

# No year given: use the one configured in .env, so the depth lives in one place.
year=${1:-}
[[ "$year" == -n ]] && { dry=-n; year=; } || dry=${2:-}
year=${year:-${SPOTWEB_SINCE_YEAR:-}}
[[ "$year" =~ ^[0-9]{4}$ ]] || {
  echo "usage: $0 [year] [-n]   year defaults to SPOTWEB_SINCE_YEAR in .env" >&2; exit 2; }
(( year >= 2004 && year <= $(date +%Y) )) || { echo "year out of range (the group starts in 2004)" >&2; exit 2; }

docker compose ps --services --status running 2>/dev/null | grep -qx spotweb \
  || { echo "spotweb is not running" >&2; exit 1; }

sw() { docker compose exec -T -u abc spotweb php -r "$1" -- "${@:2}"; }

before=$(sw 'chdir("/app"); require "vendor/autoload.php";
  $b = new Bootstrap(); list($s, $d) = $b->boot();
  $r = $d->getConnection()->arrayQuery("SELECT COUNT(*) AS n, MIN(stamp) AS mn FROM spots", []);
  printf("%d|%s", $r[0]["n"], $r[0]["mn"] ? date("Y-m-d", (int) $r[0]["mn"]) : "-");')
echo "  now: ${before%|*} spots, oldest ${before#*|}"
echo "  floor -> $year-01-01, then a retro pass over the whole group"
if [[ "$dry" == -n ]]; then echo "(dry run, nothing changed)"; exit 0; fi

sw 'chdir("/app"); require "vendor/autoload.php";
  $b = new Bootstrap(); list($s) = $b->boot();
  $s->set("retrieve_newer_than", mktime(0, 0, 0, 1, 1, (int) $argv[1]));' "$year" >/dev/null
# The container retrieves on its own cron, and two retrievals must not overlap.
# Upstream's lock is known not to prevent it (#986, #992), and on SQLite the
# second writer simply takes the write lock: a pass that had already collected
# 2.1 million spots was rolled back that way. So the crontab is emptied for the
# duration and restored afterwards, whatever happens - including Ctrl-C.
cron=$(docker compose exec -T spotweb cat /etc/crontabs/root 2>/dev/null || true)
log=$(mktemp)
restore() {
  [[ -n "$cron" ]] && printf '%s\n' "$cron" \
    | docker compose exec -T spotweb sh -c 'cat > /etc/crontabs/root' 2>/dev/null || true
  rm -f "$log"
}
trap restore EXIT
docker compose exec -T spotweb sh -c ': > /etc/crontabs/root' 2>/dev/null || true
echo "  retrieving with the container's cron held off - allow twenty minutes or so"

docker compose exec -T -u abc spotweb php /app/retrieve.php --retro > "$log" 2>&1 || true

# retrieve.php prints "crashed" and still exits 0, so the output is the verdict.
if grep -q 'Finished retrieving spots' "$log" && ! grep -qE 'crashed|Fatal error|Uncaught' "$log"; then
  after=$(sw 'chdir("/app"); require "vendor/autoload.php";
    $b = new Bootstrap(); list($s, $d) = $b->boot();
    $c = $d->getConnection();
    $r = $c->arrayQuery("SELECT COUNT(*) AS n, MIN(stamp) AS mn FROM spots", []);
    printf("%d|%s", $r[0]["n"], date("Y-m-d", (int) $r[0]["mn"]));')
  if [[ "${after%|*}" == "${before%|*}" ]]; then
    printf 'NO CHANGE - still %s spots, oldest %s. The run finished but stored\n' "${after%|*}" "${after#*|}" >&2
    printf 'nothing, which usually means another retrieval held the write lock.\n' >&2
    exit 1
  fi
  printf 'OK - %s spots, oldest %s (was %s spots, oldest %s)\n' \
    "${after%|*}" "${after#*|}" "${before%|*}" "${before#*|}"
else
  echo "FAILED - retrieval did not finish cleanly:" >&2
  grep -iE 'crashed|Fatal error|Uncaught|error' "$log" | head -5 >&2
  exit 1
fi
