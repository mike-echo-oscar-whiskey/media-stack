"""Writes one Recyclarr config file per app, merged from the guide's templates.

Called by lib/recyclarr.sh with everything in the environment. Exits 9 when the
file is already what it should be, so the caller can report "kept".

Naming comes from here too, not from lib/arr.sh: the guide owns the formats, so
the guide's own sync is what should apply them. The Plex variants are chosen
because Plex is this stack's primary server and its agents match on the braced
id; Jellyfin's bracketed form cannot be had at the same time.

Why one file with one instance per app: Recyclarr groups instances by base_url
and silently does nothing when several of them point at the same server, so the
four templates cannot each be their own instance. They are merged instead - four
quality profiles and the union of the custom-format groups, in one instance.
"""

import os
import pathlib
import re

import yaml

app = os.environ["RECYCLARR_APP"]
cache = pathlib.Path(os.environ["RECYCLARR_CACHE"])
names = os.environ["RECYCLARR_TEMPLATES"].split()
dst = pathlib.Path(os.environ["RECYCLARR_DST"])

# Guide keys, exactly as `recyclarr list naming <app>` reports them.
MEDIA_NAMING = {
    "sonarr": {
        "series": "plex-tvdb",
        "season": "default",
        "episodes": {
            "rename": True,
            "standard": "default",
            "daily": "default",
            "anime": "default",
        },
    },
    "radarr": {
        "folder": "plex-tmdb",
        "movie": {"rename": True, "standard": "plex-tmdb"},
    },
}

# Bluray-<res> is folded into the "WEB <res>" group beside it, as TRaSH's own
# [French MULTi.VO] profiles do, so the two sources rank *equally* and a
# custom-format score decides between them. In Radarr quality rank is compared
# before custom-format score, so while Bluray-1080p is a separate higher rank no
# score can ever prefer a WEB release - and preferring WEB is the point: measured
# on this library, 35 of 98 Bluray files carry DTS or TrueHD on track 1 against
# 0 of 98 WEB files, and those are the ones the televisions cannot decode.
#
# It also fixes the cutoff. Un-folded, the guide's cutoff is Bluray-1080p, which
# puts every WEB file *below* cutoff: 98 films here, every one of them an upgrade
# candidate. Folded, the cutoff is the group and both sources satisfy it.
#
# This code was removed when the dub preference went and restored when the audio
# measurements arrived. The reason has changed completely - it used to exist so a
# dub score could outrank quality - so do not read the history as precedent.
# See README "Audio the televisions can decode".
guides = cache.parents[2] / "trash-guides" / "git" / "official" / "docs" / "json" / app
guide_profiles: dict = {}
for f in sorted((guides / "quality-profiles").glob("*.json")):
    import json as _json
    d = _json.loads(f.read_text())
    if d.get("trash_id"):
        guide_profiles[d["trash_id"]] = d


def fold_bluray_into_web(items):
    """Bluray-<res> joins the "WEB <res>" group beside it. Returns
    (items, renames) - renames maps a group's old name to its new one, which the
    cutoff has to follow."""
    renames: dict[str, str] = {}
    items = [dict(i) for i in items]
    resolutions = sorted(
        m.group(1)
        for i in items
        if i.get("allowed") and (m := re.fullmatch(r"WEB (\d+p)", i.get("name", "")))
    )
    for res in resolutions:
        gn, bd = f"WEB {res}", f"Bluray-{res}"
        group = next((i for i in items if i.get("name") == gn), None)
        bluray = next((i for i in items if i.get("name") == bd), None)
        if group is None or bluray is None:
            continue
        m = dict(group, name=f"Bluray|{gn}", allowed=True,
                 items=list(group.get("items") or []) + [bd])
        renames[gn] = m["name"]
        # The merged group takes the better slot: the one Bluray-<res> held when
        # it was already allowed, otherwise the group keeps its own.
        if bluray.get("allowed"):
            items = [m if i.get("name") == bd else i for i in items if i.get("name") != gn]
        else:
            items = [m if i.get("name") == gn else i for i in items if i.get("name") != bd]
    return items, renames


