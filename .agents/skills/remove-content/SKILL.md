---
name: remove-content
description: Remove a film or series from the stack completely — library, files, requests, dashboards — and know why the disk space may not come back yet. Use when someone wants something deleted, or asks whether a title is really gone.
---

# Removing content

## Do what was asked and nothing more

Remove the title. Do **not** also add a list exclusion, blocklist the release, or unmonitor
anything unless that was asked for: an exclusion is a standing rule that quietly prevents the title
being added again, and "remove this" is not a request for one. This is written down because it
happened.

## Seerr does most of it in two clicks

Seerr's **Manage** panel on the title's page (admin only):

- **Remove from Radarr / Sonarr** — *"irreversibly remove this from {arr}, including all files"*
- **Clear Media Data** — drops Seerr's own record and the request with it

That covers the library entry, the file, and the bookkeeping. It does not touch the download client
or Plex's trash, and it deliberately adds no exclusion, so the title can be requested again.

Doing it through the API instead:

```bash
K=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/radarr/config.xml)
curl -fsS -X DELETE -H "X-Api-Key: $K" \
  "http://localhost:7878/api/v3/movie/<id>?deleteFiles=true&addImportListExclusion=false"
```

Sonarr is the same shape with `/series/<id>`. Keep `addImportListExclusion=false` unless told
otherwise.

## The space may not come back, and that is not a bug

Imports are **hardlinks**: the download and the library file are two names for one set of blocks.
Deleting the library name frees nothing while the torrent still holds its own. Check before
promising anything:

```bash
stat -c '%h links' "data/media/movies/<folder>/<file>"    # 2 = the torrent has it too
./scripts/audit-space.sh                                   # the whole picture
```

What happens next, without intervention: the torrent seeds to its limit (ratio 1 or 24 hours on
public trackers, `TORRENT_PRIVATE_SEED_HOURS` on private ones), qBittorrent stops it, and
`heal.sh` removes it with its data on the next two-minute pass. So the space returns within a day —
or within three days for a private tracker. Deleting the torrent by hand in qBittorrent **with its
files** is the only way to have it sooner, and it means abandoning that seed.

## Plex keeps the watch history, always

Nothing needs doing to preserve it, and nothing about deletion threatens it. Plex stores watch
state in `metadata_item_settings` keyed by GUID — not by file, not by library id — and history
separately in `metadata_item_views` with the title inline. Orphaned rows for deleted media survive
indefinitely, and re-downloading the same title reattaches its watched state and rating.

Only an explicit *Reset watch state* or marking unwatched loses it.

The library entry itself goes stale within seconds (the file watcher is on) and disappears from the
UI after *Manage → Libraries → Empty Trash*, since `autoEmptyTrash` is unset here.

## Confirming it is really gone

Check every place, not just the app you deleted from — a title can come back under a new id if
something else re-added it:

```bash
# the arr apps
for a in radarr:7878:v3 sonarr:8989:v3 lidarr:8686:v1; do
  IFS=: read -r n p v <<<"$a"; key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/$n/config.xml)
  curl -fsS -H "X-Api-Key: $key" "http://localhost:$p/api/$v/$( [[ $n == sonarr ]] && echo series || echo movie )" |
    jq -r --arg t "<title>" '[.[]|select(.title|test($t;"i"))]|length as $n|"'"$n"': \($n)"'
done
# Seerr requests and media rows, Plex sections, Jellyfin items, both download
# clients, and the filesystem — see the fresh-install-test skill for the loop shapes
```

Also worth checking: **import-list exclusions** (something may have added one earlier) and the
**Plex watchlist**, because Seerr can auto-request from it — though per-user
`watchlistSyncMovies/Tv` is off on this install.
