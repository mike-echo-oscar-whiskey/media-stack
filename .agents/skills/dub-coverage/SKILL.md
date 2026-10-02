---
name: dub-coverage
description: Measure how much of the library actually carries the dubbed audio track, per app and per genre, and say whether the preference is earning its keep. Use after changing DUB_LANGUAGE, DUB_REPLACE_EXISTING or the MULTi score, or when deciding whether the dub scoring is worth the re-downloads.
---

# Is the dub preference actually working?

The scoring can only reach releases whose **title** names the language, plus `MULTi`, which
says there are several tracks without saying which. So the question "are we getting the dub"
cannot be answered from the configuration - only by looking at the files that arrived.

Answer it from the files, never from the profile. A profile that scores Dutch at +500 proves
only that Dutch *would* win if offered.

## Where the truth is

Jellyfin probes every file on import and keeps the full stream list, including each audio
track's language. That is the authority, and it costs one API call and no media reads - which
matters, because most of this library lives on the archive branch and probing it directly
would pull it back off the cloud.

The arr apps also record `audioLanguages` in their own `mediaInfo`, which is a usable
cross-check, but they store a reduced set - no track titles, no dispositions - so Jellyfin is
the better source. See AGENTS.md on what the arr apps' mediaInfo does and does not keep.

## The measurement

```bash
cd ~/Projects/media-stack
LANG_CODE=$(sed -n 's/^DUB_LANGUAGE=//p' .env)          # nl
# Jellyfin uses ISO 639-2; nl is nld, and some files are tagged dut
KEY=$(curl -fsS -X POST -H 'Content-Type: application/json' \
  -H 'Authorization: MediaBrowser Client="x", Device="x", DeviceId="dub-coverage", Version="1"' \
  -d "{\"Username\":\"$(sed -n 's/^WEBUI_USERNAME=//p' .env)\",\"Pw\":\"$(sed -n 's/^WEBUI_PASSWORD=//p' .env)\"}" \
  http://127.0.0.1:8096/Users/AuthenticateByName | jq -r .AccessToken)

curl -fsS -H "Authorization: MediaBrowser Token=\"$KEY\"" \
  'http://127.0.0.1:8096/Items?Recursive=true&IncludeItemTypes=Movie&Fields=MediaStreams,Genres&Limit=5000' \
| jq -r '
  def dubbed: [.MediaStreams[]? | select(.Type=="Audio" and (.Language=="nld" or .Language=="dut"))] | length > 0;
  [.Items[]] as $all
  | "films: \([$all[]|select(dubbed)]|length) of \($all|length) carry the dub",
    "  animation: \([$all[]|select(((.Genres//[])|index("Animation")) and dubbed)]|length) of \([$all[]|select((.Genres//[])|index("Animation"))]|length)"'
```

Repeat with `IncludeItemTypes=Episode` for series.

## Reading the answer

The number alone decides nothing. What matters is whether it **moved** since the last run, and
at what cost:

- **Rising** - the scoring is reaching real releases. Worth what it costs.
- **Flat while downloads churn** - `MULTi` is being grabbed and turning out to carry some other
  language. That is the bet in the MULTi score not paying: a French group's MULTi is original
  plus French with no Dutch in it. The honest response is to drop the MULTi score back to 0
  rather than keep re-downloading for nothing.
- **Flat with no churn** - nothing qualifying exists on the indexers. Neither the score nor
  `DUB_REPLACE_EXISTING` can conjure a release; this is the ceiling.

To see whether churn is happening, count recent grabs that replaced an existing file:

```bash
RK=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' config/radarr/config.xml)
curl -fsS -H "X-Api-Key: $RK" 'http://localhost:7878/api/v3/history?pageSize=100&eventType=1' \
| jq -r '[.records[]?|select(.sourceTitle|test("MULTi";"i"))]|"MULTi releases grabbed recently: \(length)"'
```

## What the number can never tell you

A file can carry a Dutch track that is a *lektor* - one voice read over the original - rather
than a dub. Jellyfin reports it as a Dutch audio stream either way. `.env.example` says why
Lektor is deliberately not matched by the dub formats; this measurement cannot see the
difference, so a rise that looks too good is worth spot-checking by playing one.
