# Working in this repo

## The map

`compose.yml` declares the containers, Gluetun among them; `compose.hwaccel.*.yml` are the only
opt-in overrides, selected by `COMPOSE_FILE` in `.env`. `setup.sh` writes `.env` and the directory tree
once, and refuses to touch an existing `.env`. `configure.sh` then wires the running containers
together through their own APIs — it holds the preamble, the shared constants and the run order,
while each section is a `configure_<app>` function in its own `lib/*.sh`. `heal.sh`, `watch.sh`,
`mover.sh`, `update.sh`, `missing.sh` and `news.sh` run unattended on systemd user timers and each
take `install|status`. `heal.sh` and `watch.sh` are a pair and the line between them is the point:
`heal.sh` **acts** on what it finds, every two minutes; `watch.sh` only **looks and reports**, every
ten. They share `lib/alerts.sh` with `mover.sh`, and `mover.sh` also sources `lib/common.sh` for
`unrestricted_window` - those two are the `lib/` files the timer scripts source directly rather than
through `configure.sh`.
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
putting `# keep` on its first line (`config/homepage/*.yaml`, the Recyclarr configs), or
`/* keep */` for `config/homepage/custom.css`, which is CSS;
`services.yaml` is the exception, rewritten every run because it carries API keys.

**The library is a union.** `data/local` (ext4) and `data/archive/media` (the rclone crypt mount)
are branches of a mergerfs mount at `data/union`, which is what every container gets as `/data`. So
a file is at the same `/data/media/...` path whichever branch holds it, and the apps cannot tell -
that is the point. `mover.sh` is the only thing that addresses the branches directly, because moving
a file through the union would be a copy onto itself. The mount is a systemd *system* unit,
`media-stack-union.service`, ordered `Before=docker.service`; `scripts/union-*.sh` set it up, migrate
to it, probe it and verify it.

Host scripts reach an app at `localhost:<published port>`; an app reaches another app by its
container name. Two exceptions, both easy to get wrong: Plex runs on the host network, so
containers address it as `$LAN_IP`, and qBittorrent, Prowlarr and FlareSolverr live in Gluetun's
namespace, so all three are addressed as `gluetun` (on 8081, 9696 and 8191). `configure.sh` defines both forms at the top —
use those constants instead of writing a URL. qBittorrent's UI is on 8081, because SABnzbd owns
8080.

The README answers most questions in one chapter. Cite chapters **by name, never by number** —
outside the README a number rots silently on the next reorder, which is exactly what happened to
eleven references before this file existed. A name can still rot if the chapter is renamed, so the
citations are checkable — exactly, the whole chapter name: a prefix of one passes by accident and
stops passing the day the tail changes.

```bash
python3 - <<'EOF'
import re, pathlib
readme = pathlib.Path('README.md').read_text()
names = set(re.findall(r'^#{2,3} (?:[0-9]+\. )?(.+)$', readme, re.M))
for p in pathlib.Path('.').rglob('*'):
    if not p.is_file() or p.suffix not in {'.sh', '.yml', '.py', '.example', '.md'}: continue
    if '.git/' in str(p) or p.name == 'AGENTS.md' or 'docs-audit' in str(p): continue
    # Prose and comments both wrap, so a citation can span two lines: join them
    # and drop the comment leader before matching, or the check silently sees
    # nothing. Ten citations hid behind a line break until it did this.
    for n in re.findall(r'README "([^"]+)"', re.sub(r'\n\s*#?\s*', ' ', p.read_text())):
        if n not in names: print(f'{p}: no such chapter: "{n}"')
EOF
```

The chapters worth knowing by name: *Directory structure*, *URLs, hostnames and ports*, *Initial
configuration order*, *Quality: profiles, formats and guards*, *Connecting download clients*,
*Torrents through a VPN*, and the three troubleshooting chapters at the end.

## Procedures

Five of them, as Agent Skills under `.agents/skills/` — the neutral path the standard's clients
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
- `.agents/skills/docs-audit/SKILL.md` — before trusting the documentation: the checks that compare
  `README.md`, this file and `.env.example` against the code, as commands rather than as a reading.

## The run order is a dependency order

`configure.sh` calls its sections in an order that is load-bearing, and nothing enforces it:

