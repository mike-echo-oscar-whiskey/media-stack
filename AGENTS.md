# Working in this repo

## The map

`compose.yml` declares the containers, Gluetun among them; `compose.hwaccel.*.yml` are the only
opt-in overrides, selected by `COMPOSE_FILE` in `.env`. `setup.sh` writes `.env` and the directory tree
once, and refuses to touch an existing `.env`. `configure.sh` then wires the running containers
together through their own APIs — it holds the preamble, the shared constants and the run order,
while each section is a `configure_<app>` function in its own `lib/*.sh`. `heal.sh`, `update.sh`,
`missing.sh` and `news.sh` run unattended on systemd user timers and each take `install|status`.
`scripts/release-guard.sh` is different from all of these: it runs *inside* the Sonarr and Radarr
containers as a Custom Script connection, registered by `add_release_guard` in `lib/arr.sh`.

**`lib/` is not a set of modules.** Every file is sourced before anything runs, they define
functions only, and they call across each other freely: `common.sh` (`arr`, `set_env`,
`xml_apikey`, `urlenc`, `configure_ui_dates`) from everywhere, `set_arr_login` in `arr.sh` from
`prowlarr.sh`, `jf` in `jellyfin.sh` from `arr.sh`, `plex_token` in `plex.sh` from `homepage.sh`,
`recyclarr_profile` in `recyclarr.sh` from both `seerr.sh` and `profiles.sh`. They also hand each
other run-time state in globals — `SAB_KEY` from `sabnzbd.sh`, `JELLYFIN_TOKEN` from
`jellyfin.sh`, `Q_DEFAULT` and `SEERR_QUALITY_PROFILE` from `quality_plan`.

Settings live in `.env`; `.env.example` is its template and every key is documented there.
`config/` belongs to the apps, is gitignored, and is never hand-edited — a fix clicked into a web
UI is not done until `configure.sh` performs it. A generated file can be taken over by hand by
putting `# keep` on its first line (`config/homepage/*.yaml`, the Recyclarr configs);
`services.yaml` is the exception, rewritten every run because it carries API keys.

Host scripts reach an app at `localhost:<published port>`; an app reaches another app by its
container name. Two exceptions, both easy to get wrong: Plex runs on the host network, so
containers address it as `$LAN_IP`, and qBittorrent, Prowlarr and FlareSolverr live in Gluetun's
namespace, so all three are addressed as `gluetun` (on 8081, 9696 and 8191). `configure.sh` defines both forms at the top —
use those constants instead of writing a URL. qBittorrent's UI is on 8081, because SABnzbd owns
8080.

The README answers most questions in one chapter. Cite chapters **by name, never by number** —
outside the README a number rots silently on the next reorder, which is exactly what happened to
eleven references before this file existed. A name can still rot if the chapter is renamed, so the
citations are checkable:

```bash
grep -rhoE 'README "([^"]+)"' --include='*.sh' --include='*.yml' --include='*.example' . |
  sed 's/README "//; s/"$//' | sort -u |
  while read -r n; do grep -q "^## [0-9]*\. $n" README.md || echo "no such chapter: $n"; done
```

The chapters worth knowing by name: *Directory structure*, *URLs, hostnames and ports*, *Initial
configuration order*, *Quality: profiles, formats and guards*, *Connecting download clients*,
*Torrents through a VPN*, and the three troubleshooting chapters at the end.

## Procedures

Four of them, as Agent Skills under `.agents/skills/` — the neutral path the standard's clients
scan, symlinked from `.claude/skills/` because Claude Code reads its own. A client with no skills
mechanism can simply open the file:

- `.agents/skills/add-content/SKILL.md` — before adding a film or series: Seerr first, TMDB ids for
  films against TVDB for series, the anthology season offset, and that a library write waits for an
  explicit instruction.
- `.agents/skills/remove-content/SKILL.md` — before deleting anything: the two-click Seerr path, why
  hardlinks delay the space coming back, and that Plex keeps watch history regardless.
- `.agents/skills/env-settings/SKILL.md` — before changing `.env`: which keys need `configure.sh`,
  which need a container recreate, no spaces in values, rates in KiB.
- `.agents/skills/fresh-install-test/SKILL.md` — before claiming an install-path change works: the
  teardown, clone, credentials, verify and restore sequence.

