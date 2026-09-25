---
name: add-content
description: Add a film or series to this stack the way it is meant to be added — through Seerr, with the right id, and only when asked. Use when someone wants something downloaded, a request fails, or a title is missing from the library.
---

# Adding content

## The rule that comes before any of this

**Never write to the library without an explicit instruction naming the action.** A question
("why can't I request this?"), a statement of what someone was looking for, or a declined
clarifying question are not approval. Investigate freely — every read below is safe — but adding
a film or series, monitoring a season or firing a search waits for a clear yes.

This is here because a series was once added to Sonarr on inference, monitored, searched, and had
to be removed again.

## Prefer Seerr

Requesting in Seerr is the right path even when the API would be quicker:

- the request records who asked, and Seerr marks it available when the file lands
- Seerr picks the profile and root folder the stack configured, including the dubbed twins
- nothing needs to be undone later if the title turns out to be unavailable

Adding straight to Radarr or Sonarr is the exception, and it leaves Seerr showing the title as
unavailable forever, because Seerr tracks its own media rows. Say so when you do it.

## Ids: the thing that actually goes wrong

Radarr is **TMDB**-keyed. Sonarr is **TVDB**-keyed. Seerr's catalogue is TMDB and it resolves the
TVDB id from TMDB's `external_ids` when handing a series to Sonarr.

So a series whose TMDB entry carries no TVDB id **cannot be requested in Seerr at all** — the UI
blocks it and nothing reaches the server log. Check with:

```bash
SK=$(jq -r '.main.apiKey' config/seerr/settings.json)
curl -fsS -H "X-Api-Key: $SK" http://localhost:5055/api/v1/tv/<tmdbId> |
  jq -r '{name, tvdb: .externalIds.tvdbId, seasons: [.seasons[]|select(.seasonNumber>0)]|length}'
```

Sonarr can often resolve the same id itself, because its metadata service knows mappings TMDB does
not publish:

```bash
K=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/sonarr/config.xml)
curl -fsS -G -H "X-Api-Key: $K" http://localhost:8989/api/v3/series/lookup \
  --data-urlencode "term=tmdb:<tmdbId>" | jq -r '.[0] | {title, tvdbId, tmdbId}'
```

**Anthologies are the trap.** TMDB gives each installment its own one-season series; TVDB files
them as seasons of one show. *Monster: The Lizzie Borden Story* is TMDB 299939 with 1 season, and
TVDB's *Monster* (389492) season 4. There is no automatic translation: requesting "season 1" of the
TMDB entry would fetch season 1 of the TVDB show — Dahmer, not Lizzie Borden. When ids and season
counts disagree like this, explain it and let the human choose; do not pick a season for them.

An ambiguous number is also worth checking both ways: 299939 is that series *and* the 2014 film
*Debug*. Ask which they meant rather than guessing from context.

## When adding directly is the agreed route

Use the stack's own defaults rather than inventing any:

```bash
K=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/radarr/config.xml)
prof=$(curl -fsS -H "X-Api-Key: $K" http://localhost:7878/api/v3/qualityprofile |
       jq -r 'first(.[] | select(.name == "HD Bluray + WEB")) | .id')
# root folder /data/media/movies, monitored true, minimumAvailability released
```

For a series, add with `addOptions.monitor: "none"` first, read the episodes to confirm which
season is the one wanted (air dates settle it), then monitor that season and search it. Adding with
everything monitored fetches the whole anthology.

## Expect nothing to happen when nothing should

A film still in cinemas (`isAvailable=false`, no digital date) will not grab, and that is correct —
the release guard exists because a search for an unreleased title returns fakes. Report "searched,
found nothing, because it is not out until X" rather than treating it as a failure.

## Afterwards

- `./scripts/probe-parser.sh` if a release was refused and the reason is unclear
- the request in Seerr completes on its own when the file imports; its availability sync repairs the
  link even if the Radarr id changed
