"""Writes one Recyclarr config file per app, merged from the guide's templates.

Called by lib/recyclarr.sh with everything in the environment. Exits 9 when the
file is already what it should be, so the caller can report "kept".

Why one file with one instance per app: Recyclarr groups instances by base_url
and silently does nothing when several of them point at the same server, so the
four templates cannot each be their own instance. They are merged instead - four
quality profiles and the union of the custom-format groups, in one instance.
"""

import os
import pathlib
import yaml

app = os.environ["RECYCLARR_APP"]
cache = pathlib.Path(os.environ["RECYCLARR_CACHE"])
names = os.environ["RECYCLARR_TEMPLATES"].split()
dst = pathlib.Path(os.environ["RECYCLARR_DST"])

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
        profiles.append(profile)
    formats = section.get("custom_format_groups") or {}
    for group in formats.get("add") or []:
        if group["trash_id"] not in seen:
            seen.add(group["trash_id"])
            groups.append(group)
    for group in formats.get("skip") or []:
        skips.append(group)

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
