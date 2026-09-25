# The archive tier: an encrypted folder at a cloud provider, mounted at
# /data/archive by
# the rclone container, carried by Sonarr and Radarr as a second root folder and
# by Plex and Jellyfin as a second library path.
# Sourced by configure.sh, which loads .env, defines the URL constants and the
# log/ok/skip/die helpers.
#
# What this section does NOT do is create the remote. The OAuth consent flow
# needs a browser, and the encryption password must never be generated or stored
# by a script: there is no reset, so a lost password is lost data and it belongs
# in a password manager rather than in .env. Until config/rclone/rclone.conf
# holds a working "media" remote this section reports that and changes nothing,
# the way configure_spotweb waits for the first spots.

RCLONE_CONF=$CONFIG_ROOT/rclone/rclone.conf

# rc ARGS... - rclone from inside its own container, so the host needs no rclone
# installed and the config is read where it already lives.
rc() { docker compose exec -T rclone rclone "$@" 2>/dev/null; }

# Never print rclone.conf: it holds the obscured crypt passwords and the provider
# credentials. Only presence is ever checked, and only non-secret fields - the
# backend type and which remote the crypt wraps - are ever read out.
# True when the pattern is there, and true when the file cannot be read - which
# is not the same claim, but it is the safe one here. rclone runs as root and
# rewrites this file on every Drive token refresh, so it returns to root-owned
# 0600 however often it is chowned; grep then exits 2 for "permission denied",
# and reading that as "no such remote" makes configure.sh skip the whole archive
# section on a stack whose archive is mounted and working. Same fault as
# archive_enabled in lib/alerts.sh, same answer: never let "cannot tell" take
# the branch meant for "no".
rclone_conf_has() {
  [[ -r "$RCLONE_CONF" ]] || { [[ -s "$RCLONE_CONF" ]]; return; }
  grep -q "^$1" "$RCLONE_CONF" 2>/dev/null
}

# rclone_conf_field SECTION KEY - one non-secret value from rclone.conf.
# Never call this for a password, token or key.
rclone_conf_field() {
  local prog='
    $0 == want { f = 1; next }
    /^\[/      { f = 0 }
    f && $0 ~ "^" k " *=" { sub("^" k " *= *", ""); print; exit }'
  if [[ -r "$RCLONE_CONF" ]]; then
    awk -v want="[$1]" -v k="$2" "$prog" "$RCLONE_CONF" 2>/dev/null
    return 0
  fi
  # Unreadable on the host - rclone rewrites this file as root on every token
  # refresh - so ask the container that owns it instead. The provider's name is
  # what decides whether the Drive-only advice below applies at all, and without
  # it those checks are skipped silently rather than reported.
  docker compose ps --services --status running 2>/dev/null | grep -qx rclone || return 0
  docker compose exec -T rclone awk -v want="[$1]" -v k="$2" "$prog" /config/rclone/rclone.conf </dev/null 2>/dev/null
  return 0
}

# The provider behind the crypt layer. "media:" is the only name the stack ever
# mounts - compose, configure.sh and mover.sh all address that - so swapping
# Google Drive for a Hetzner Storage Box, or anything else rclone speaks, is a
# change to rclone.conf alone and to nothing in this repo.
archive_backend() {
  local base
  base=$(rclone_conf_field media remote)
  [[ -n "$base" ]] || return 0
  rclone_conf_field "${base%%:*}" type
}

configure_rclone() {
  log "Archive tier"

  if [[ ! -s "$RCLONE_CONF" ]] || ! rclone_conf_has '\[media\]'; then
    skip "no archive configured"
    echo "        (one-time setup by hand - see README \"The archive tier\")"
    return 0
  fi
  # Configured but switched off is a different thing from configured and broken,
  # and the fix is different too.
  if ! docker compose config --services 2>/dev/null | grep -qx rclone; then
    skip "archive configured but the profile is off"
    echo "        (set COMPOSE_PROFILES=archive in .env, then: docker compose up -d)"
    return 0
  fi
  if ! docker compose ps --services --status running 2>/dev/null | grep -qx rclone; then
    skip "rclone container not running"
    echo "        (docker compose up -d rclone)"
    return 0
  fi

  # The remote answering is the only proof that the token and the password are
  # both right; a wrong password fails here rather than at the first upload.
  if ! rc lsd media: --max-depth 1 >/dev/null; then
    printf '   WARN the media: remote does not answer - check: docker compose logs rclone\n'
    return 0
  fi
  ok "media: answers"

  # Provider-specific advice, and only where it applies: the two Drive settings
  # below mean nothing on an SFTP box and would read as spurious warnings there.
  local backend; backend=$(archive_backend)
  ok "provider: ${backend:-unknown}"
  case "$backend" in
    drive)
      if rclone_conf_has 'root_folder_id'; then
        skip "token scoped to the archive folder"
      else
        printf '   WARN no root_folder_id on the drive remote: the token can reach the whole Drive\n'
      fi
      if rclone_conf_has 'use_trash = false'; then
        skip "deletes bypass Drive's trash"
      else
        printf '   WARN use_trash is not false: deleted files keep counting against the quota\n'
      fi
      ;;
    sftp)
      # A Storage Box has no quota games and no daily caps; the thing worth
      # saying is that a password in the config is worse than a key.
      if rclone_conf_has 'key_file'; then
        skip "authenticates with an SSH key"
      else
        printf '   NOTE the sftp remote has no key_file: a key is better than a stored password\n'
      fi
      ;;
  esac

  # The apps no longer see the cloud separately: /data/media is the union, and a
  # title reads from whichever branch holds it. What has to be true inside each
  # app is that /data/media really is the union and not the bare local directory,
  # because the bare directory looks identical and is quietly missing everything
  # that was archived.
  local seen=0 c
  for c in sonarr radarr lidarr; do
    docker compose exec -T "$c" sh -c 'stat -f -c %T /data/media 2>/dev/null | grep -q fuse' \
      && seen=$(( seen + 1 ))
  done
  if (( seen == 3 )); then
    ok "/data/media is the union in Sonarr, Radarr and Lidarr"
  else
    printf '   WARN /data/media is not the union in %s of 3 apps - the archived half of the\n' "$(( 3 - seen ))"
    printf '        library is invisible to them. Check: systemctl status media-stack-union\n'
    printf '        then: docker compose up -d sonarr radarr lidarr\n'
    return 0
  fi

  # No archive root folders any more. A library has exactly one root folder,
  # /data/media/<lib>, added by lib/arr.sh; which branch a title physically sits
  # on is the union's business and the apps are deliberately unaware of it.

  configure_archive_libraries
  echo "        (mover.sh keeps ${ARCHIVE_REMOTE_PERCENT:-0}% of the library here, and moves more below ${DISK_WARN_GIB:-0} GiB free)"
  return 0
}

