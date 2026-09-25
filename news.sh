#!/usr/bin/env bash
# Headlines for the dashboard, from RSS or Atom feeds:
#
#   ./news.sh              fetch every feed in NEWS_FEEDS, one JSON file each
#   ./news.sh install      systemd user timer, every 15 minutes
#   ./news.sh status       last result, next run
#
# NEWS_FEEDS in .env holds "Title|URL" pairs separated by semicolons; each
# becomes config/homepage/news/<slug>.json (slug = title lower-cased, spaces
# to dashes). Several URLs after one title, separated by spaces, are merged
# into that tile: the newest item of each source in turn, so a busy feed
# cannot crowd out a quiet one, and repeated titles are dropped.
# Why: Homepage has no feed widget; its custom-API widget lists
# items from a JSON document. The container serves this directory as static
# files (compose.yml mounts it under /app/public/news), so the dashboard
# reads the headlines from itself and nothing on the internet gets a copy of
# the request. Python's standard library does the fetching and parsing.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$(pwd)
UNIT=media-stack-news
DIR=config/homepage/news

slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '-' | sed 's/-\{2,\}/-/g; s/^-//; s/-$//'; }

fetch_one() {                     # fetch_one TITLE "URL [URL...]" -> news/<slug>.json
  NEWS_TITLE=$1 NEWS_URLS=$2 OUT="$DIR/$(slug "$1").json" python3 - <<'PY'
import json, os, tempfile, urllib.request, xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime
from datetime import datetime, timezone
from urllib.parse import urlsplit

title, urls, out = os.environ["NEWS_TITLE"], os.environ["NEWS_URLS"].split(), os.environ["OUT"]

def text(el, *names):
    for n in names:
        found = el.find(n)
        if found is not None and (found.text or found.get("href")):
            return (found.text or found.get("href")).strip()
    return ""

def when(s):
    if not s:
        return None
    try:
        return parsedate_to_datetime(s)
    except (TypeError, ValueError):
        pass
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (compatible; media-stack news.sh)"})
    with urllib.request.urlopen(req, timeout=20) as r:
        root = ET.fromstring(r.read())
    source = urlsplit(url).hostname.removeprefix("www.")
    items = []
    for it in root.iter("item"):                                   # RSS
        items.append((text(it, "title"), text(it, "link"), when(text(it, "pubDate")), source))
    a = "{http://www.w3.org/2005/Atom}"
    for it in root.iter(a + "entry"):                              # Atom
        items.append((text(it, a + "title"), text(it, a + "link"), when(text(it, a + "updated", a + "published")), source))
    items = [i for i in items if i[0]]
    items.sort(key=lambda i: i[2] or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    return items

failed = []
sources = []
for u in urls:
    try:
        sources.append(fetch(u))
    except Exception as e:                          # one dead feed must not empty the tile
        failed.append(f"{u}: {type(e).__name__}")

merged, seen = [], set()
while any(sources) and len(merged) < 20:            # round robin over the sources
    for s in sources:
        while s:
            t, l, d, src = s.pop(0)
            key = t.casefold()
            if key in seen:
                continue
            seen.add(key)
            merged.append((t, l, d, src))
            break

doc = {
    "feed": title,
    "fetched": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    "items": [{"title": t, "link": l, "source": src,
               "published": (d.astimezone(timezone.utc).isoformat(timespec="seconds") if d else None)}
              for t, l, d, src in merged],
}
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out), prefix=".news-", suffix=".json")
with os.fdopen(fd, "w") as f:
    json.dump(doc, f, ensure_ascii=False)
os.chmod(tmp, 0o644)
os.replace(tmp, out)
print(f"{title}: {len(doc['items'])} headlines from {len(sources)} source(s) -> {out}" + (f"  (failed: {', '.join(failed)})" if failed else ""))
if not sources:
    raise SystemExit(1)
PY
}

fetch() {
  set -a; source .env; set +a
  [[ -n "${NEWS_FEEDS:-}" ]] || { echo "NEWS_FEEDS is empty in .env - nothing to fetch"; return 0; }
  mkdir -p "$DIR" || { echo "cannot create $DIR (owned by root? create it yourself: mkdir -p $DIR)" >&2; return 1; }
  local entry title url rc=0
  IFS=';' read -ra entries <<<"$NEWS_FEEDS"
  for entry in "${entries[@]}"; do
    title=${entry%%|*}; url=${entry#*|}
    [[ -n "$title" && "$url" == http* ]] || { echo "skipping malformed entry: $entry" >&2; rc=1; continue; }
    fetch_one "$title" "$url" || rc=1
  done
  return $rc
}

install_timer() {
  local dir=~/.config/systemd/user span
  [[ -f .env ]] && { set -a; source .env; set +a; }
  span=${NEWS_INTERVAL:-15min}
  [[ "$span" =~ ^[0-9]+(s|sec|m|min|h|hour)$ ]] || { echo "NEWS_INTERVAL must be a systemd time span such as 15min (got \"$span\")" >&2; exit 1; }
  mkdir -p "$dir"
  cat > "$dir/$UNIT.service" <<UNIT
[Unit]
Description=media-stack: fetch dashboard headlines
After=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$HERE
ExecStart=$HERE/news.sh
UNIT
  cat > "$dir/$UNIT.timer" <<UNIT
[Unit]
Description=media-stack dashboard headlines (every $span)

[Timer]
OnBootSec=2min
OnUnitActiveSec=$span

[Install]
WantedBy=timers.target
UNIT
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer" >/dev/null
  echo "timer enabled:"; systemctl --user list-timers "$UNIT.timer" --no-pager | head -2
  if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) != yes ]]; then
    echo "NOTE: run once as root so the timer also fires when you are not logged in:"
    echo "      sudo loginctl enable-linger $USER"
  fi
}

show_status() {
  local f
  if ls "$DIR"/*.json >/dev/null 2>&1; then
    for f in "$DIR"/*.json; do echo "$(jq -r '.feed' "$f"): $(jq -r '.items | length' "$f") headlines, fetched $(jq -r '.fetched' "$f")"; done
  else
    echo "never fetched (no files in $DIR)"
  fi
  systemctl --user list-timers "$UNIT.timer" --no-pager 2>/dev/null | head -2 || echo "timer not installed (./news.sh install)"
}

case "${1:-}" in
  "")       fetch ;;
  install)  install_timer ;;
  status)   show_status ;;
  *) echo "usage: $0 [install|status]" >&2; exit 2 ;;
esac
