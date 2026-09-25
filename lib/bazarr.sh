# Bazarr: Sonarr/Radarr connections, languages and player notifications.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- Bazarr
configure_bazarr() {
  log "Bazarr"
  local key
  # Only the auth: block - the sonarr:/radarr: blocks carry their own apikey lines.
  key=$(sed -n '/^auth:/,/^[^ ]/{s/^ *apikey: *//p}' "$CONFIG_ROOT/bazarr/config/config.yaml" | tr -d "\"'" | head -n1)
  [[ -n "$key" ]] || die "no apikey in $CONFIG_ROOT/bazarr/config/config.yaml yet"
  curl -fsS -H "X-API-KEY: $key" -X POST "$BAZARR_URL/api/system/settings" \
    --data-urlencode 'settings-general-use_sonarr=true' \
    --data-urlencode 'settings-sonarr-ip=sonarr' --data-urlencode 'settings-sonarr-port=8989' \
    --data-urlencode "settings-sonarr-apikey=$(xml_apikey sonarr)" \
    --data-urlencode 'settings-general-use_radarr=true' \
    --data-urlencode 'settings-radarr-ip=radarr' --data-urlencode 'settings-radarr-port=7878' \
    --data-urlencode "settings-radarr-apikey=$(xml_apikey radarr)" \
    --data-urlencode 'settings-auth-type=form' \
    --data-urlencode "settings-auth-username=$WEBUI_USERNAME" \
    --data-urlencode "settings-auth-password=$WEBUI_PASSWORD" >/dev/null
  ok "Sonarr http://sonarr:8989 and Radarr http://radarr:7878 connected"
  ok "Web UI login set (form)"

  # Language profile 1 mirrors SUBTITLE_LANGUAGES on every run (.env is the
  # source of truth for it); profiles you add yourself are left untouched.
  local langs=() code profiles items enabled=() i=0 mine others
  IFS=', ' read -r -a langs <<<"${SUBTITLE_LANGUAGES:-en}"
  for code in "${langs[@]}"; do enabled+=(--data-urlencode "languages-enabled=$code"); done
  items=$(for code in "${langs[@]}"; do i=$((i+1)); jq -cn --argjson id "$i" --arg l "$code" \
    '{id:$id, language:$l, audio_exclude:"False", audio_only_include:"False", hi:"False", forced:"False"}'; done | jq -cs .)
  mine=$(jq -cn --argjson items "$items" --arg name "${langs[*]}" \
    '{profileId:1, name:$name, items:$items, cutoff:null, mustContain:[], mustNotContain:[], originalFormat:false, tag:null}')
  profiles=$(curl -fsS -H "X-API-KEY: $key" "$BAZARR_URL/api/system/languages/profiles")
  others=$(jq -c '[.[] | select(.profileId != 1)]' <<<"$profiles")
  curl -fsS -H "X-API-KEY: $key" -X POST "$BAZARR_URL/api/system/settings" "${enabled[@]}" \
    --data-urlencode "languages-profiles=$(jq -cn --argjson m "$mine" --argjson o "$others" '[$m] + $o')" \
    --data-urlencode 'settings-general-serie_default_enabled=true' --data-urlencode 'settings-general-serie_default_profile=1' \
    --data-urlencode 'settings-general-movie_default_enabled=true' --data-urlencode 'settings-general-movie_default_profile=1' >/dev/null
  ok "language profile \"${langs[*]}\" as default for series and movies"

  # Plex link with the server owner's token (classic method - the OAuth flow
  # needs a browser): refresh the item and set its "added" date after a
  # subtitle download, so Plex shows the new subtitle immediately.
  local token
  token=$(plex_token)
  # Bazarr rewrites its whole plex section from the POST below, and a key left
  # out falls back to the validator default - auth_method's is "apikey". A run
  # that did not send it therefore unlinked an account linked by OAuth, every
  # time, silently. Read it first and send it back as it stands.
  local method
  method=$(curl -fsS -H "X-API-KEY: $key" "$BAZARR_URL/api/system/settings" 2>/dev/null \
           | jq -r '.plex.auth_method // "apikey"' 2>/dev/null)
  [[ "$method" == "oauth" || "$method" == "apikey" ]] || method=apikey
  if [[ -n "$token" ]]; then
    curl -fsS -H "X-API-KEY: $key" -X POST "$BAZARR_URL/api/system/settings" \
      --data-urlencode 'settings-general-use_plex=true' \
      --data-urlencode "settings-plex-auth_method=$method" \
      --data-urlencode "settings-plex-ip=$PLEX_INTERNAL_HOST" --data-urlencode 'settings-plex-port=32400' --data-urlencode 'settings-plex-ssl=false' \
      --data-urlencode 'settings-plex-movie_library=Movies' --data-urlencode 'settings-plex-series_library=TV Shows' \
      --data-urlencode 'settings-plex-update_movie_library=true' --data-urlencode 'settings-plex-update_series_library=true' \
      --data-urlencode 'settings-plex-set_movie_added=true' --data-urlencode 'settings-plex-set_episode_added=true' >/dev/null
    # Only the token method needs the server token stored: handing Bazarr a
    # second credential while the account is linked is how it gets confused.
    [[ "$method" == "oauth" ]] || curl -fsS -H "X-API-KEY: $key" -X POST "$BAZARR_URL/api/plex/apikey" --data-urlencode "apikey=$token" >/dev/null
    if curl -fsS -H "X-API-KEY: $key" -X POST "$BAZARR_URL/api/plex/test-connection" --data-urlencode "uri=http://$PLEX_INTERNAL_HOST:32400" | jq -e '.success == true' >/dev/null; then
      ok "Plex http://$PLEX_INTERNAL_HOST:32400 connected (item refresh + added date after subtitle downloads)"
    else
      printf '   WARN Bazarr could not reach Plex at http://%s:32400 with the owner token\n' "$PLEX_INTERNAL_HOST"
    fi
  else
    echo "        (Plex link is added once the server is claimed)"
  fi
  # Jellyfin link: same purpose, its own API key; the library names match the
  # stack's libraries so the right one is refreshed after a download.
  local jkey
  jkey=$(jellyfin_api_key Bazarr)
  if [[ -n "$jkey" ]]; then
    curl -fsS -H "X-API-KEY: $key" -X POST "$BAZARR_URL/api/system/settings" \
      --data-urlencode 'settings-general-use_jellyfin=true' \
      --data-urlencode 'settings-jellyfin-url=http://jellyfin:8096' --data-urlencode "settings-jellyfin-apikey=$jkey" \
      --data-urlencode 'settings-jellyfin-update_movie_library=true' --data-urlencode 'settings-jellyfin-update_series_library=true' \
      --data-urlencode 'settings-jellyfin-refresh_method=immediate' >/dev/null
    ok "Jellyfin http://jellyfin:8096 connected (library refresh after subtitle downloads)"
  else
    echo "        (Jellyfin link is added once Jellyfin is set up)"
  fi
  link_plex_account "$key"
  add_plex_playback_webhook "$key"
  echo "        (subtitle providers need your accounts: Bazarr > Settings > Providers)"
}