- `quality_plan` sets the profile names everything downstream asks for.
- `configure_sabnzbd` sets `SAB_KEY`, which `arr.sh`, `prowlarr.sh` and `homepage.sh` need.
- `configure_jellyfin` sets `JELLYFIN_TOKEN`; `jellyfin_api_key` in `arr.sh` returns empty without
  it, so a wrong order fails *silently* rather than loudly.
- `configure_recyclarr` creates the guide profiles that `configure_dub_preference` then scores
  and `configure_seerr_prefs` points Seerr at. `dub_prefer` edits the guide profile in place, so
  it only survives because the Recyclarr configs set `reset_unmatched_scores: false`.
- `configure.sh` stops Homepage near the start and `configure_homepage` starts it again at the
  end. A section that dies between the two leaves the dashboard stopped.
- Inside `configure_homepage`, `homepage_custom_css` runs after `homepage_widgets_yaml`. The CSS
  pins the archive disk by its position among the resource blocks and reads that position back out
  of the generated `widgets.yaml`, so the other order styles the previous run's list.

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
- **SABnzbd's `set_config` accepts a protected option and does nothing.** `inet_exposure`,
  `api_warnings` and `local_ranges` carry `protect=True`, so `set_dict` drops them: the API
  answers `{"status": true}`, the value never changes, and reading it back is the only way to
  find out. They have to be written into `sabnzbd.ini`, and SABnzbd rewrites that file as it
  shuts down - so stop the container, edit, start, rather than edit and restart.
- **SABnzbd decides for itself whether a client is local, and the host can never see it fail.**
  With `local_ranges` empty it asks Python whether the address is private, which excludes
  Tailscale: `100.64.0.0/10` is shared address space, so a tailnet browser gets "External
  internet access denied" while every check run on this host passes, because loopback is always
  local. Caddy does not hide the client - SABnzbd reads `X-Forwarded-For` and checks every hop.
  Test this one from the device that was refused.
- **A watchdog timing something by wall clock punishes whatever the stack itself
  paused.** `evict_stalled_metadata` blocklisted a magnet when `now - added_on`
  passed `HEAL_METADATA_STALL_MINUTES`, which is time since it was *added*, not
  time spent trying. The disk brake stops torrents for hours, so every stopped
  magnet was already over the limit the instant it resumed - five releases were
  blocklisted within a second of the brake releasing, none of them faulty. qBittorrent's
  `time_active` counts only the time a torrent was actually running, and is the
  field to judge on: one magnet read 329 minutes since it was added against one
  minute active. Before trusting any age test in heal.sh, ask what the stack does
  to that clock while it is braked, queued, or waiting on the quiet window.
- **Renaming on import destroys the only evidence of what a release was.** An audio-description
  release announces itself in the release *title* - "Rick and Morty S01E01 Pilot with Audio
  Description 1080p AMZN...-Kitsune" - and the file is then renamed to the naming format, which
  keeps the quality tags and drops everything else. Eighteen such files sat in the library looking
  exactly like good ones, and judging them by the name on disk says the release could not have been
  caught. It could: `/api/v3/history?episodeId=N&eventType=1` still holds the grabbed title, and
  that is what a `ReleaseTitleSpecification` custom format reads. Ask history what was grabbed
  before concluding a release was unmarked, and never infer a release's contents from the renamed
  file.
- **A guide custom-format group whose members are all `required: false` syncs nothing when added.**
  `[Optional] Accessibility` holds WiTH AD / ASL / BASL / BSL, every one optional, so the group must
  name them under `select` - adding `{trash_id, exclude: null, select: null}` is accepted by
  Recyclarr, reports "All custom formats are already up to date", and produces no formats at all.
  `lib/recyclarr-config.py` reads the group's json and selects every member rather than listing
  ids, because the ids differ per app and a fifth variant would otherwise be missed silently.
  The corollary bit immediately afterwards: **a template may already list the group with no
  `select`**, so a writer that skips a group it has "already seen" adds the formats for one app and
  silently not the other. Sonarr's templates list `[Optional] Language Profiles` exactly that way.
  Merge the selection into the existing entry instead of skipping it, and check both generated
  configs rather than one.
