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
    # One member. The guides own "Language: Not Original" - a negated
    # LanguageSpecification on "Original", scored -10000 - and this stack used to
    # rebuild it by hand in lib/profiles.sh for want of a template that asks for
    # it. The rest of the group is German and French profiles that do not apply.
    "optional-language-profiles": {"Language: Not Original"},
    # One member. MULTi says a release carries several audio tracks without
    # saying which, so the guides never score it alone - they AND it with a
    # language check. lib/profiles.sh scores it the same as the dub, on the
    # reasoning that a full-disc rip is often the only way a dubbed version is
    # offered at all, and that scoring it *above* the dub would trade a release
    # that names the language for one that merely might carry it.
    "optional-miscellaneous": {"MULTi"},
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