# ------------------------------------------------------------- Plex OAuth link
# The token link above is enough to refresh a library, but Bazarr's newer Plex
# features - its autopulse hand-off among them - check auth_method and do
# nothing unless the account itself is linked:
#
#   auth_method = settings.plex.get('auth_method', 'apikey')
#   if auth_method != 'oauth':   # only proceed if OAuth is configured
#
# That link is Plex's PIN flow, which needs one approval in a browser. Bazarr's
# own endpoints drive it and store what comes back; forging the stored token
# instead would work (TokenManager is itsdangerous signing, not encryption, and
# the key sits in config.yaml) but would tie this repo to Bazarr's internal
# storage format, to break silently on an image update.
link_plex_account() {
  local key=$1 method pin pin_id state auth_url i result
  method=$(curl -fsS -H "X-API-KEY: $key" "$BAZARR_URL/api/system/settings" 2>/dev/null \
           | jq -r '.plex.auth_method // "apikey"' 2>/dev/null)
  if [[ "$method" == "oauth" ]]; then
    skip "Plex account linked (OAuth)"; return 0
  fi
  # No terminal: configure.sh runs with stdin closed in automation, where an
  # approval can never arrive. Say what is missing instead of waiting for it.
  if [[ ! -t 0 ]]; then
    echo "        (Plex account not linked: run ./configure.sh from a terminal to approve the"
    echo "         PIN once - Bazarr needs it for autopulse and its other newer Plex features)"
    return 0
  fi
  pin=$(curl -fsS -H "X-API-KEY: $key" -X POST "$BAZARR_URL/api/plex/oauth/pin" 2>/dev/null) || {
    printf '   WARN could not start the Plex PIN flow\n'; return 0; }
  pin_id=$(jq -r '.data.pinId // empty' <<<"$pin")
  state=$(jq -r '.data.state // empty' <<<"$pin")
  auth_url=$(jq -r '.data.authUrl // empty' <<<"$pin")
  if [[ -z "$pin_id" || -z "$auth_url" ]]; then
    printf '   WARN Plex PIN flow returned nothing usable: %s\n' "$(jq -rc '.error // .' <<<"$pin" | head -c 120)"
    return 0
  fi
  printf '   Approve this once in a browser, then leave it to finish:\n   %s\n' "$auth_url"
  for i in $(seq 1 60); do
    sleep 5
    result=$(curl -fsS -H "X-API-KEY: $key" \
             "$BAZARR_URL/api/plex/oauth/pin/$pin_id/check?state=$(urlenc "$state")" 2>/dev/null) || continue
    if [[ "$(jq -r '.data.authenticated // false' <<<"$result")" == "true" ]]; then
      ok "Plex account linked as $(jq -r '.data.username // "?"' <<<"$result") (OAuth)"
      return 0
    fi
  done
  printf '   WARN the PIN was not approved within five minutes - re-run ./configure.sh to try again\n'
  return 0
}