- **Recyclarr adopts a hand-built custom format by name, and then owns it.** Replacing one of ours
  with the guide's does not duplicate it: the id stays (44 in Sonarr, 93 in Radarr) and the
  contents are overwritten to match the guide. There is no cache file to inspect in v8, and the
  "Skipped N Custom Formats that did not change" count does not move when the format already
  matched - so neither proves anything. Compare a field the two versions spell differently: ours
  named the specification "Original", the guide names it "Not Original Language".
- **The disk brake cannot stop rclone's cache, which is the thing that fills the disk.**
  `--vfs-cache-mode full` puts every archived file through the local cache on its way up, so a
  mover run frees bytes from the library and spends them again on cache - and `df` only recovers
  an hour later, when `--vfs-cache-max-age` expires them. `heal.sh` stops downloads at
  `DISK_FLOOR_GIB` and the cache keeps growing past it, so `RCLONE_CACHE_MAX` has to be well
  under the floor - half of it - and the whole chain is `ARCHIVE_MAX_GIB_PER_RUN <=
  RCLONE_CACHE_MAX / 2 <= DISK_FLOOR_GIB / 4`. The shipped defaults had a 50G cache against a
  25 GiB floor, which is the brake defending a line the cache walks straight through. The cache
  lives in the rclone container's writable layer, not under `DATA_ROOT`, so recreating the
  container empties it at once - but see the next entry: that is not a safe thing to do while the
  union is assembled, so treat the cache as self-managing and let the max-size and max-age limits
  reclaim it.
- **Never recreate the rclone container while the union is assembled.** Doing it leaves a dead
  FUSE endpoint - listed in `/proc/mounts`, answering `Transport endpoint is not connected`,
  invisible to `mountpoint -q` - and the replacement container restart-loops on `failed to access
  mountpoint ... Socket not connected` while the whole archive tier reads as missing.
  `fusermount3 -u` cannot clear it ("not found in /etc/mtab") and the mount is root-owned, so
  recovery is `sudo umount -l <path>`: nothing the stack can do for itself.

  The first version of this entry said it was safe "between mover passes". It is not, and the
  correction cost a second outage. `fuser -m data/archive` lists dozens of holders, mergerfs among
  them, because the union keeps the branch open for as long as it exists - so the mountpoint is
  **never** idle and there is no quiet moment to recreate in. Stop the union first or do not
  recreate at all. Reclaiming the VFS cache is not a reason to: `--vfs-cache-max-size` and
  `--vfs-cache-max-age` already do it.
- **`RenameFiles` with an empty `files` list succeeds and renames nothing.** The command takes the
  parent id *and* the file ids; `{name, seriesId, files: []}` is accepted, reports success, and is
  a no-op. The ids come from the same `/api/v3/rename` response that said the names were stale -
  `episodeFileId` in Sonarr, `movieFileId` in Radarr. Check a file on disk afterwards rather than
  trusting the command's answer.
- **Homepage polling qBittorrent with a stale login earns a one-hour IP ban** after five failures,
  which is why the login change stops Homepage before anything else runs.
- Under `set -euo pipefail` a bare `return` after a failed test hands back that status and ends the
  whole run, silently. Write `return 0`.
- **`printf` without a newline makes `read` return 1 even though it worked.** `unrestricted_window`
  ends with `printf '%d %d %d %d'`, so `read -r a b c d < <(...)` fills every variable and still
  exits non-zero at EOF - and `|| return 0` after it then fires on success. That is how a
  quiet-hours check answered "inside the window" at every hour of the day. Read it into a variable
  and use `<<<`, which supplies the newline.
- **A value with a space in it breaks `.env` for the shell, not for compose.** `.env` has two
  readers: compose parses it, and `heal.sh`, `watch.sh` and `mover.sh` `source` it. Compose accepts
  `KEY=a b` and the shell reads the second word as a command — `set -euo pipefail` then ends the run
  at exit 127. Verifying through `docker compose config` alone will not show it. Quote the value, and
  check with `bash -c 'set -a; . ./.env; set +a'` before believing it works.
- **"Nothing references it" is not "nothing wants it".** Before deleting a completed download,
  the test that matters is whether an app still *wants* the thing, not whether a client still
  *holds* it. Two Hozier albums sat in `usenet/complete` with one link each and no queue entry -
  and Lidarr had them monitored with 0 of 19 and 0 of 26 tracks, still waiting. They imported
  through nothing because the job had aged out of SABnzbd's history, which is how an *arr app
  correlates a finished download at all. Match the apps' queue `outputPath`, and check
  monitored-and-missing before removing anything the library could still be short of.
