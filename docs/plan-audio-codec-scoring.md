# Plan: prefer audio this house can actually play

Status: **not built**. This is the design and the evidence for it, written so the work can be
picked up without re-deriving any of it. Nothing in `lib/` implements this yet.

## The problem, measured rather than assumed

A Samsung Tizen television cannot decode DTS. When the audio track Plex wants is DTS or TrueHD it
transcodes the audio while passing the video through, and **video-direct-plus-audio-transcode is an
unfixed Plex-for-Samsung defect** — see the Plex entry under *Traps* in `AGENTS.md`, which also
lists the five causes already disproved so they are not retried.

Observed live on 2026-10-03, playing `Encanto (2021)` on the living-room set:

```
11:23:11  pos 0.35min  playing  Plex for Samsung @192.168.1.200
          | video=copy audio=transcode throttled=1 speed=0 | audio: English aac
```

The file is `Encanto.2021.DUTCH.1080p.BluRay.x264-HDEX`, whose tracks are:

| Track | Language | Codec | Channels |
|---:|---|---|---|
| 1 | eng | **DTS-HD MA** | 7.1 |
| 2 | nld (Dutch) | AC3 | 5.1 |
| 3 | nld (Flemish) | AC3 | 5.1 |

English *is* track 1, so track order was not the fault here. The **codec** was: Plex re-encoded
DTS-HD MA to AAC and put playback on the broken path.

### It is not one unlucky release

Measured across the 196 films in the library, by the codec of their **first** audio track, as
Jellyfin probed it on import:

| First-track codec | Bluray files | WEB files |
|---|---:|---:|
| EAC3 | 47 | 71 |
| AC3 | 16 | 7 |
| AAC | 0 | 20 |
| **DTS** | **30** | **0** |
| **TrueHD** | **5** | **0** |
| **DTS or TrueHD** | **35 of 98 (35%)** | **0 of 98 (0%)** |

So a third of Bluray releases arrive unplayable on the only televisions in the house, and no WEB
release ever does. That is the trade-off hiding behind "Bluray is better": Bluray carries
10.1 Mbit/s median video against WEB-DL's 6.8, and a 35% chance of audio the TV cannot decode.

### Which codecs are safe

| Codec | Direct plays on the Samsung? | Evidence |
|---|---|---|
| EAC3 (DD+) | **yes** | a file direct played HEVC *and* EAC3 that the shipped client profile forbids — `AGENTS.md`, Traps |
| AC3 (DD) | yes | long-standing Dolby Digital support |
| AAC | yes | it is what Plex transcodes *to* for this client |
| DTS, DTS-ES, DTS-HD HRA, DTS-HD MA, DTS X | **no** | Plex removed its DTS toggle and 2018+ Samsung sets carry no DTS licence; confirmed by the transcode above |
| TrueHD, TrueHD ATMOS | **no** | same family of unsupported lossless formats |

**Verify before building.** The DTS conclusion rests on the single observation above plus
research, not on a per-codec playback test. One file per codec played on the actual set would
settle it, and is cheap.

## The design

### Positive scores on safe codecs, not negative scores on unsafe ones

This is the load-bearing decision. `minFormatScore` is **0**, so any release whose total score goes
negative is *rejected*, not merely ranked lower. A penalty on DTS would therefore refuse a film
that is only offered with DTS — and a film that needs one transcode is better than no film.

So: score the codecs the TV can play **above zero**, and leave DTS and TrueHD at the guide's 0.
Everything stays grabbable; the safe release simply wins when both exist.

