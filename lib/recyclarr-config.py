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

# With a dub language set, each profile also folds Bluray into the WEB group at
# the same resolution, so a custom-format score can choose between a Bluray and
# a WEB release instead of the quality rank always deciding. It is written here,
# into Recyclarr's own config, rather than applied to the profile afterwards:
# Recyclarr syncs nightly on CRON_SCHEDULE and reports "N contain quality
# changes" when it puts a hand-merged profile back the way the guide has it.
# Scores are the other way round - reset_unmatched_scores keeps ours, so
# lib/profiles.sh owns those. See README "Dubbed audio (the original language
# plus one more)".
dub_floor = os.environ.get("RECYCLARR_DUB_FLOOR") or ""
guides = cache.parents[2] / "trash-guides" / "git" / "official" / "docs" / "json" / app
guide_profiles = {}
if dub_floor:
    for f in sorted((guides / "quality-profiles").glob("*.json")):
        import json
        d = json.loads(f.read_text())
        if d.get("trash_id"):
            guide_profiles[d["trash_id"]] = d


def fold_bluray_into_web(items):
    """Bluray-<res> joins the "WEB <res>" group beside it, as TRaSH's own
    [French MULTi.VO] profiles do. Returns (items, renames) - renames maps a
    group's old name to its new one, which the cutoff has to follow."""
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
            # The cutoff has to name something in that list. Two ways it can stop
            # doing so, and only the first was handled at first: the cutoff is a
            # quality that got folded *into* a group (Radarr's Bluray-1080p), or
            # it is the group's own name, which the fold renamed (Sonarr cuts off
            # at "WEB 1080p", now "Bluray|WEB 1080p"). Missing the second meant
            # Recyclarr rejected the whole sonarr.yml - silently, reporting only
            # "Found 1 config files" and syncing Radarr alone.
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
            profile["min_upgrade_format_score"] = int(dub_floor)
            # Fail here rather than let Recyclarr drop the file without a word.
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

# Accessibility releases carry a narration or a signer instead of the normal
# audio - "Rick and Morty S01E01 Pilot with Audio Description ...-Kitsune" has
# one audio track and it is the description of what is on screen. Nothing in the
# library can repair that: there is no second track to switch to, and the apps'
# own mediaInfo records neither track titles nor dispositions, so the release
# guard cannot see it on import either. The release title is the only place it
# is ever stated, which is exactly what a custom format reads - and the renamed
# file loses it, which is why the library looks blameless.
#
# The guide ships the group and scores every member -10000. Its formats are all
# optional, so the group has to name them in `select` or adding it does nothing.
# Read rather than listed, because the ids differ per app and a fifth variant
# would otherwise be silently missed.
accessibility = guides / "cf-groups" / "optional-accessibility.json"
if accessibility.is_file():
    import json
    g = json.loads(accessibility.read_text())
    picks = [c["trash_id"] for c in g.get("custom_formats") or []]
    if picks and g.get("trash_id") not in seen:
        seen.add(g["trash_id"])
        groups.append({"trash_id": g["trash_id"], "exclude": None, "select": picks})

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
