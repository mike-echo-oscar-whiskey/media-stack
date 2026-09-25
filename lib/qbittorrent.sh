# qBittorrent and the VPN it runs behind.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- qBittorrent
configure_qbittorrent() {
  log "qBittorrent"
  local user=$WEBUI_USERNAME pass=$WEBUI_PASSWORD jar
  jar=$(mktemp); trap 'rm -f "$jar"' RETURN

  # Success is 200 "Ok." on older versions and 204 on current ones; failure is 401.
  qbt_login() {
    local code
    code=$(curl -sS -c "$jar" -o /dev/null -w '%{http_code}' \
           --data-urlencode "username=$1" --data-urlencode "password=$2" "$QBT_URL/api/v2/auth/login")
    [[ "$code" == 200 || "$code" == 204 ]]
  }

  if qbt_login "$user" "$pass"; then
    skip "login with the credentials from .env"
  else
    # The temporary password belongs to whatever username qBittorrent has
    # stored (the previous WEBUI_USERNAME), not necessarily "admin".
    local temp admin
    temp=$(docker compose logs --no-log-prefix qbittorrent 2>/dev/null \
           | sed -n 's/.*temporary password is provided for this session: \([^ ]*\).*/\1/p' | tail -n1)
    admin=$(docker compose logs --no-log-prefix qbittorrent 2>/dev/null \
            | sed -n 's/.*WebUI administrator username is: \([^ ]*\).*/\1/p' | tail -n1)
    if [[ -z "$temp" ]] || ! qbt_login "${admin:-admin}" "$temp"; then
      # .env and qBittorrent disagree (login changed on either side). .env is the
      # source of truth: drop the stored hash while stopped, qBittorrent then
      # issues a fresh temporary password on start.
      echo "   .env login not accepted - resetting qBittorrent's stored password"
      docker compose stop qbittorrent >/dev/null 2>&1
      sed -i '/^WebUI\\Password_PBKDF2=/d' "$CONFIG_ROOT/qbittorrent/qBittorrent/qBittorrent.conf"
      docker compose start qbittorrent >/dev/null 2>&1
      local i
      for i in $(seq 1 30); do
        temp=$(docker compose logs --no-log-prefix --since 1m qbittorrent 2>/dev/null \
               | sed -n 's/.*temporary password is provided for this session: \([^ ]*\).*/\1/p' | tail -n1)
        admin=$(docker compose logs --no-log-prefix --since 1m qbittorrent 2>/dev/null \
                | sed -n 's/.*WebUI administrator username is: \([^ ]*\).*/\1/p' | tail -n1)
        [[ -n "$temp" ]] && curl -fsS -o /dev/null "$QBT_URL/" 2>/dev/null && break
        sleep 2
      done
      [[ -n "$temp" ]] || die "no temporary password after the reset; check: docker compose logs qbittorrent"
      qbt_login "${admin:-admin}" "$temp" || die "temporary password from the log was rejected"
    fi
    curl -fsS -b "$jar" "$QBT_URL/api/v2/app/setPreferences" \
      --data-urlencode "json=$(jq -cn --arg u "$user" --arg p "$pass" '{web_ui_username:$u, web_ui_password:$p}')" >/dev/null
    qbt_login "$user" "$pass" || die "new credentials do not work"
    ok "Web UI login set"
  fi

  # Caps are KiB/s, the unit qBittorrent itself rounds to: bytes = KiB x 1024
  # is exact, so what lands is what was asked for. Mbit/s would not be - a line
  # rate is decimal (1 Mbit/s = 125000 B/s) and 100 Mbit/s is 12207.03 KiB, so
  # it stored 32 B/s short. To convert: KiB = Mbit x 125000 / 1024, or roughly
  # Mbit x 122.07.
  local ratio=${TORRENT_SEED_RATIO:-0} days=${TORRENT_SEED_DAYS:-0} kib=${TORRENT_MAX_KIB:-0} upkib=${TORRENT_UPLOAD_MAX_KIB:-0}
  # These go straight into shell arithmetic and into jq, where a typo would
  # end the run with an arithmetic or parse error instead of a clear message.
  [[ "$ratio"  =~ ^[0-9]+([.][0-9]+)?$ ]] || die "TORRENT_SEED_RATIO must be a number (got \"$ratio\")"
  [[ "$days"   =~ ^[0-9]+$ ]] || die "TORRENT_SEED_DAYS must be a whole number of days (got \"$days\")"
  [[ "$kib"   =~ ^[0-9]+$ ]] || die "TORRENT_MAX_KIB must be a whole number of KiB/s (got \"$kib\")"
  [[ "$upkib" =~ ^[0-9]+$ ]] || die "TORRENT_UPLOAD_MAX_KIB must be a whole number of KiB/s (got \"$upkib\")"
  # The unrestricted window is qBittorrent's alternative-limit schedule with
  # both alternative limits at 0 (= no limit).
  local sched='{scheduler_enabled: false}' win
  if win=$(unrestricted_window); then
    set -- $win
    sched=$(jq -cn --argjson fh "$1" --argjson fm "$2" --argjson th "$3" --argjson tm "$4" \
      '{scheduler_enabled: true, schedule_from_hour: $fh, schedule_from_min: $fm, schedule_to_hour: $th, schedule_to_min: $tm,
        scheduler_days: 0, alt_dl_limit: 0, alt_up_limit: 0}')
  fi
  # In VPN mode the listening port is whatever the provider forwards: Gluetun
  # sets it (and the tunnel interface) through the API from inside the shared
  # network namespace, which is why localhost may skip the login there.
  curl -fsS -b "$jar" "$QBT_URL/api/v2/app/setPreferences" --data-urlencode "json=$(jq -cn \
      --argjson ratio "$ratio" --argjson minutes "$(( days * 1440 ))" \
      --argjson dl "$(( kib * 1024 ))" --argjson up "$(( upkib * 1024 ))" --argjson sched "$sched" '{
      save_path: "/data/torrents",
      dl_limit: $dl, up_limit: $up,
      temp_path: "/data/torrents/incomplete", temp_path_enabled: true,
      incomplete_files_ext: true,
      upnp: false, random_port: false,
      bypass_local_auth: true,
      max_ratio_enabled: ($ratio > 0), max_ratio: (if $ratio > 0 then $ratio else -1 end),
      max_seeding_time_enabled: ($minutes > 0), max_seeding_time: (if $minutes > 0 then $minutes else -1 end),
      max_ratio_act: 0 }
      + $sched')" >/dev/null
  ok "save path /data/torrents, incomplete /data/torrents/incomplete (.!qB), UPnP off; port set by Gluetun"
  # Both units, because the setting is exact in KiB and the line is sold in Mbit.
  local dltxt=unlimited uptxt=unlimited
  (( kib   > 0 )) && dltxt="$kib KiB/s ($(( (kib * 1024 * 8 + 500000) / 1000000 )) Mbit/s)"
  (( upkib > 0 )) && uptxt="$upkib KiB/s ($(( (upkib * 1024 * 8 + 500000) / 1000000 )) Mbit/s)"
  ok "download $dltxt, upload $uptxt, unrestricted ${UNRESTRICTED_HOURS:-never}"
  local span="${days} days"
  if (( days == 1 )); then span="24 hours"; fi
  ok "seeding stops (pause) at ratio ${ratio} or after ${span}; Sonarr/Radarr then remove the torrent"

  # A torrent can carry its own share limit, set when it was added; it then
  # ignores the two values above. .env is the single source of truth, so put
  # such a torrent back on the global limit. shareLimitAction is a required
  # parameter from qBittorrent 5.1 on.
  local stamped
  stamped=$(curl -fsS -b "$jar" "$QBT_URL/api/v2/torrents/info" \
            | jq -r '.[] | select(.ratio_limit != -2 or .seeding_time_limit != -2) | .hash')
  if [[ -n "$stamped" ]]; then
    curl -fsS -b "$jar" -X POST "$QBT_URL/api/v2/torrents/setShareLimits" \
      --data-urlencode "hashes=$(tr '\n' '|' <<<"$stamped")" --data-urlencode "ratioLimit=-2" \
      --data-urlencode "seedingTimeLimit=-2" --data-urlencode "inactiveSeedingTimeLimit=-2" \
      --data-urlencode "shareLimitAction=Default" >/dev/null
    ok "$(wc -l <<<"$stamped") torrent(s) had their own limit - back on the global one"
  fi

  local cats cat
  cats=$(curl -fsS -b "$jar" "$QBT_URL/api/v2/torrents/categories")
  for cat in tv movies music prowlarr; do
    if jq -e --arg c "$cat" 'has($c)' <<<"$cats" >/dev/null; then
      curl -fsS -b "$jar" "$QBT_URL/api/v2/torrents/editCategory" --data-urlencode "category=$cat" --data-urlencode "savePath=/data/torrents/$cat" >/dev/null
      skip "category $cat -> /data/torrents/$cat"
    else
      curl -fsS -b "$jar" "$QBT_URL/api/v2/torrents/createCategory" --data-urlencode "category=$cat" --data-urlencode "savePath=/data/torrents/$cat" >/dev/null
      ok "category $cat -> /data/torrents/$cat"
    fi
  done
}