| Format (Radarr's own names, all currently scored 0) | Proposed |
|---|---:|
| `DD+`, `DD+ ATMOS` | + |
| `DD` | + |
| `AAC` | + |
| `DTS`, `DTS-ES`, `DTS-HD HRA`, `DTS-HD MA`, `DTS X` | 0 (unchanged) |
| `TrueHD`, `TrueHD ATMOS` | 0 (unchanged) |

All sixteen audio formats already exist in both apps — the guides ship them and Recyclarr syncs
them. Nothing new has to be created, only scored. The guides deliberately score them all 0, so
this is a documented deviation and belongs in the README beside the foreign-first guard.

### The size of the number matters more than the sign

The guides' release-group tiers span **1600 to 1800**. An audio score large enough to outrank a
tier would trade a top-tier release for a bottom-tier one to gain a codec, which is the wrong
trade. An audio score must be *smaller* than the gap between adjacent tiers, so it only decides
between releases that are otherwise equal. **50 is the starting proposal; the tier gaps are 50
apart, so anything larger inverts the tier order and has to be checked against
`/api/v3/parse` rather than reasoned about.**

### Where the code goes

`lib/profiles.sh`, inside the existing **`our_scores`** function. That function is already the
single owner of every score this stack sets: it runs after `configure_recyclarr`, reads the
profile, applies the foreign-first guard and the `UNSCORED_FORMATS` zeroes, compares, and writes
once. Adding a map of audio format names to scores is a few lines in the same `jq` pass and gets
the convergence behaviour for free.

**Do not put this back where it was.** An earlier attempt lived in a separate post-hoc step and was
abandoned because Recyclarr restored the guide's 0 from its templates before the step ran, so three
profiles changed on every single run and `configure.sh` could never converge. Two things fixed since
make the new placement sound:

- `our_scores` compares before writing, and `reset_unmatched_scores: false` means a score it writes
  survives Recyclarr's nightly sync.
- `recyclarr-config.py` now has a `SKIP_GROUPS` mechanism for the other half of that fight — a
  guide group whose scores would be re-applied can be dropped at the source. The language-profiles
  group needed exactly this because *Sonarr's* templates list it while Radarr's do not.

If a future sync is found re-applying an audio score, `SKIP_GROUPS` is the lever, not a louder
number.

## The risk that needs handling first: churn

`minUpgradeFormatScore` is **1** and `upgradeAllowed` is **true**. So *any* score gain makes an
existing file eligible for replacement — and **35 of 196 films have DTS or TrueHD on track 1**.
Scoring safe codecs above 0 would make all 35 upgrade candidates at once.

That is 35 re-downloads for an audio track, against a Google Drive upload allowance that has
already blocked this stack for hours at a time (`AGENTS.md`, the 403 entry). It must be a decision,
not a surprise.

Three options, in order of preference:

1. **Raise `minUpgradeFormatScore` above the audio delta.** An existing file is then never
   re-grabbed merely to change codec, while new grabs still prefer safe audio. This is exactly what
   the retired `DUB_UPGRADE_FLOOR` did, so the pattern is known-good here. The field is written by
   Recyclarr, not by us, so it belongs in `lib/recyclarr-config.py` — setting it in `our_scores`
   would be overwritten on the next sync.
2. **Accept the churn deliberately**, with the download clients held to one job each so the disk
   stays bounded, and only once Drive is accepting uploads again.
3. **Re-mux the 35 files in place** instead of re-downloading — far cheaper in bandwidth, but it
   edits the library, which needs explicit per-file approval.

Option 1 is the default this plan assumes.

## Verification, before claiming it works

A green re-run proves nothing about a branch it skipped, so each of these has to be made to run:

1. **Scores land.** Read all four managed profiles in both apps and confirm the audio scores, as
   `our_scores` already does for the guard.
2. **Nothing is newly rejected.** Replay the 350 distinct grabbed titles from
   `/api/v3/history?eventType=1` through `/api/v3/parse` and diff the accept/reject verdict against
   a snapshot taken first. A DTS-only release must still be *acceptable*.
3. **The preference actually bites.** Take a film offered as both DTS and EAC3, run an interactive
   search, and confirm the EAC3 release now outranks the DTS one — ranked order, not just scores.
4. **Tier order is intact.** Confirm no release moved across a release-group tier boundary. This is
   what a too-large number breaks, and it is invisible in the score list.
5. **Churn is counted.** Record the cutoff-unmet count before and after. It must not jump by 35.
6. **Idempotency.** A second `configure.sh` reports `kept` on every line and exits 0.
7. **Convergence against Recyclarr.** Run a bare `recyclarr sync radarr` and `recyclarr sync
   sonarr` afterwards and confirm each reports "All quality profiles are up to date" — the check
   that caught the Sonarr fight.

## Optional, and separate: close the bare-language-tag gap

Removing `Language: Not Original` to let `.DUTCH.` releases through also let a handful of genuinely
foreign releases through. Of the 350 historical grabs, four:

```
Ice Age 3.2009 Danish 1080p BluRay x264-GERUDO
Ice.Age.3.2009.Danish.1080p.BluRay.x264-GERUDO
Les.Legendaires.2025.FRENCH.1080p.WEB.H264-SUPPLY
One.Battle.After.Another.2025.German.1080p.HMAX.WEB-DL.MULTi.DDP5.1.Atmos.H.264-FUZEER
```

The `Foreign Audio First (title)` guard misses these because its pattern wants a `FOREIGN-ENG`
pair, a French marker, `EniaHD` or `[Esp]`, and a bare `Danish` is none of those.

A naive fix — matching bare language words — is wrong, and measurably so: it wrongly blocks **5 of
411** live `.DUTCH.` releases, because a good multi-audio release *lists* its languages
(`[EAC3 5 1][English+Mandarin+Czech+Danish+…]`) and so names several foreign ones.

What works is a **positional** pattern: the language word sitting in the scene-tag slot, directly
followed by a release token (`1080p`, `BluRay`, `WEB-DL`, `PROPER`, …), as in
`Title.Year.DANISH.1080p.BluRay`. Measured:

| | Count |
|---|---:|
| Foreign grabs caught, of 350 | **4 of 4** |
| `.DUTCH.` releases wrongly blocked, of 411 | **1** |

The single Dutch casualty is `Ni.Le.Ciel.Ni.La.Terre.2015.FRENCH.1080p.WebHD.H264-DUTCH` — a French
film whose *release group* happens to be called `DUTCH`, which carries French audio and should be
refused anyway. So the real false-positive count is 0.

Dutch and Flemish are excluded from the language list, for the same reason they are excluded from
the existing pattern: those releases are wanted.

This is independent of the audio-codec work and can ship on its own.
