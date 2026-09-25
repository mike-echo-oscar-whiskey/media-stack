# Seerr: Plex login, servers, libraries and request defaults.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- Seerr
# Seerr's wizard, end to end. Its first login accepts a Plex auth token; the
# server owner's token is in Plex's own config once the server is claimed.
configure_seerr() {
  log "Seerr"
  local token jar settings
  token=$(plex_token)
  [[ -n "$token" ]] || { skip "waits for the Plex claim (it signs in through Plex)"; return; }
  if jq -e '.public.initialized == true' "$CONFIG_ROOT/seerr/settings.json" >/dev/null 2>&1; then
    skip "already set up"; return
  fi
  jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  seerr() {                       # seerr METHOD PATH [JSON]  (admin session cookie)
    local m=$1 path=$2 body=${3:-}
    if [[ -n "$body" ]]; then curl -fsS -b "$jar" -X "$m" -H 'Content-Type: application/json' --data "$body" "$SEERR_URL/api/v1$path"
    else curl -fsS -b "$jar" -X "$m" "$SEERR_URL/api/v1$path"; fi
  }

  curl -fsS -c "$jar" -H 'Content-Type: application/json' --data "$(jq -cn --arg t "$token" '{authToken:$t}')" \
    "$SEERR_URL/api/v1/auth/plex" >/dev/null || die "Seerr rejected the Plex token"
  ok "signed in as the Plex server owner (admin)"

  # name and machineId are read-only: Seerr fills them in from the server.
  seerr POST /settings/plex "$(jq -cn --arg h "$PLEX_INTERNAL_HOST" '{ip:$h, port:32400, useSsl:false}')" >/dev/null
  local ids
  ids=$(seerr GET '/settings/plex/library?sync=true' | jq -r '[.[] | .id] | join(",")')
  seerr GET "/settings/plex/library?enable=$ids" >/dev/null
  ok "Plex server http://$PLEX_INTERNAL_HOST:32400, libraries enabled"

  # add_seerr_arr KIND HOST PORT APIKEY ROOT EXTRA_JSON WANTED_PROFILE
  add_seerr_arr() {
    local kind=$1 host=$2 port=$3 apikey=$4 root=$5 extra=$6 want=$7 test profile pid pname body current
    current=$(seerr GET "/settings/$kind" | jq -c --arg n "${kind^}" 'first(.[] | select(.name == $n)) // empty')
    if [[ -n "$current" ]]; then
      # configure_seerr only runs its setup on a fresh install, so an existing
      # server is brought in line by configure_seerr_prefs instead.
      skip "${kind^}"; return
    fi
    test=$(seerr POST "/settings/$kind/test" "$(jq -cn --arg h "$host" --argjson p "$port" --arg k "$apikey" \
      '{hostname:$h, port:$p, apiKey:$k, useSsl:false}')")
    profile=$(jq -c --arg want "$want" \
      '(.profiles[] | select(.name == $want)) // .profiles[0]' <<<"$test")
    pid=$(jq -r .id <<<"$profile"); pname=$(jq -r .name <<<"$profile")
    body=$(jq -cn --arg n "${kind^}" --arg h "$host" --argjson p "$port" --arg k "$apikey" \
      --argjson pid "$pid" --arg pname "$pname" --arg root "$root" --argjson extra "$extra" \
      '{name:$n, hostname:$h, port:$p, apiKey:$k, useSsl:false, baseUrl:"",
        activeProfileId:$pid, activeProfileName:$pname, activeDirectory:$root,
        is4k:false, isDefault:true, syncEnabled:false, preventSearch:false, tags:[]} + $extra')
    seerr POST "/settings/$kind" "$body" >/dev/null
    ok "${kind^} http://$host:$port, profile \"$pname\", root $root"
  }
  # Seerr asks Radarr with SEERR_QUALITY_PROFILE (a Radarr profile name, and
  # the default's own name when the key is empty); Sonarr has different profile
  # names, so it follows the default variant on its own side.
  add_seerr_arr radarr radarr 7878 "$(xml_apikey radarr)" /data/media/movies \
    '{"minimumAvailability":"released"}' "$SEERR_QUALITY_PROFILE"
  add_seerr_arr sonarr sonarr 8989 "$(xml_apikey sonarr)" /data/media/tv \
    '{"enableSeasonFolders":true,"animeTags":[]}' "$(recyclarr_profile sonarr "$Q_DEFAULT")"
  add_seerr_dub_servers

  seerr POST /settings/initialize >/dev/null
  ok "setup complete - http://seerr.$SITE_DOMAIN"
}

