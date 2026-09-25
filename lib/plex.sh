# Plex: claim, libraries, playback and account settings.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- Plex helpers
PLEX_PREFS="$CONFIG_ROOT/plex/Library/Application Support/Plex Media Server/Preferences.xml"
plex_token() { sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$PLEX_PREFS" 2>/dev/null; }
# ---------------------------------------------------------------- Plex
# Online Media Sources (Movies & Shows on Plex, Live TV channels, and the
# retired News/Podcasts/Web Shows) are account settings on plex.tv, not server
# settings. Every client home screen fetches those rows from the internet on
# each visit; the family TVs are noticeably quicker without them. "opt_out" on
# the admin account covers the managed Home users too (they cannot change it
# themselves), "opt_out_managed" would keep the sources for the admin only.
plex_online_sources_off() {         # plex_online_sources_off TOKEN
  local token=$1 hdr=(-H "X-Plex-Token: $token" -H "X-Plex-Client-Identifier: media-stack-configure" \
    -H "X-Plex-Product: media-stack" -H "X-Plex-Version: 1" -H "Accept: application/json")
  local uuid url current key changed=0
  uuid=$(curl -fsS -m 15 "${hdr[@]}" https://plex.tv/api/v2/user 2>/dev/null | jq -r '.uuid // empty')
  [[ -n "$uuid" ]] || { echo "   WARN plex.tv did not answer; online media sources left as they are"; return; }
  url="https://plex.tv/api/v2/user/$uuid/settings/opt_outs"
  current=$(curl -fsS -m 15 "${hdr[@]}" "$url" 2>/dev/null) || current='{}'
  for key in vod epg news podcasts webshows; do
    [[ $(jq -r --arg k "tv.plex.provider.$key" '.[$k] // "opt_in"' <<<"$current") == opt_out ]] && continue
    curl -fsS -m 15 -o /dev/null -X POST "${hdr[@]}" "$url?key=tv.plex.provider.$key&value=opt_out" && changed=1
  done
  if (( changed )); then ok "online media sources (Movies & Shows, Live TV channels, News, Podcasts, Web Shows) off for the whole Plex Home"
  else skip "online media sources off"; fi
}

configure_plex() {
  log "Plex"
  local token
  token=$(plex_token)
  if [[ -z "$token" ]]; then
    local claim=${PLEX_CLAIM:-}
    if [[ -z "$claim" && -t 0 ]]; then
      echo "   Server is not claimed. Get a token from https://www.plex.tv/claim (valid 4 minutes)"
      read -r -p "   and paste it here, or press Enter to skip: " claim
    fi
    if [[ -n "$claim" ]]; then
      # Compose prefers the shell environment over .env, and .env was sourced
      # with set -a above - so the new value must be exported, not just written.
      set_env PLEX_CLAIM "$claim"; export PLEX_CLAIM=$claim
      docker compose up -d plex >/dev/null
      printf '   waiting for Plex to claim the server'
      local i
      for i in $(seq 1 40); do token=$(plex_token); [[ -n "$token" ]] && break; printf '.'; sleep 3; done
      echo
      # Single-use token: clear it and recreate once more so it leaves the
      # container's environment as well.
      set_env PLEX_CLAIM ""; export PLEX_CLAIM=""
      docker compose up -d plex >/dev/null
      [[ -n "$token" ]] || die "claim did not complete (token expired? they last 4 minutes); check: docker compose logs plex"
      ok "server claimed (Plex keeps the token in its own config; PLEX_CLAIM cleared)"
    else
      skip "unclaimed - libraries are still created; claim later with PLEX_CLAIM in .env"
    fi
  else
    skip "already claimed"
  fi

  local auth=() sections
  [[ -n "$token" ]] && auth=(-H "X-Plex-Token: $token")
  # -f, so an HTTP error is a failure and the loop keeps trying: a server that
  # has just been claimed rejects its own token with 403 for a few seconds,
  # and without -f the loop took that error page for an answer and went on to
  # create libraries that were refused.
  for i in $(seq 1 20); do
    sections=$(curl -fsS "${auth[@]}" -H 'Accept: application/json' "$PLEX_URL/library/sections" 2>/dev/null) && break; sleep 3
  done

  add_library() {                # add_library NAME TYPE AGENT SCANNER PATH
    if jq -e --arg p "$5" '[.MediaContainer.Directory[]?.Location[]?.path] | index($p) != null' <<<"$sections" >/dev/null; then
      skip "library $1 ($5)"; return
    fi
    curl -fsS "${auth[@]}" -X POST -o /dev/null -G "$PLEX_URL/library/sections" \
      --data-urlencode "name=$1" --data-urlencode "type=$2" --data-urlencode "agent=$3" \
      --data-urlencode "scanner=$4" --data-urlencode "language=en-US" --data-urlencode "location=$5"
    ok "library $1 -> $5"
  }
  add_library "Movies"   movie  tv.plex.agents.movie  "Plex Movie"       /data/media/movies
  add_library "TV Shows" show   tv.plex.agents.series "Plex TV Series"   /data/media/tv
  add_library "Music"    artist tv.plex.agents.music  "Plex Music"       /data/media/music
  if [[ -n "$DUB_CODE" ]]; then
    local dub; dub=$(dub_name "$DUB_CODE")
    add_library "Movies ($dub)"   movie tv.plex.agents.movie  "Plex Movie"     "/data/media/movies-$DUB_CODE"
    add_library "TV Shows ($dub)" show  tv.plex.agents.series "Plex TV Series" "/data/media/tv-$DUB_CODE"
  fi

  # Everything below needs the token, which an unclaimed server does not have.
  # "return" on its own would hand back the failed test's status, and set -e
  # then ends the whole run - silently, right here, on a first install.
  [[ -n "$token" ]] || return 0
  # Per-library preferences (need the token): certification country - a video
  # library setting, music libraries have none.
  local cc=${PLEX_CERTIFICATION_COUNTRY:-US} sid
  sections=$(curl -sS "${auth[@]}" -H 'Accept: application/json' "$PLEX_URL/library/sections")
  for sid in $(jq -r '.MediaContainer.Directory[] | select(.type == "movie" or .type == "show") | .key' <<<"$sections"); do
    curl -fsS -o /dev/null -X PUT "${auth[@]}" "$PLEX_URL/library/sections/$sid/prefs?country=${cc^^}"
  done
  ok "certification country ${cc^^} on the video libraries"
  # Hardware transcoding (Plex Pass): on when the container can see a GPU,
  # i.e. one of the compose.hwaccel.*.yml overrides is active.
  if docker compose exec -T plex sh -c 'ls /dev/dri/renderD* >/dev/null 2>&1 || nvidia-smi -L >/dev/null 2>&1'; then
    curl -fsS -o /dev/null -X PUT -G "${auth[@]}" "$PLEX_URL/:/prefs" \
      --data-urlencode "HardwareAcceleratedCodecs=1" --data-urlencode "HardwareAcceleratedEncoders=1"
    ok "hardware transcoding on (GPU visible in the container)"
  else
    echo "        (no GPU in the Plex container: enable a COMPOSE_FILE override in .env for hardware transcoding)"
  fi
  # Network settings (need the token): advertise the LAN address so clients on
  # the LAN, a routed site or the tailnet connect directly; treat those ranges
  # as LAN (no remote-stream bandwidth caps); optional fixed public port for a
  # router port-forward (PLEX_PUBLIC_PORT), otherwise Plex keeps trying UPnP.
  local mode=0 port=32400
  if [[ -n "${PLEX_PUBLIC_PORT:-}" ]]; then mode=1; port=$PLEX_PUBLIC_PORT; fi
  # On the host network Plex would also publish the Docker bridge addresses
  # (172.17.0.1, 172.18.0.1) as "local" connections; every client then tries
  # and times out on those before finding the real one. Pin the interface
  # that carries LAN_IP.
  local iface
  iface=$(ip -o -4 addr show 2>/dev/null | awk -v ip="$LAN_IP/" 'index($4, ip) == 1 {print $2; exit}')
  curl -fsS -o /dev/null -X PUT -G "${auth[@]}" "$PLEX_URL/:/prefs" \
    --data-urlencode "customConnections=http://$LAN_IP:32400" \
    --data-urlencode "PreferredNetworkInterface=${iface:-}" \
    --data-urlencode "LanNetworksBandwidth=${PLEX_LAN_NETWORKS:-}" \
    --data-urlencode "ManualPortMappingMode=$mode" \
    --data-urlencode "ManualPortMappingPort=$port" \
    --data-urlencode "FSEventLibraryUpdatesEnabled=1" \
    --data-urlencode "FSEventLibraryPartialScanEnabled=1" \
    --data-urlencode "ScheduledLibraryUpdatesEnabled=1" \
    --data-urlencode "ScheduledLibraryUpdateInterval=86400" \
    --data-urlencode "logDebug=0" \
    --data-urlencode "sendCrashReports=0" \
    --data-urlencode "allowMediaDeletion=0" \
    --data-urlencode "GenerateAdMarkerBehavior=never"
  ok "advertises http://$LAN_IP:32400 on ${iface:-any interface}; LAN networks: ${PLEX_LAN_NETWORKS:-(none)}"
  # The file watcher plus the arr import hooks add media within seconds; the
  # scheduled full scan is only a safety net, so once a day is enough. Debug
  # logging rotates 10 MB every few minutes on a busy server; deletion from a
  # Plex client bypasses the arr databases; ad markers exist for DVR
  # recordings, which this stack no longer makes.
  ok "library scans: automatic on change, partial, and a daily full scan"
  ok "debug logging, crash reports, media deletion and ad-marker analysis off"
  if (( mode )); then
    ok "public port $port (forward TCP $port on your internet router to $LAN_IP:32400)"
  else
    echo "        (no PLEX_PUBLIC_PORT in .env: internet access relies on UPnP or Plex relay)"
  fi
  curl -fsS -o /dev/null -X PUT "${auth[@]}" "$PLEX_URL/myplex/refreshReachability" 2>/dev/null || true
  plex_online_sources_off "$token"
  # A DVR still pointing at the retired Threadfin
  # tuner (127.0.0.1:34400) would only produce errors.
  local dvrs stale devkey
  dvrs=$(curl -fsS "${auth[@]}" -H 'Accept: application/json' "$PLEX_URL/livetv/dvrs" 2>/dev/null || echo '{}')
  for stale in $(jq -r '.MediaContainer.Dvr[]? | select(any(.Device[]?; .uri | test("34400"))) | .key' <<<"$dvrs"); do
    for devkey in $(jq -r --arg k "$stale" '.MediaContainer.Dvr[] | select(.key == $k) | .Device[].key' <<<"$dvrs"); do
      curl -fsS -o /dev/null "${auth[@]}" -X DELETE "$PLEX_URL/media/grabbers/devices/$devkey" 2>/dev/null || true
    done
    curl -fsS -o /dev/null "${auth[@]}" -X DELETE "$PLEX_URL/livetv/dvrs/$stale" 2>/dev/null || true
    ok "retired the Threadfin DVR from Plex"
  done
}