- **`config/rclone/rclone.conf` goes back to root-owned 0600 on its own.** rclone runs as root and
  rewrites the file on every Drive token refresh, so a `chown` to your user holds only until the
  next one - it is not a one-time fix and nothing should depend on the file being readable. Three
  separate checks have been caught by this: `archive_enabled`, `rclone_conf_has` and
  `archive_backend`. The first two treat "cannot read" as "cannot tell" and err towards configured;
  the third asks the rclone container, which owns the file, rather than guessing.
- **A union has to span the download folders, or every import becomes a copy.** Hardlinking from
  an ext4 download directory into a FUSE library is cross-device: `link()` returns `EXDEV` and the
  arr app silently falls back to copying the whole file. So `torrents` and `usenet` live on the
  local branch *inside* the union, not beside it, and the link is made within that branch.
  `scripts/union-verify.sh` tests it, because nothing else would notice until the disk filled twice
  as fast as expected.
- **An unmounted branch is not an error, it is a plain directory.** Write to `data/archive/media`
  while rclone is down and the bytes land on the local disk - the one the mover was trying to free -
  and vanish from view the moment rclone mounts over them. Every path that writes to a branch checks
  `mountpoint -q` first, and `mover.sh` refuses to run unless the union and both branches are
  mounted.
- **mergerfs resolves its branches per operation**, so a mount appearing under a branch *after*
  mergerfs started is picked up. That is what lets the unit run `Before=docker.service` while the
  rclone container mounts the cloud branch later. Proved with `scripts/union-probe.sh` rather than
  assumed - and the first version of that probe reported a false negative because its fixture nested
  the late mount one level too deep.
- **Sonarr will not be told where an episode file is.** `PUT /api/v3/episodefile/{id}` answers 202
  and ignores a changed `path`: the path is derived from the series root plus `relativePath`, not
  stored. There is no per-episode or per-season root folder either. That is why episode-level
  archiving needs the storage layer to present one path, and cannot be done through the API.
- **Lidarr loses its files when a root folder changes; Radarr and Sonarr do not.** Those two
  derive a file's path from `rootFolderPath` + `relativePath`, so moving a title between roots with
  `moveFiles: false` costs nothing. Lidarr stores absolute track paths, so the same edit orphans
  every record and its next scan removes them: the artists remain, `trackFileCount` goes to 0 of N,
  `sizeOnDisk` to 0, and **no health error is raised** - the only symptom is a library that looks
  empty while the files sit there perfectly readable. Worse, a monitored album with no files is one
  Lidarr will re-download. Rescan it (`RefreshArtist` per artist, then `RescanFolders`) after any
  root-folder change.
- **A Radarr collection carries a root folder as well as a quality profile.** Retiring a root
  folder leaves collections pointing at a path that no longer exists, and Radarr reports
  `Missing root folder for movie collection` naming each one - days later, because nothing
  checks it at the time. Repointing films is not enough: films and collections live in
  different endpoints and only the profile was shared, so the first fix repointed
  `qualityProfileId` on collections and left `rootFolderPath` wrong. `move_to_managed_profile`
  now moves any collection whose root folder has gone, which is general rather than a patch for
  the three that broke.
- **A quality profile can be "in use" with nothing on it.** In Radarr a *collection* carries a
  `qualityProfileId` of its own, so a profile every film has moved off still answers 500
  `QualityProfile [7] is in use.` on delete. Repoint `/api/v3/collection` as well as
  `/api/v3/movie`. Sonarr has no collections, so the same code needs the app guard.
- **Folding a quality into a group invalidates the profile's cutoff.** `cutoff` names a
  *top-level* quality or group id; put `Bluray-1080p` inside the `WEB 1080p` group and the PUT
  answers 400 `Cutoff must be an allowed quality or group` with no hint as to which field. Move
  the cutoff to the group's id in the same edit - which is what the guides' own merged profiles do.
- **`moveFiles: true` on the bulk editor will pull a film back out of the archive tier.** The
  editor applies one `rootFolderPath` to every id it is given, so a repoint that was meant for the
  dubbed root also relocated a film living in `/data/archive/movies`, and Radarr spent an 11 GiB
  download dragging it off Google Drive so the mover could push it back. Split the ids by the root
  they are actually in and only relocate the ones you mean to.