# --------------------------------------------------- Plex playback webhook
# Plex calls this when something starts playing and Bazarr searches subtitles
# for that item there and then, instead of waiting for its scheduled sweep.
# Registered on the Plex *account*, not the server, so it is left exactly as
# found when it is already there, and any other webhook is preserved.
add_plex_playback_webhook() {
  local key=$1 token url existing payload
  token=$(plex_token)
  if [[ -z "$token" ]]; then
    echo "        (Plex playback webhook is added once the server is claimed)"; return 0
  fi
  # Plex runs on the host network, so loopback reaches Bazarr's published port.
  url="http://127.0.0.1:6767/api/webhooks/plex?apikey=$key"
  existing=$(curl -fsS -H 'Accept: application/json' -H 'X-Plex-Client-Identifier: media-stack-configure' \
             "https://plex.tv/api/v2/user/webhooks?X-Plex-Token=$token" 2>/dev/null) || existing='[]'
  if jq -e --arg u "$url" 'any(.[]?; .url == $u)' <<<"$existing" >/dev/null 2>&1; then
    skip "Plex playback webhook -> Bazarr"; return 0
  fi
  # The endpoint replaces the whole list, so every existing url goes back with it.
  payload=$(jq -r --arg u "$url" '[(.[]?.url), $u] | unique | map("urls[]=" + @uri) | join("&")' <<<"$existing")
  if curl -fsS -o /dev/null -X POST -H 'X-Plex-Client-Identifier: media-stack-configure' \
       --data "$payload" "https://plex.tv/api/v2/user/webhooks?X-Plex-Token=$token" 2>/dev/null; then
    ok "Plex playback webhook -> Bazarr (subtitles searched when playback starts)"
  else
    printf '   WARN could not register the Plex webhook (Plex Pass required)\n'
  fi
}