# With the union there is one path per library, and /data/archive does not exist
# inside Plex, Jellyfin or Bazarr any more. A stack that ran the old layout still
# has the second location recorded, pointing at nothing - so this removes it
# rather than adding it, and converges to a single path on every run.
configure_archive_libraries() {
  log "Library paths"
  local token sections id title changed=0 kept=0

  # Plex will not be told. PUT /library/sections/<id> answers 400 to every shape
  # tried - location alone, location with the section's own name, type, agent,
  # scanner and language, and with a client identifier - so the stale path is
  # reported rather than removed, and the one manual step is named. Jellyfin
  # below has a real endpoint for it and is handled properly.
  token=$(plex_token)
  if [[ -z "$token" ]]; then
    skip "Plex library paths (server not claimed yet)"
  else
    sections=$(curl -fsS -H "X-Plex-Token: $token" -H 'Accept: application/json' \
               "$PLEX_URL/library/sections" 2>/dev/null) || sections=''
    local stale
    stale=$(jq -r '[.MediaContainer.Directory[]? | select(any(.Location[]?; .path | startswith("/data/archive"))) | .title] | join(", ")' <<<"$sections" 2>/dev/null)
    if [[ -n "$stale" && "$stale" != "null" ]]; then
      printf '   WARN Plex still lists /data/archive on: %s\n' "$stale"
      printf '        That path is gone from the container, so anything Plex recorded under it is\n'
      printf '        unplayable until a scan relinks it. Plex has no API to drop a library path:\n'
      printf '        Settings > Libraries > Edit > remove the /data/archive folder, then scan.\n'
    else
      skip "Plex library paths"
    fi
  fi

  [[ -n "${JELLYFIN_TOKEN:-}" ]] || { skip "Jellyfin library paths (no token this run)"; return 0; }
  local folders name
  folders=$(jf GET /Library/VirtualFolders) || folders='[]'
  changed=0
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local path
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      jf DELETE "/Library/VirtualFolders/Paths?name=$(urlenc "$name")&path=$(urlenc "$path")" >/dev/null \
        && { ok "Jellyfin $name: removed $path"; changed=1; } \
        || printf '   WARN could not remove %s from Jellyfin %s\n' "$path" "$name"
    done < <(jq -r --arg n "$name" '.[] | select(.Name == $n) | .Locations[]? | select(startswith("/data/archive"))' <<<"$folders")
  done < <(jq -r '.[] | select(any(.Locations[]?; startswith("/data/archive"))) | .Name' <<<"$folders")
  (( changed )) || skip "Jellyfin library paths"
  return 0
}
