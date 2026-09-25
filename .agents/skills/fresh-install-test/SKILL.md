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
printf '%s\n' 'test.lan' '' 'n' '' '' 'nl,en' 'nl' "$VPN_KEY" '' '' | script -qec './setup.sh' /dev/null
```

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

Then `COMPOSE_FILE=compose.yml:compose.hwaccel.amd.yml` in the test `.env`,
`docker compose up -d`, and `./configure.sh < /dev/null` again.

## What to verify

- 15 containers healthy
- `configure.sh` exits 0, and a **second** run reports only `kept`
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
