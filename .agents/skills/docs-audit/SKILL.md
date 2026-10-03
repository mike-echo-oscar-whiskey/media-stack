---
name: docs-audit
description: Audit the docs mechanically rather than by reading - the README, AGENTS.md and .env.example against the code they describe, and the README against itself for anchors, chapter order and structure. Use after changing settings, scripts, ports or chapters, after splitting a script, or when the documentation is suspected of having drifted.
---

# Auditing the documentation

Reading the docs and judging them does not work: whoever wrote a line reads it as correct, and
nobody notices the setting that no longer exists. Every check here is a command whose output is the
verdict, and every finding any of them has made was invisible to a careful reader.

They answer two different questions, and the second is the one that gets skipped:

- **Is it true?** — the docs against the code. A setting nothing reads, a command that cannot run.
- **Can it be found?** — the docs against themselves. A chapter nobody can reach, a table in the
  wrong order, a required step written down where nobody goes looking for it.

What neither answers is whether the writing is any good, or whether a chapter earns its length.
That stays a judgement, and **What this does not check** at the end says where to apply it.

Each block below prints nothing when it passes.

## Is it true? — against the code

### Settings documented ↔ settings used

`.env.example` is the template `setup.sh` copies, so a key the code reads but the template lacks is a
key a fresh install will not have.

`config/` is excluded from both directions and has to be: it is app state, holds several hundred
vendored Prowlarr indexer definitions, and adds enough names to the output that a real finding would
be skipped over.

```bash
# read by the code, absent from the template
comm -13 <(grep -oE '^[A-Z_]+=' .env.example | tr -d '=' | sort -u) \
         <(grep -rhoE '\$\{[A-Z_]{3,}[:}]' --include='*.sh' --include='*.yml' \
             --exclude-dir=config --exclude-dir=backups --exclude-dir=.git . |
           grep -oE '[A-Z_]{3,}' | sort -u)
```

Filter the result by hand: a name derived at run time is not a setting and belongs in nobody's
`.env`. Today that is all five of them — `MIN_FILE_MIB` (from `ARCHIVE_MIN_FILE_MIB`),
`JELLYFIN_TOKEN`, `SPOTWEB_KEY`, `SPOTWEB_SPOTS`, and `SUDO_USER`, which the shell sets and the
`scripts/union-*.sh` helpers read. A sixth name appearing is the finding.

```bash
# documented, read by nothing - the worse direction, because a knob that does
# nothing gets believed. Confirm each hit with: grep -rn KEY --exclude-dir=.git .
comm -23 <(grep -oE '^[A-Z_]+=' .env.example | tr -d '=' | sort -u) \
         <(grep -rhoE '[A-Z_]{3,}' --include='*.sh' --include='*.yml' --include='*.py' \
             --exclude-dir=config --exclude-dir=backups --exclude-dir=.git . | sort -u)
```

`{3,}` is what keeps the output readable, and it costs the two-letter keys: `TZ` is used nine times
in `compose.yml` and reports as unread every run. Confirm each hit with `grep -rn KEY` before
believing it.

`.env.example` says every key is documented there, and "present" is not the same as "documented":

```bash
# a key with no comment block above it
python3 - <<'EOF'
import re, pathlib
lines = pathlib.Path('.env.example').read_text().splitlines()
for i, l in enumerate(lines):
    m = re.match(r'^([A-Z_0-9]+)=', l)
    if not m: continue
    j = i - 1                                  # a block of sibling keys shares one comment
    while j >= 0 and re.match(r'^[A-Z_0-9]+=', lines[j]): j -= 1
    if j < 0 or not lines[j].lstrip().startswith('#'): print(m.group(1))
EOF
```

A key the template offers **commented out** is a documented setting too, and `^[A-Z_0-9]+=` cannot
see it: `#COMPOSE_FILE=compose.yml:compose.hwaccel.nvidia.yml` is how the GPU overrides are offered
and `setup.sh` uncomments the right one. Check the commented forms before calling such a key
undocumented:

```bash
grep -nE '^#[A-Z_0-9]+=' .env.example
```

Finally, the live `.env` against the template. Both files are a **discovery surface**: a key you
cannot see is a knob you do not know exists, so a key present in one and not the other is a
finding in either direction — a default in the code does not excuse it:

```bash
comm -13 <(grep -oE '^[A-Z_0-9]+=' .env.example | tr -d '=' | sort -u) \
         <(grep -oE '^[A-Z_0-9]+=' .env         | tr -d '=' | sort -u)   # in .env, not in the template
comm -23 <(grep -oE '^[A-Z_0-9]+=' .env.example | tr -d '=' | sort -u) \
         <(grep -oE '^[A-Z_0-9]+=' .env         | tr -d '=' | sort -u)   # new since this .env was written
```

A key in `.env` that the template never had is the user's own leftover; say so and leave it. A key
the template has and `.env` lacks gets added at its documented default — that is a settings
change, so the `env-settings` skill says what it needs to take effect.

### A documented key must be able to reach the code that reads it

The two checks above compare **names**, and a name can satisfy both while the setting does nothing
at all. `GUARD_DRY_RUN` sat in `.env.example`, documented as the way to see why a grab was refused,
and `scripts/release-guard.sh` read it — so it was neither undocumented nor unread, and every run
of this skill passed it. But the guard runs *inside* the Sonarr and Radarr containers as a Custom
Script, `compose.yml` passed only the two ratio keys through, and the knob was inert for as long as
it existed. That is the skill's own "a knob that does nothing gets believed", one level down.

The rule: a script that runs in a container reads that **container's** environment, not `.env`. So
every key it reads must be listed in the `environment:` of every service that mounts it. Which
scripts those are is readable from how they are referenced — a container-run script is registered
by its absolute container path (`/scripts/release-guard.sh`, in `add_release_guard`), a host script
is invoked as `./scripts/...` and reads `.env` directly. Do not simply take everything under
`scripts/`: the whole directory is bind-mounted for the guard, so the host scripts sitting in it
will each report a dozen keys they never needed from a container.

```bash
python3 - <<'EOF'
import json, re, pathlib, subprocess
cfg = json.loads(subprocess.run(['docker', 'compose', 'config', '--format', 'json'],
                                capture_output=True, text=True).stdout)
template = set(re.findall(r'^#?([A-Z_0-9]+)=', pathlib.Path('.env.example').read_text(), re.M))
# registered by absolute path = runs in a container; "./scripts/..." = runs on the host
registered = set()
for p in list(pathlib.Path('lib').glob('*.sh')) + list(pathlib.Path('.').glob('*.sh')):
    for m in re.findall(r'(?<!\.)(/scripts/[a-z0-9-]+\.sh)', p.read_text()):
        registered.add(m.lstrip('/'))
for rel in sorted(registered):
    s = pathlib.Path(rel)
    if not s.exists(): print(f'registered but absent: {rel}'); continue
    keys = {k for k in re.findall(r'\$\{?([A-Z_][A-Z_0-9]{2,})', s.read_text()) if k in template}
    for name, svc in cfg['services'].items():
        if not any(rel.rsplit('/', 1)[0] in str(v.get('source', ''))
                   for v in svc.get('volumes', [])): continue
        missing = keys - set(svc.get('environment') or {})
        if missing:
            print(f'{rel} runs in {name}, which never receives: {" ".join(sorted(missing))}')
EOF
```

A hit is fixed in `compose.yml`, not in the docs: the documentation was right and the wiring was
missing. Prove the fix the way the repo asks — a green re-run proves nothing about a branch it
skipped, so check the value has actually crossed the boundary rather than that the file looks right:

```bash
docker compose config --format json |
  jq -r '.services.sonarr.environment | to_entries[] | select(.key|startswith("GUARD"))'
docker compose exec sonarr sh -c 'echo "${GUARD_DRY_RUN:-<unset>}"'   # after `up -d`
```

The `exec` is the one that counts, and it only tells the truth after `docker compose up -d` has
recreated the container — a changed `environment:` does not reach a running one.

### Citations

Every `README "chapter"` citation has to name a chapter, and name the whole of it. A one-line grep
gets this wrong twice: it cannot see a citation that wrapped onto the next line, and it accepts a
prefix, so `README "Quality"` passes against `## 8. Quality: profiles, formats and guards` and would
go on passing if that chapter were renamed. Both mistakes were live.

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

### Claims about the code

```bash
# functions AGENTS.md attributes to a lib file are in that file
for p in common.sh:arr common.sh:set_env common.sh:xml_apikey common.sh:add_root_folder \
         arr.sh:set_arr_login jellyfin.sh:jf plex.sh:plex_token recyclarr.sh:recyclarr_profile; do
  f=lib/${p%%:*}; fn=${p##*:}
  grep -qE "^$fn\(\)" "$f" || echo "$fn is not in $f (it is in: $(grep -lE "^$fn\(\)" lib/*.sh))"
done

# every script documented as taking install|status does
for f in heal watch mover news missing update; do
  grep -q 'install)' "$f.sh" && grep -q 'status)' "$f.sh" || echo "$f.sh is missing a subcommand"
done
```

### Commands in the docs must actually run

This is the check that pays for itself. The troubleshooting chapters are read by someone whose stack
is already broken, and a command that cannot work costs them the evening.

```bash
# the namespace trap, which the docs have fallen into twice: qBittorrent,
# Prowlarr and FlareSolverr are in Gluetun's namespace and have no names of
# their own. Any doc addressing them by name is wrong. The second grep drops
# comment lines, because compose.yml explains the trap by quoting the wrong
# form, and a check that flags its own documentation gets ignored.
grep -rnE 'http://(qbittorrent|prowlarr|flaresolverr):' \
  --include='*.md' --include='*.yml' --include='*.sh' --include='*.example' . |
  grep -vE ':[0-9]+:[[:space:]]*#'
```

Then run the commands the troubleshooting chapters give, verbatim, and check the exit codes. A
documented `curl` that 404s is a defect even when the prose around it is right.

### Numbers

Counts rot silently. Derive them rather than trusting them:

```bash
# the container count, in both states - COMPOSE_PROFILES decides which
COMPOSE_PROFILES=        docker compose config --services | wc -l   # 17, the default
COMPOSE_PROFILES=archive docker compose config --services | wc -l   # 18, with the archive tier
grep -c '^[A-Z_0-9]*=' .env.example                                    # any "N settings" claim
grep -inE '\b(fifteen|sixteen|seventeen|eighteen|1[5-9]) (containers|services)\b' README.md AGENTS.md
```

The quickstart said sixteen for two containers' worth of drift, because nothing ever recounted, and
the first line of the README said it again — `grep -i`, or a count that opens a sentence is the one
the check cannot see. A count in prose states the default; the archive chapter explains the
eighteenth.

## Can it be found? — against itself

### Anchors

```bash
# every ](#anchor) resolves to a heading
python3 -c "
import re,pathlib
s=pathlib.Path('README.md').read_text()
h={re.sub(r'[^a-z0-9 -]','',x.lower()).replace(' ','-') for x in re.findall(r'^#{2,3} (.+)\$',s,re.M)}
[print('BROKEN: #'+m) for m in sorted(set(re.findall(r'\]\(#([a-z0-9-]+)\)',s))-h)]"
```

Renumbering chapters breaks inline links that no table of contents covers, which is how one survived.

### Shape

Whether the README *reads* well is not checkable and is not audited here. Four things about its
shape are, and each one is a place where a reader gets lost rather than misled.