# A second Seerr entry per app, pointing at the same Radarr/Sonarr but with the
# dubbed profile and folder as its defaults: choosing it under "Destination
# Server" in a request then settles profile and root folder in one go.
# Runs on every pass, so it also appears on a stack set up before DUB_LANGUAGE.
add_seerr_dub_servers() {
  [[ -n "$DUB_CODE" ]] || return 0
  local lang jar
  lang=$(dub_name "$DUB_CODE")
  jq -e '.public.initialized == true' "$CONFIG_ROOT/seerr/settings.json" >/dev/null 2>&1 || return 0
  jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  local token; token=$(plex_token); [[ -n "$token" ]] || return 0
  curl -fsS -c "$jar" -o /dev/null -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg t "$token" '{authToken:$t}')" "$SEERR_URL/api/v1/auth/plex"

  add_one() {                     # add_one KIND HOST PORT APIKEY ROOT PROFILE_URL EXTRA
    local kind=$1 host=$2 port=$3 apikey=$4 root=$5 purl=$6 extra=$7 pid pname body current
    # The dubbed twin of whichever profile is the default (lib/profiles.sh).
    pname="$(recyclarr_profile "$kind" "$Q_DEFAULT") (${DUB_CODE^^}-DUB)"
    pid=$(arr "$apikey" GET "$purl/api/v3/qualityprofile" | jq -r --arg n "$pname" 'first(.[] | select(.name == $n)) | .id // empty')
    [[ -n "$pid" ]] || { echo "        (no \"$pname\" profile in ${kind^} yet)"; return; }
    current=$(curl -fsS -b "$jar" "$SEERR_URL/api/v1/settings/$kind" \
              | jq -c --arg n "${kind^} ($lang)" 'first(.[] | select(.name == $n)) // empty')
    if [[ -n "$current" ]]; then
      # An API key can change (a rotation, a restored config) and the profile
      # follows the default, so both are brought back in line here.
      if [[ "$(jq -r '"\(.apiKey) \(.activeProfileId)"' <<<"$current")" == "$apikey $pid" ]]; then
        skip "Seerr server \"${kind^} ($lang)\""; return
      fi
      curl -fsS -b "$jar" -o /dev/null -X PUT -H 'Content-Type: application/json' \
        --data "$(jq -c --arg k "$apikey" --argjson pid "$pid" --arg pname "$pname" \
                  'del(.id) | .apiKey = $k | .activeProfileId = $pid | .activeProfileName = $pname' <<<"$current")" \
        "$SEERR_URL/api/v1/settings/$kind/$(jq -r .id <<<"$current")"
      ok "Seerr server \"${kind^} ($lang)\" -> $pname (refreshed)"; return
    fi
    body=$(jq -cn --arg n "${kind^} ($lang)" --arg h "$host" --argjson p "$port" --arg k "$apikey" \
      --argjson pid "$pid" --arg pname "$pname" --arg root "$root" --argjson extra "$extra" \
      '{name:$n, hostname:$h, port:$p, apiKey:$k, useSsl:false, baseUrl:"",
        activeProfileId:$pid, activeProfileName:$pname, activeDirectory:$root,
        is4k:false, isDefault:false, syncEnabled:false, preventSearch:false, tags:[]} + $extra')
    curl -fsS -b "$jar" -X POST -H 'Content-Type: application/json' --data "$body" "$SEERR_URL/api/v1/settings/$kind" >/dev/null
    ok "Seerr server \"${kind^} ($lang)\" -> $pname, $root"
  }
  add_one radarr radarr 7878 "$(xml_apikey radarr)" "/data/media/movies-$DUB_CODE" "$RADARR_URL" '{"minimumAvailability":"released"}'
  add_one sonarr sonarr 8989 "$(xml_apikey sonarr)" "/data/media/tv-$DUB_CODE"     "$SONARR_URL" '{"enableSeasonFolders":true,"animeTags":[]}'
}