# ---------------------------------------------------------------- VPN
# Gluetun's control server (:8000, only inside the shared namespace) answers
# two read-only routes without a login - see gluetun/auth.toml.
check_vpn() {
  log "VPN (Gluetun)"
  [[ -n "${VPN_WIREGUARD_PRIVATE_KEY:-}" ]] || die "VPN_WIREGUARD_PRIVATE_KEY is empty - this stack does not run without the tunnel"
  local ip fwd port jar
  ip=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8000/v1/publicip/ip 2>/dev/null | jq -r '"\(.public_ip) (\(.country // "?"), \(.organization // .city // "?"))"' 2>/dev/null || true)
  fwd=$(docker compose exec -T qbittorrent curl -fsS -m 10 http://localhost:8000/v1/portforward 2>/dev/null | jq -r '.port // 0' 2>/dev/null || echo 0)
  jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  curl -sS -c "$jar" -o /dev/null --data-urlencode "username=$WEBUI_USERNAME" --data-urlencode "password=$WEBUI_PASSWORD" "$QBT_URL/api/v2/auth/login"
  port=$(curl -fsS -b "$jar" "$QBT_URL/api/v2/app/preferences" | jq -r '.listen_port')
  [[ -n "$ip" ]] && ok "torrent traffic exits as $ip" || echo "   WARN could not read the VPN exit address (docker compose logs gluetun)"
  if [[ "$fwd" != 0 && "$fwd" != "$port" ]]; then
    # Gluetun's own hook runs before this script has allowed localhost past
    # the login on a first start; apply the port here, the hook covers later
    # reconnections. qBittorrent must then restart: a listening port changed
    # at runtime leaves its DHT with zero nodes until the next start, and
    # without DHT a torrent only ever sees the peers its tracker hands out.
    curl -fsS -b "$jar" "$QBT_URL/api/v2/app/setPreferences" \
      --data-urlencode "json=$(jq -cn --argjson p "$fwd" '{listen_port:$p}')" >/dev/null
    docker compose restart qbittorrent >/dev/null 2>&1
    local i
    for i in $(seq 1 40); do curl -fsS -o /dev/null "$QBT_URL/" 2>/dev/null && break; sleep 3; done
    ok "listening port set to $fwd and qBittorrent restarted (DHT re-bootstraps)"
    port=$fwd
  fi
  if [[ "$fwd" != 0 && "$fwd" == "$port" ]]; then
    ok "forwarded port $fwd, qBittorrent listens on it (incoming peers work without a router forward)"
  else
    echo "   WARN no forwarded port yet (Gluetun still connecting, or the WireGuard config was generated without NAT-PMP)"
  fi
}