- **`(( i++ ))` returns status 1 while `i` is still 0**, because a post-increment
  evaluates to the *old* value and an arithmetic command evaluating to zero is a
  failure. Under `set -euo pipefail` that ends the run at the first increment of a
  counter, with no message at all - the Plex user section died exactly there, after
  printing nothing, which reads as if the function was never entered. Write
  `i=$(( i + 1 ))`, or `(( ++i ))`.
- **Recyclarr discards a config file it dislikes without saying which or why.** A
  `quality_profiles` entry whose `upgrade.until_quality` names something absent from its own
  `qualities` list fails validation, and the whole file is dropped: the run then reports
  `Found 1 config files with 1 Radarr and 0 Sonarr instances` and syncs Radarr alone, with no
  error anywhere. Nothing downstream notices either, because the profiles it had already made
  are still there - it has merely stopped maintaining them. This is how the union's group
  rename (`WEB 1080p` -> `Bluray|WEB 1080p`) silently stopped Sonarr syncing for half a day:
  Radarr's cutoff is a quality *folded into* the group and kept working, Sonarr's cutoff is the
  group's own *name*. `lib/recyclarr-config.py` now raises if a cutoff is not among the
  qualities it emitted. To check by hand: `recyclarr config list local` and count the instances.
- **`pgrep -f` matches its own command line.** `docker compose exec plex sh -c 'pgrep -f "Plex
  Media Scanner"'` always answers yes, because the `sh -c` process it runs in contains that very
  string - so "is the scanner still running" can only ever be answered one way. A wait loop built
  on it never ends: one spun for a full fifteen minutes and the timeout was read as "the scan is
  slow" rather than "the predicate is broken", and the scan had in fact finished long before.
  Use the bracket trick the same way you would with `grep` on `ps` output - `pgrep -af "Plex Media
  [S]canner"` - or ask the application instead; Plex answers `/activities` with what it is really
  doing. Never conclude a job is running from a check that cannot return false.

  The bracket trick does not rescue the other shape of this: a wait loop whose own command line
  *invokes* the thing it waits for. `until ! pgrep -f configure.sh; do sleep 10; done; ./configure.sh`
  contains the literal string in both halves, so `[c]onfigure\.sh` matches it too and the loop waits
  on itself for ever - quietly, looking exactly like a long run. Two of those sat here for twenty
  minutes while nothing at all was running, and the second configure.sh never started. Wait on a pid
  you captured, on a systemd unit's state, or on a marker the job itself writes; never on a pattern
  that your own command line contains.
- **A `RETURN` trap fires again when the *calling* function returns.** It is not
  function-local: `trap 'rm -f "$tmp"' RETURN` set inside a function stays armed,
  and when the function that called it returns, the trap runs in that frame -
  where the inner function's `local` no longer exists. `set -u` then ends the run
  with `line N: tmp: unbound variable`, pointing at a line in the caller, which
  reads as though an unrelated function is at fault. `lib/plex.sh` was written
  this way and killed a run after the Plex section.

  Sibling functions are *not* affected, which is why a naive reproduction passes
  and this looks like superstition. The reproduction that does fail is: function
  sets the trap, returns; its caller then returns.

  Every other `RETURN` trap in `lib/` is called from `configure.sh`'s top level,
  so there is no enclosing frame and nothing leaks. The one exception is
  `remove_seerr_dub_servers`, which is nested, and which survives only because
  both of its callers happen to hold a `local jar` of their own - bash's dynamic
  scoping pointing the leaked trap at a live variable. That is luck, so it uses
  `${jar:-}`. Guard the expansion, clean up explicitly, or keep the variable
  global; do not rely on the caller owning a variable of the same name.
- **An empty answer is not a negative one.** `jq` given an empty body prints nothing and exits 0, so
  a guard built from `cmd | jq` arrives as an empty string that reads as "the thing holds nothing" -
  and a protection written as `if [[ -n "$list" ]]` is then skipped rather than enforced. That is
  how the orphan sweep deleted a complete torrent's files while qBittorrent still held it. Check the
  shape (`jq -e 'type == "array"'`) before believing the answer, and never let "cannot tell" take
  the same branch as "nothing". `archive_enabled` had the same fault with `grep`'s exit 2.

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