def as_qualities(items):
    """Recyclarr's `qualities:` shape - a group is a name plus nested names."""
    out = []
    for i in items:
        if not i.get("allowed"):
            continue
        if i.get("items"):
            out.append({"name": i["name"], "qualities": list(i["items"])})
        else:
            out.append({"name": i["name"]})
    return out


merged = {"base_url": os.environ["RECYCLARR_URL"], "api_key": os.environ["RECYCLARR_KEY"]}
profiles: list = []
groups: list = []
skips: list = []
seen: set = set()

for name in names:
    template = cache / app / "templates" / f"{name}.yml"
    if not template.is_file():
        raise SystemExit(f"the guide no longer ships the {app} template {name!r}")
    section = next(iter(yaml.safe_load(template.read_text())[app].values()))
    merged.setdefault("quality_definition", section.get("quality_definition"))
    for profile in section.get("quality_profiles") or []:
        # Our own formats are not in the guide, so an unmatched-score reset
        # would clear them out of every profile on each sync.
        profile["reset_unmatched_scores"] = {"enabled": False}
        guide = guide_profiles.get(profile.get("trash_id"))
        if guide:
            items, renames = fold_bluray_into_web(guide["items"])
            profile["qualities"] = as_qualities(items)
            # The cutoff has to name something in that list, and there are two
            # ways it can stop doing so. It is a quality that got folded *into* a
            # group (Radarr cuts off at Bluray-1080p), or it is the group's own
            # name, which the fold renamed (Sonarr cuts off at "WEB 1080p", now
            # "Bluray|WEB 1080p"). Missing the second meant Recyclarr rejected the
            # whole sonarr.yml - silently, reporting only "Found 1 config files"
            # and syncing Radarr alone.
            cutoff = renames.get(guide["cutoff"], guide["cutoff"])
            for i in items:
                if cutoff in (i.get("items") or []):
                    cutoff = i["name"]
                    break
            profile["upgrade"] = {
                "allowed": guide.get("upgradeAllowed", True),
                "until_quality": cutoff,
                "until_score": guide["cutoffFormatScore"],
            }
            profile["min_format_score"] = guide["minFormatScore"]
            # min_upgrade_format_score is deliberately NOT set: the guide's own
            # value stands, so a release that scores better than the file on disk
            # replaces it. That is wanted here - the library is meant to converge
            # on the rules rather than keep whatever arrived first - and the
            # one-at-a-time pacing is scripts/audio-regrab.sh's job, not a score's.
            names = {q["name"] for q in profile["qualities"]}
            if cutoff not in names:
                raise SystemExit(
                    f'{app}: cutoff {cutoff!r} is not among the qualities '
                    f'{sorted(names)} - Recyclarr would discard this file silently')
        profiles.append(profile)
    formats = section.get("custom_format_groups") or {}
    for group in formats.get("add") or []:
        if group["trash_id"] not in seen:
            seen.add(group["trash_id"])
            groups.append(group)
    for group in formats.get("skip") or []:
        skips.append(group)

# Groups a template asks for that this stack does not want. Sonarr's templates
# list [Optional] Language Profiles in their own `add`, with `select: null` - and
# that is *not* inert: Recyclarr reports "4 contain updated scores" and puts
# "Language: Not Original" back to -10000 on every sync. Radarr's templates do
# not list it, which is why only Sonarr fought back.
#
# -10000 on that format refuses every Dutch-dubbed release there is - 40 of 40
# live ones measured through /api/v3/parse - and those are wanted here, for the
# children. Zeroing the score after the sync cannot win against something that
# re-applies it, so the group is skipped at the source instead. Recyclarr's own
# `skip` list is the mechanism.
#
# The id is read from the guide's json rather than written out, because it differs
# per app: 74aff41... in Sonarr against 13856622... in Radarr.
SKIP_GROUPS = ("optional-language-profiles",)