```bash
python3 - <<'EOF'
import re, pathlib
lines = pathlib.Path('README.md').read_text().splitlines()
hdr = [(i, l[3:]) for i, l in enumerate(lines) if l.startswith('## ')]
anc = lambda t: re.sub(r'[^a-z0-9 -]', '', t.lower()).replace(' ', '-')

# a long chapter with no internal navigation - every other long one has some
for n, (i, t) in enumerate(hdr):
    end = hdr[n+1][0] if n+1 < len(hdr) else len(lines)
    if end - i > 100 and not any(x.startswith('### ') for x in lines[i:end]):
        print(f'no ### in a {end-i}-line chapter: {t}')

# a chapter the Contents does not list
i = next(i for i, l in enumerate(lines) if l.startswith('## Contents'))
j = next(j for j in range(i+1, len(lines)) if lines[j].startswith('## '))
toc = set(re.findall(r'\]\(#([a-z0-9-]+)\)', '\n'.join(lines[i:j])))
for _, t in hdr:
    if anc(t) not in toc and not t.startswith(('Quickstart', 'How it', 'Contents')):
        print(f'missing from Contents: {t}')

# how much has to be read to reach a running stack
first_ref = next(i for i, l in enumerate(lines) if l.startswith('## 6.'))
print(f'install path: {first_ref} lines of {len(lines)}')
EOF
```

The numbers to compare against: 32 chapters, median 45 lines, longest 201, and 362 lines - under a
fifth of the file - from the top to the end of chapter 5, with a 19-line Quickstart above that for
someone who will not read chapters at all. A median drifting up is the signal that the shape is
going wrong; a single chapter growing is only a prompt to look at that one.

Two chapters are past 170 now - *Quality: profiles, formats and guards* and *The archive tier* -
and both were left that way deliberately. Splitting either renumbers every chapter after it, and
this README is cited from code **by name**, with 65 numbered anchors inside it: the cost of a
renumber is real and the gain is a line count. The answer for a chapter that has outgrown one
screen is `####` headings inside it, which cost nothing and are what the check below actually
looks for. Chapter 23 was the original finding: 128 lines and no subheadings at all.

### Ordering

Where a chapter sits is mostly judgement, but four things about the order are not, and each one is
how an order stops making sense without anyone deciding that it should.

```bash
python3 - <<'EOF'
import re, pathlib
lines = pathlib.Path('README.md').read_text().splitlines()
hdr = [(i, l[3:]) for i, l in enumerate(lines) if l.startswith('## ')]
num = [(i, m.group(1), m.group(2)) for i, t in hdr if (m := re.match(r'([0-9]+)\. (.+)', t))]
anc = lambda t: re.sub(r'[^a-z0-9 -]', '', t.lower()).replace(' ', '-')

# 1. numbering contiguous from 1 - a move that renumbered only one end shows here
got = [int(n) for _, n, _ in num]
if got != list(range(1, len(got) + 1)): print('numbering is not contiguous:', got)

# 2. each anchor's number matches the chapter it points at: a reorder that
#    renumbered the headings and left the links is the classic half-done move
for a in set(re.findall(r'\]\(#([0-9]+-[a-z0-9-]+)\)', '\n'.join(lines))):
    n, rest = a.split('-', 1)
    hit = [x for x in num if x[1] == n and anc(x[2]) == rest]
    if not hit: print(f'anchor #{a} points at no chapter of that number')

# 3. the Contents in the same order, with the same numbers, as the chapters
i = next(i for i, l in enumerate(lines) if l.startswith('## Contents'))
j = next(j for j in range(i + 1, len(lines)) if lines[j].startswith('## '))
toc = re.findall(r'^([0-9]+)\. \[(.+?)\]', '\n'.join(lines[i:j]), re.M)
if toc != [(n, t) for _, n, t in num]: print('Contents and chapters disagree:')
for a, b in zip(toc, [(n, t) for _, n, t in num]):
    if a != b: print(f'   Contents {a}  vs  chapter {b}')

# 4. rows of a numbered table, out of order - the config order table had its
#    fifth step printed between the seventh and the eighth for who knows how long
rows, start = [], None
for k, l in enumerate(lines):
    m = re.match(r'^\| ([0-9]+) \|', l)
    if m: rows.append(int(m.group(1))); start = start or k + 1
    elif rows:
        if rows != sorted(rows): print(f'table near line {start}: rows out of order {rows}')
        rows, start = [], None
EOF
```

