---
name: env-settings
description: Change a setting in .env correctly — knowing which keys need configure.sh, which need a container recreate, and which take effect on their own. Use when adjusting caps, limits, guards, timers or adding a new key.
---

# Changing a setting

## Three kinds of key, and they behave differently

**Read by `configure.sh` and pushed into an app** — speed caps, seeding limits, categories, UI
dates, quality choice, dubbed language, Homepage settings. Edit `.env`, then run `./configure.sh`.
Nothing happens until you do.

**Read by a container at start** — anything listed in `compose.yml`'s `environment:`, which is where
`GUARD_MIN_RATIO` and `GUARD_MAX_RATIO` live: the release guard reads them from its own process
environment. Editing `.env` is not enough and neither is `configure.sh` — the container has to be
recreated:

```bash
docker compose up -d sonarr radarr
docker compose exec -T radarr sh -c 'echo "$GUARD_MIN_RATIO $GUARD_MAX_RATIO"'   # verify
```

**Read at run time by the host scripts** — `HEAL_*`, `TORRENT_PRIVATE_SEED_HOURS`,
`NEWS_FEEDS`, `MISSING_SEARCH_TIME`. `heal.sh` and friends source `.env` on every run, so the next
pass picks the change up with nothing else to do. Timer *intervals* are the exception: they are
baked into the unit file, so `./heal.sh install` again after changing `HEAL_INTERVAL`.

If you are unsure which kind a key is, grep for it — `grep -rn KEY lib/ *.sh compose.yml` — rather
than guessing.

## Two traps in the file itself

**No spaces in values.** `configure.sh` parses `.env` with python precisely because bash would
misread it, but `heal.sh`, `update.sh`, `news.sh`, `missing.sh` and `migrate.sh` all use
`set -a; source .env`. A value like `HEAL_ORPHAN_KEEP=prowlarr music` makes bash try to run
`music`, and the script dies with `command not found`. Use a comma-separated list, as that key does.

**Rates are in KiB/s, deliberately.** `USENET_MAX_KIB`, `TORRENT_MAX_KIB`,
`TORRENT_UPLOAD_MAX_KIB`. KiB is what both clients store, so the number is applied exactly, where a
Mbit value gets rounded down to the nearest KiB. To convert a line speed: `KiB = Mbit × 125000 /
1024`, near enough `Mbit × 122`. Read a cap back in **bytes per second** to check it; dividing by
1024² and calling the result Mbit is how a correct 100 Mbit cap once got reported as 95.

## Adding a *new* key is three things, not one

Per the repo's conventions in `AGENTS.md`:

1. the code that reads it, with validation — `[[ "$x" =~ ^[0-9]+$ ]] || die "KEY must be …"`
2. a documented entry in `.env.example`, since `setup.sh` takes its defaults from that file, so an
   undocumented key means fresh installs silently lack it
3. a mention in the README, which is checkable:

```bash
for k in $(grep -oE '^[A-Z_]+=' .env.example | tr -d '='); do
  grep -q "$k" README.md || echo "undocumented: $k"
done
```

Also update the live `.env` — `setup.sh` only ever writes a new one — and `migrate.sh`'s
`CARRY_KEYS` if the setting should follow the stack to another host.

## Prove the change rather than assuming it

Read the value back from the thing that consumes it, not from `.env`:

- qBittorrent: `/api/v2/app/preferences` → `up_limit`, `dl_limit`, `max_ratio`, `max_seeding_time`
- SABnzbd: `mode=get_config` for the stored string, `mode=queue` for `speedlimit_abs` in B/s
- the guard: `docker compose exec radarr sh -c 'echo $GUARD_MIN_RATIO'`
- the arr apps: the relevant `/api/v3/config/...` endpoint

Then run `./configure.sh` a second time: every step must report `kept` and exit 0. A step that says
`ok` twice for the same input is not idempotent and wants fixing.