for group_file in SKIP_GROUPS:
    path = guides / "cf-groups" / f"{group_file}.json"
    if not path.is_file():
        raise SystemExit(f"the guide no longer ships the {app} group {group_file!r}")
    import json
    tid = json.loads(path.read_text())["trash_id"]
    groups[:] = [e for e in groups if e.get("trash_id") != tid]
    if tid not in skips:
        skips.append(tid)

# Guide groups this stack asks for by name. Recyclarr syncs a group only when a
# profile template asks for it and none of the templates used here do - but a
# group listed with an explicit `select` is pulled in regardless, which is how
# these arrive without adopting a whole language or accessibility template. The
# members are all `required: false`, so the `select` is not optional: added
# without one, Recyclarr accepts the config, reports everything up to date and
# syncs no formats at all.
#
# Members are read from the guide's own json rather than listed as ids, because
# the ids differ per app and a new variant would otherwise be missed silently.
EXTRA_GROUPS = {
    # Every member. An accessibility release carries a narration of what is on
    # screen, or a sign-language inset, *instead of* the normal audio - the file
    # has one audio track and it is the description. Nothing downstream can
    # repair that, and neither app records track titles in its own mediaInfo, so
    # the release title is the only place it is ever stated. The guide scores
    # them all -10000.
    "optional-accessibility": None,
    # "Language: Not Original" and "MULTi" used to be selected here as well.
    # Both are gone deliberately. "Language: Not Original" scores -10000 on any
    # release whose parsed language is not the film's own, which refuses every
    # Dutch-dubbed release there is - measured, 40 of 40 live ones - and those
    # are wanted here. MULTi says only that a release carries several audio
    # tracks, never which, so it was already scored 0 and did nothing. Neither
    # is requested by the profile templates this stack uses, so leaving them out
    # is what the unmodified guide gives. See README "Dutch audio, and why
    # nothing scores for it".
}

for group_file, wanted in EXTRA_GROUPS.items():
    path = guides / "cf-groups" / f"{group_file}.json"
    if not path.is_file():
        raise SystemExit(f"the guide no longer ships the {app} group {group_file!r}")
    import json
    g = json.loads(path.read_text())
    members = g.get("custom_formats") or []
    picks = [c["trash_id"] for c in members if wanted is None or c["name"] in wanted]
    if wanted is not None:
        missing = wanted - {c["name"] for c in members}
        if missing:
            raise SystemExit(f"{app}: {group_file} no longer holds {sorted(missing)}")
    if not picks:
        continue
    # A template may already list the group - Sonarr's do, with no `select`,
    # which syncs none of it because every member is optional. Merge into that
    # entry rather than skipping it on "already seen", or the formats arrive for
    # one app and silently not the other.
    existing = next((e for e in groups if e["trash_id"] == g["trash_id"]), None)
    if existing is None:
        seen.add(g["trash_id"])
        groups.append({"trash_id": g["trash_id"], "exclude": None, "select": picks})
    else:
        have = existing.get("select") or []
        existing["select"] = have + [t for t in picks if t not in have]

merged["media_naming"] = MEDIA_NAMING[app]
merged["quality_profiles"] = profiles
merged["custom_format_groups"] = {"add": groups}
if skips:
    merged["custom_format_groups"]["skip"] = skips

header = (
    "# Written by configure.sh from the TRaSH Guides templates Recyclarr ships:\n"
    f"#   {', '.join(names)}\n"
    '# Put "# keep" on the first line to take this file over; it is then left alone.\n'
)
out = header + yaml.safe_dump({app: {app: merged}}, sort_keys=False, width=100)

if dst.exists() and dst.read_text() == out:
    raise SystemExit(9)
dst.write_text(out)
