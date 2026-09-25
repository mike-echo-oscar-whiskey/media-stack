"""Works out what each Plex Home user's library access should be.

Reads the family file, plex.tv's Home user list and the server's sharing
records, and prints one line per account for lib/plex.sh to act on:

    put  <shared_id> <section_ids> <name> <library names>
    post <user_id>   <section_ids> <name> <library names>
    keep <name>
    profile <name> <current profile> <rating from the file>

The rule is the same one lib/jellyfin.sh applies: films and series for
everyone, music for the adults. A Home user with no sharing record already sees
every library, so a record is only created when something has to be withheld.

The section ids are plex.tv's own (nine digits), not the server's local keys -
sending the local keys matches nothing and unshares everything.
"""

import json
import os
import pathlib
import sys
import xml.etree.ElementTree as ET

family = json.loads(pathlib.Path(os.environ["PLEX_USERS_FILE"]).read_text())
home = json.loads(pathlib.Path(os.environ["PLEX_HOME_JSON"]).read_text())
shares_xml = pathlib.Path(os.environ["PLEX_SHARES_XML"]).read_text()

try:
    root = ET.fromstring(shares_xml)
except ET.ParseError:
    sys.exit("could not parse the sharing records")

# Every record lists every section, shared or not, so any one of them gives the
# full title -> id map. With no record at all there is nothing to read it from.
sections: dict[str, int] = {}
shared_by_user: dict[str, tuple[str, set[int]]] = {}
for ss in root.iter("SharedServer"):
    ids = set()
    for s in ss.iter("Section"):
        sections[s.get("title")] = int(s.get("id"))
        if s.get("shared") == "1":
            ids.add(int(s.get("id")))
    shared_by_user[ss.get("userID")] = (ss.get("id"), ids)

if not sections:
    sys.exit("no sharing record to read section ids from")

by_name = {u["title"]: u for u in home.get("users", []) if not u.get("admin")}
ADULTS_ONLY = {"Music"}


def wanted(role: str) -> set[int]:
    if role == "child":
        return {i for t, i in sections.items() if t not in ADULTS_ONLY}
    return set(sections.values())


def titles(ids: set[int]) -> str:
    return ", ".join(sorted(t for t, i in sections.items() if i in ids))


for entry in family:
    name = entry.get("name")
    role = entry.get("role")
    if not name or role == "admin":
        continue
    user = by_name.get(name)
    if user is None:          # a Jellyfin-only account, not in Plex Home
        continue
    want = wanted(role)
    record = shared_by_user.get(str(user["id"]))
    ids = ",".join(str(i) for i in sorted(want))
    if record is None:
        # No record means every library, which is already right for an adult.
        if want != set(sections.values()):
            print(f"post {user['id']} {ids} {name}\t{titles(want)}")
        else:
            print(f"keep {name}")
    elif record[1] != want:
        print(f"put {record[0]} {ids} {name}\t{titles(want)}")
    else:
        print(f"keep {name}")
    if role == "child":
        print(f"profile {name} {user.get('restrictionProfile') or 'none'} {entry.get('rating', '?')}")