# Region and language for Seerr's discover pages; applied on every run.
configure_seerr_prefs() {
  jq -e '.public.initialized == true' "$CONFIG_ROOT/seerr/settings.json" >/dev/null 2>&1 || return 0
  local token jar region=${PLEX_CERTIFICATION_COUNTRY:-US}
  token=$(plex_token); [[ -n "$token" ]] || return 0
  jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  curl -fsS -c "$jar" -o /dev/null -H 'Content-Type: application/json' --data "$(jq -cn --arg t "$token" '{authToken:$t}')" "$SEERR_URL/api/v1/auth/plex"
  curl -fsS -b "$jar" -o /dev/null -X POST -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg u "http://seerr.$SITE_DOMAIN" --arg r "${region^^}" \
      '{applicationUrl:$u, region:$r, discoverRegion:$r, streamingRegion:$r, originalLanguage:"", locale:"en"}')" \
    "$SEERR_URL/api/v1/settings/main"
  ok "region ${region^^}, interface and metadata in English, URL http://seerr.$SITE_DOMAIN"
  # The Plex address Seerr talks to follows the stack (host network -> LAN_IP).
  curl -fsS -b "$jar" -o /dev/null -X POST -H 'Content-Type: application/json' \
    --data "$(jq -cn --arg h "$PLEX_INTERNAL_HOST" '{ip:$h, port:32400, useSsl:false}')" "$SEERR_URL/api/v1/settings/plex"
  ok "Plex server http://$PLEX_INTERNAL_HOST:32400"
  # Every GET of /settings/plex/library rewrites the enabled flags from its
  # enable= list (a plain GET disables all), so sync and enable are two calls,
  # and the list is read back from settings.json, never from another GET.
  local ids
  ids=$(curl -fsS -b "$jar" "$SEERR_URL/api/v1/settings/plex/library?sync=true" | jq -r '[.[] | .id] | join(",")')
  curl -fsS -b "$jar" -o /dev/null "$SEERR_URL/api/v1/settings/plex/library?enable=$ids"
  ok "Plex libraries in Seerr: all enabled"
  # New film requests go to the encode profile (README "Quality"); the Dutch
  # server keeps its own profile.
  local srv pid
  srv=$(curl -fsS -b "$jar" "$SEERR_URL/api/v1/settings/radarr" | jq -c 'first(.[] | select(.name == "Radarr")) // empty')
  pid=$(curl -fsS -H "X-Api-Key: $(xml_apikey radarr)" "$RADARR_URL/api/v3/qualityprofile" | jq -r --arg n "$SEERR_QUALITY_PROFILE" 'first(.[] | select(.name == $n)) | .id // empty')
  if [[ -n "$srv" && -n "$pid" ]]; then
    if [[ $(jq -r .activeProfileId <<<"$srv") == "$pid" ]]; then
      skip "Seerr's film requests use \"$SEERR_QUALITY_PROFILE\""
    else
      curl -fsS -b "$jar" -o /dev/null -X PUT -H 'Content-Type: application/json' \
        --data "$(jq -c --argjson p "$pid" --arg n "$SEERR_QUALITY_PROFILE" 'del(.id) | .activeProfileId = $p | .activeProfileName = $n' <<<"$srv")" \
        "$SEERR_URL/api/v1/settings/radarr/$(jq -r .id <<<"$srv")"
      ok "Seerr's film requests use \"$SEERR_QUALITY_PROFILE\""
    fi
  fi
  # An app's API key can change (a rotation, a restored config) and Seerr then
  # refuses every request it sends. configure_seerr only runs its setup on a
  # fresh install, so the keys are checked here, on every pass.
  local kind current want pid
  for kind in radarr sonarr; do
    current=$(curl -fsS -b "$jar" "$SEERR_URL/api/v1/settings/$kind" \
              | jq -c --arg n "${kind^}" 'first(.[] | select(.name == $n)) // empty')
    [[ -n "$current" ]] || continue
    # Seerr asks Radarr with SEERR_QUALITY_PROFILE (a Radarr profile name, and
    # the default variant's own name when the key is empty). Sonarr's profiles
    # are named differently, so it follows the default variant on its side - it
    # used to be handed the Radarr name, find nothing, and settle for "Any".
    if [[ $kind == radarr ]]; then want=$SEERR_QUALITY_PROFILE; else want=$(recyclarr_profile sonarr "$Q_DEFAULT"); fi
    pid=$(arr "$(xml_apikey "$kind")" GET "$([[ $kind == radarr ]] && echo "$RADARR_URL" || echo "$SONARR_URL")/api/v3/qualityprofile" \
          | jq -r --arg n "$want" 'first(.[] | select(.name == $n)) | .id // empty')
    if [[ "$(jq -r .apiKey <<<"$current")" == "$(xml_apikey "$kind")" ]] \
       && [[ -z "$pid" || "$(jq -r .activeProfileId <<<"$current")" == "$pid" ]]; then
      skip "Seerr's ${kind^} API key and profile"
    else
      curl -fsS -b "$jar" -o /dev/null -X PUT -H 'Content-Type: application/json' \
        --data "$(jq -c --arg k "$(xml_apikey "$kind")" --arg n "$want" --arg pid "${pid:-}" \
           'del(.id) | .apiKey = $k
            | if $pid == "" then . else .activeProfileId = ($pid|tonumber) | .activeProfileName = $n end' <<<"$current")" \
        "$SEERR_URL/api/v1/settings/$kind/$(jq -r .id <<<"$current")"
      ok "Seerr's ${kind^} points at \"$want\" with a current API key"
    fi
  done

  # The owner's Plex watchlist becomes requests: Seerr polls it every three
  # minutes with the Plex token it stored at login. Only works for accounts
  # that signed in to Seerr themselves; managed Plex Home users have no
  # e-mail address, cannot be imported and so have no token here.
  local wl
  wl=$(curl -fsS -b "$jar" "$SEERR_URL/api/v1/user/1/settings/main" | jq -r '[.watchlistSyncMovies, .watchlistSyncTv] | map(. == true) | all')
  if [[ $wl == true ]]; then
    skip "owner's Plex watchlist feeds Seerr"
  else
    curl -fsS -b "$jar" -o /dev/null -X POST -H 'Content-Type: application/json' \
      --data '{"watchlistSyncMovies":true,"watchlistSyncTv":true}' "$SEERR_URL/api/v1/user/1/settings/main"
    ok "owner's Plex watchlist feeds Seerr (films and series, checked every three minutes)"
  fi
  add_seerr_dub_servers
}
