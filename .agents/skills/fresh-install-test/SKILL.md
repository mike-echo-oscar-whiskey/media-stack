---
name: fresh-install-test
description: Prove the install path on an empty install without losing the live stack's data — teardown, clone, setup, credentials, configure, verify, restore. Use before claiming a change to setup.sh, configure.sh or lib/ works.
---

# Testing a fresh install

A re-run of `configure.sh` on a configured host proves almost nothing: every step skips. Bugs on
the install path only appear on an empty one — a bare `return` that ended the whole run silently, a
Jellyfin library refused because its directory did not exist yet, a SABnzbd restart racing the
provider step. All three were found this way and none by reading the code.

## What is and is not at risk

The stack keeps nothing in named volumes: `config/` and `data/` are bind mounts under the repo. So
`docker compose down` stops everything and touches no data, and the live stack comes back with
`up -d`. The test uses a **separate clone in its own directory**, which gets its own Compose project
name only if `compose.yml`'s `name:` is absent — it is not, so **both installs share the project
name `media-stack` and cannot run at once**. The live stack must be down for the duration.

Tell the user how long it will be down before starting. Do not start without a clear instruction.

## The sequence

```bash
cd ~/Projects/media-stack && docker compose down          # data untouched
cd ~/Projects && rm -rf arrr-test
git clone -q git@github.com:mike-echo-oscar-whiskey/media-stack.git arrr-test
cd arrr-test
printf '%s\n' 'test.lan' '' 'n' '' '' 'nl,en' 'nl' 'n' "$VPN_KEY" 'Netherlands' '' \
  | script -qec './setup.sh' /dev/null
```

Eleven answers, and the order is load-bearing — check it against `grep -nE 'ask(_secret|_yn)? "'
setup.sh` before trusting this list, because a prompt added in the middle silently shifts every
answer after it:

| # | Prompt | Answer |
|---|---|---|
| 1 | Domain suffix | `test.lan` |
| 2 | Other networks Plex treats as local | *(empty)* |
| 3 | Reach Plex from outside the house? | `n` |
| 4 | Plex claim token | *(empty)* |
| 5 | Locale | *(empty)* |
| 6 | Subtitle languages | `nl,en` |
| 7 | Dubbed audio | `nl` |
| 8 | Do you have a Usenet provider? | `n` — carried afterwards instead |
| 9 | WireGuard private key | `$VPN_KEY` |
| 10 | Countries | `Netherlands` |
| 11 | Weather coordinates | *(empty)* |

Answering `n` to the Usenet question keeps the provider's password off the transcript entirely: the
keys stay empty and the copy script below fills them before the second `configure.sh`.

The VPN key is **required** now: `setup.sh` exits 1 without one and writes no `.env`, so the
sequence has to carry a real key — read it from the live `.env` into `VPN_KEY` in a way that keeps
it off the transcript, never paste it. A run with no PTY cannot work at all any more, because
`ask_secret` returns empty when it is not interactive, which is now fatal.

Feeding answers on stdin works, but note that `script` allocates a PTY, which
makes `configure.sh` *prompt* for a Web UI login instead of generating one. Run `configure.sh`
without a PTY and with stdin closed:

```bash
./configure.sh < /dev/null
```

Copy the provider credentials across **without letting a value reach the transcript** — a script
reads them and prints only a verdict:

```python
# carry USENET_* and VPN_WIREGUARD_PRIVATE_KEY / VPN_SERVER_COUNTRIES from the live .env
# print "ok  KEY: carried over (N characters)" and never the value
```

`setup.sh` sets `COMPOSE_FILE` itself when it finds a GPU at `/dev/dri`, so that no longer needs
doing by hand. Then `docker compose up -d` and `./configure.sh < /dev/null` again.

## What to verify

- **17** containers healthy — count it from `docker compose config --services`, not from memory;
  this number has been wrong in these notes twice
- `rclone` is **not** among them: the archive tier is behind the `archive` compose profile and
  `COMPOSE_PROFILES` is empty on a fresh install. Its absence is a pass, not a failure
- `configure.sh` exits 0, and a **second** run reports mostly `kept` — the `ok` lines that remain
  are statements rather than changes ("all healthy", "torrent traffic exits as …", the rate caps)
- the first run may warn `no forwarded port yet`: Gluetun is still negotiating NAT-PMP. It clears
  by the second run, and a warning that survives the second run is the real thing
- the VPN: exit IP differs from the host's own, and the forwarded port is adopted by qBittorrent
- the Usenet provider: SABnzbd's own test endpoint answers `Connection Successful!` — build the
  request from `.env` in a script so the password never appears
- with a claim token: Plex claims, and the libraries are created afterwards

## Restoring

```bash
cd ~/Projects/arrr-test && docker compose down
cd ~/Projects && rm -rf arrr-test
cd ~/Projects/media-stack && docker compose up -d
./configure.sh < /dev/null      # expect 15 healthy, all kept, exit 0
```

Check the live stack is genuinely back — 15 healthy, `configure.sh` clean — and say so explicitly.
A test that ends without that check is not finished.

## Two things that will bite

**Secrets.** Never print `.env`, `config/*/config.xml`, `services.yaml`, Seerr's `settings.json` or
the Recyclarr configs, in either install. Verify by comparison, by length, or through the app's own
test endpoint.

**Plex.** A throwaway server claimed with a real token appears in the owner's Plex account under
Settings → Devices and stays there. Mention it so they can remove it.