Then the one that only suggests: a chapter several **earlier** chapters link forward to is one the
reader keeps needing before it arrives. It is not automatically misplaced - a reference chapter
earns forward links - but it is where to look first.

```bash
python3 - <<'EOF'
import re, pathlib
lines = pathlib.Path('README.md').read_text().splitlines()
hdr = [(i, l[3:]) for i, l in enumerate(lines) if l.startswith('## ')]
anc = lambda t: re.sub(r'[^a-z0-9 -]', '', t.lower()).replace(' ', '-')
at = {anc(t): n for n, (_, t) in enumerate(hdr)}
own, ends = {}, [h[0] for h in hdr[1:]] + [len(lines)]
for n, ((i, t), e) in enumerate(zip(hdr, ends)):
    for k in range(i, e): own[k] = n
for n, (i, t) in enumerate(hdr):
    if t == 'Contents': continue
    fwd = {own[k] for k, l in enumerate(lines)
           for a in re.findall(r'\]\(#([a-z0-9-]+)\)', l)
           if at.get(a) == n and own.get(k, n) < n and hdr[own[k]][1] != 'Contents'}
    if len(fwd) >= 3: print(f'{t}: needed by {len(fwd)} earlier chapters')
EOF
```

One chapter answers that today and is fine as it is: *Torrents through a VPN (Gluetun)*, which the
Quickstart and Prerequisites point at for the one thing you need before you start. A second name
appearing is the finding.

What no check will tell you is whether a chapter is under the right heading in the Contents. Read
the five part headings and ask of each chapter only whether it belongs under the one above it. *The
archive tier* sat under **When something is wrong** for exactly as long as nobody did.

## What counts as a defect

- A setting documented that nothing reads, or read that nothing documents.
- A setting documented *and* read whose value cannot reach the code that reads it. Both name
  checks pass and the knob still does nothing.
- A key in `.env.example` that the live `.env` lacks, or the reverse. Both files are how a
  setting is discovered at all, so a default in the code does not excuse the absence.
- A path, script, function or chapter named that does not exist.
- A command that does not run, or runs and does the wrong thing.
- A number that no longer matches what the code produces.
- Prose that contradicts `AGENTS.md`'s own traps — that has happened, and the traps are right.
- A chapter that cannot be reached, is numbered out of step with its links, or sits under a heading
  that does not describe it.
- A required step documented only somewhere a reader would not go looking. The WireGuard key stops
  `setup.sh` dead and was named in the Quickstart but not in *Prerequisites*.

## What this does not check

Whether it reads well, whether a chapter earns its length, and whether the whole thing is more than
a reader needs. No command decides those and this skill does not pretend to. What it can do is hand
the judgement some numbers: the chapter-length distribution and the install-path figure above say
whether the shape has drifted since anyone last looked, and a chapter past about 170 lines, or a
median creeping up, is the prompt to split rather than keep appending.

Read the Contents' part headings and ask of each chapter only whether it belongs under the one above
it. That question is thirty seconds and it is the one a script cannot ask. Beyond that: prose you
would have phrased differently is not a defect. This is an audit, not a rewrite.

## Finishing

Fix what you find in the same pass, then re-run the block that caught it — a finding reported and
not re-checked is a finding you have only half had. `README.md`, `AGENTS.md` and `.env.example` are
tracked, so the fixes go in the commit like any other change.