## The run order is a dependency order

`configure.sh` calls its sections in an order that is load-bearing, and nothing enforces it:

- `quality_plan` sets the profile names everything downstream asks for.
- `configure_sabnzbd` sets `SAB_KEY`, which `arr.sh`, `prowlarr.sh` and `homepage.sh` need.
- `configure_jellyfin` sets `JELLYFIN_TOKEN`; `jellyfin_api_key` in `arr.sh` returns empty without
  it, so a wrong order fails *silently* rather than loudly.
- `configure_recyclarr` creates the guide profiles that `configure_dub_profiles` copies into
  twins and `configure_seerr_prefs` points Seerr at.
- `configure.sh` stops Homepage near the start and `configure_homepage` starts it again at the
  end. A section that dies between the two leaves the dashboard stopped.

## Traps

Each of these cost a debugging session, and none can be read off the code.

- **Bodies go on stdin.** One argument caps at 128 KB; a profile carrying a hundred custom formats
  and the specification schema both exceed it. `arr()` handles it — pass large JSON to `jq` on
  stdin too, and strip `.presets`, `.infoLink` and `.implementationName` before posting a schema.
- **Custom-format conditions of the same type are OR-ed, of different types AND-ed.** Verified
  against `/api/v3/parse`. One condition type per format, or the rule silently cannot match.
- **Resolve condition options by name, never by number.** Radarr's `SourceSpecification` counts
  cam, telesync, telecine, workprint where Sonarr's counts Television, TelevisionRaw, Web, WebRip.
- **qBittorrent's `setShareLimits` requires `shareLimitAction`** since 5.1, or it answers 400
  "Missing required parameters", which reads as if the limits were wrong. `-2` means "use global".
- **Recyclarr groups instances by `base_url`** and syncs nothing, silently, when two share one.
  One instance per app, `reset_unmatched_scores: false`, and the config writer exits **9** for
  "already correct" — catch it or `set -e` ends the run.
- **Prowlarr masks stored API keys as `****`**, so a stale key cannot be found by comparing; test
  the application instead.
- **Seerr**: a plain GET of `/settings/plex/library` disables every library, so sync and enable are
  two calls. Anything that must converge on an existing install belongs in `configure_seerr_prefs`,
  not `configure_seerr`, which only runs on a fresh install.
- **`jq`'s `inside()` matches substrings.** It matched `HD-1080p` inside another profile name and
  rebuilt the stock profile from "Any". Match exactly.
- **Poll a container after `docker compose restart`** before calling it again, or the next request
  dies on a closed socket (`curl: (56)`).
- **Rates are decimal, suffixes are binary.** A line rate of 1 Mbit/s is 125000 B/s, but
  SABnzbd's `K`/`M`/`G` mean KiB/MiB/GiB: `bandwidth_max: 75M` asks for 629 Mbit/s, not 600.
  Convert to bytes and pass whole KiB. qBittorrent takes plain B/s and rounds to KiB, which
  costs 32 B/s on a 100 Mbit cap and is fine. Check a cap by reading it back in B/s, never by
  dividing by 1024² and calling the result Mbit.
- **Homepage polling qBittorrent with a stale login earns a one-hour IP ban** after five failures,
  which is why the login change stops Homepage before anything else runs.
- Under `set -euo pipefail` a bare `return` after a failed test hands back that status and ends the
  whole run, silently. Write `return 0`.

**Never print these:** `.env`, `config/*/config.xml`, `config/homepage/services.yaml`, Seerr's
`settings.json`, `config/recyclarr/configs/*.yml`. Compare files, call the app's own test endpoint,
or print a length instead.

## Finishing a change

Steps are idempotent: GET, compare, then `ok` when you changed something or `skip` — which prints
**`kept`** — when you did not. A second run must change nothing and exit 0.

A new section is three things, not one: the `lib/*.sh` file, a key in `.env.example` if it is
configurable, and a README chapter.

A green re-run proves nothing about a branch it skipped, and on an idempotent script the second
pass skips nearly everything. Before trusting a fix, put the system back into the state that runs
the branch and watch it execute. Changes to the install path are proven on an empty install:
fresh clone, `setup.sh`, `up -d`, `configure.sh`.
