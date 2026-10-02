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

import datetime
import json
import os
import pathlib
import sys
import xml.etree.ElementTree as ET


def rating_for(entry):
    """The Kijkwijzer step this user has reached today.

    Mirrors rating_for in lib/common.sh: an explicit `rating` wins, otherwise
    `born` (YYYY-MM-DD) is turned into the highest step they are old enough for,
    so the number moves on its own as they grow instead of going stale.
    """
    if entry.get("rating") not in (None, ""):
        return entry["rating"]
    born = entry.get("born")
    if not born:
        return "?"
    try:
        b = datetime.date.fromisoformat(born)
    except ValueError:
        return "?"
    today = datetime.date.today()
    age = today.year - b.year - ((today.month, today.day) < (b.month, b.day))
    return next((s for s in (18, 16, 14, 12, 9, 6) if age >= s), 0)

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


def wanted(role: str, music: bool = False) -> set[int]:
    # Music is withheld from a child by library rather than by rating, because
    # tracks carry no age rating at all - so no rating can grant it back and
    # `music: true` on the entry is the only way to give it to an older child.
    if role == "child" and not music:
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
    want = wanted(role, entry.get("music") is True)
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
        print(f"profile {name} {user.get('restrictionProfile') or 'none'} {rating_for(entry)}")
