# Prowlarr: the applications it syncs to and the download clients it hands to.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- Prowlarr
configure_prowlarr() {
  log "Prowlarr"
  local key existing schema
  local PROWLARR_MOVED=0        # set when an application's Prowlarr address changes
  key=$(xml_apikey prowlarr)
  [[ -n "$key" ]] || die "no ApiKey in $CONFIG_ROOT/prowlarr/config.xml yet"
  set_arr_login "$key" "$PROWLARR_URL" v1
  configure_ui_dates "$key" "$PROWLARR_URL" v1
  existing=$(arr "$key" GET "$PROWLARR_URL/api/v1/applications")
  schema=$(arr "$key" GET "$PROWLARR_URL/api/v1/applications/schema")

  add_app() {                    # add_app IMPLEMENTATION BASEURL APIKEY
    local impl=$1 base=$2 appkey=$3 body current id
    current=$(jq -c --arg n "$impl" 'first(.[] | select(.name == $n)) // empty' <<<"$existing")
    if [[ -n "$current" ]]; then
      # Prowlarr masks a stored API key as "****" on read, so the only way to
      # know whether it still works is to ask it: the test endpoint uses the
      # stored key. A stale one makes the indexer sync fail silently.
      if arr "$key" POST "$PROWLARR_URL/api/v1/applications/test" "$current" >/dev/null 2>&1; then
        skip "application $impl"; return
      fi
      id=$(jq -r .id <<<"$current")
      # prowlarrUrl too, not just the key: it is what Prowlarr writes into the
      # app's indexers, and that name is Gluetun's, not Prowlarr's own.
      [[ "$(jq -r '.fields[] | select(.name == "prowlarrUrl") | .value' <<<"$current")" == "$PROWLARR_INTERNAL" ]] || PROWLARR_MOVED=1
      arr "$key" PUT "$PROWLARR_URL/api/v1/applications/$id" \
        "$(jq -c --arg k "$appkey" --arg p "$PROWLARR_INTERNAL" '.fields |= map(
            if .name == "apiKey" then .value = $k
            elif .name == "prowlarrUrl" then .value = $p
            else . end)' <<<"$current")" >/dev/null
      ok "application $impl (API key and Prowlarr address refreshed)"; return
    fi
    body=$(jq -c --arg impl "$impl" --arg base "$base" --arg k "$appkey" --arg p "$PROWLARR_INTERNAL" '
      first(.[] | select(.implementation == $impl))
      | .name = $impl | .syncLevel = "fullSync"
      | .fields |= map(
          if .name == "prowlarrUrl" then .value = $p
          elif .name == "baseUrl" then .value = $base
          elif .name == "apiKey" then .value = $k
          else . end)' <<<"$schema")
    arr "$key" POST "$PROWLARR_URL/api/v1/applications" "$body" >/dev/null
    ok "application $impl -> $base"
  }
  add_app Sonarr http://sonarr:8989 "$(xml_apikey sonarr)"
  add_app Radarr http://radarr:7878 "$(xml_apikey radarr)"
  add_app Lidarr http://lidarr:8686 "$(xml_apikey lidarr)"

  # Spotweb, as a Newznab indexer. Prowlarr has no Spotweb definition of its
  # own - 600-odd built-in definitions and none of them match - so the generic
  # Newznab one is instantiated instead, which is what Spotweb speaks. Its key
  # comes from configure_spotweb, which runs before this section.
  #
  # Like an application, a stored key reads back as "****", so the only way to
  # tell a live entry from a stale one is to let Prowlarr test it.
  add_newznab() {                # add_newznab NAME BASEURL APIKEY
    local name=$1 base=$2 idxkey=$3 idx ischema body current id have
    [[ -n "$idxkey" ]] || { echo "        ($name has no API key yet)"; return 0; }
    idx=$(arr "$key" GET "$PROWLARR_URL/api/v1/indexer")
    current=$(jq -c --arg n "$name" 'first(.[] | select(.name == $n)) // empty' <<<"$idx")
    if [[ -n "$current" ]]; then
      # Converge on the address, not on a test: unlike an application, this
      # indexer's key is one this stack issued and does not rotate, while a test
      # search fails whenever the spot database happens to be empty - which says
      # nothing about the configuration.
      have=$(jq -r '[(.fields[] | select(.name == "baseUrl") | .value),
                     (.fields[] | select(.name == "apiPath") | .value)] | join("|")' <<<"$current")
      if [[ "$have" == "$base|/api" ]]; then
        skip "indexer $name"; return 0
      fi
      id=$(jq -r .id <<<"$current")
      arr "$key" PUT "$PROWLARR_URL/api/v1/indexer/$id" \
        "$(jq -c --arg b "$base" --arg k "$idxkey" '.fields |= map(
            if .name == "baseUrl" then .value = $b
            elif .name == "apiPath" then .value = "/api"
            elif .name == "apiKey" then .value = $k
            else . end)' <<<"$current")" >/dev/null
      ok "indexer $name (address and API key refreshed)"; return 0
    fi
    # Prowlarr validates by searching, so an empty Spotweb cannot be added at
    # all. configure_spotweb counts the spots; without any, this waits.
    if [[ "${SPOTWEB_SPOTS:-0}" == 0 ]]; then
      skip "indexer $name (waits until Spotweb has retrieved its first spots)"; return 0
    fi
    ischema=$(arr "$key" GET "$PROWLARR_URL/api/v1/indexer/schema")
    body=$(jq -c --arg n "$name" --arg b "$base" --arg k "$idxkey" '
      first(.[] | select(.implementation == "Newznab" and .definitionName == "Newznab"))
      | .name = $n | .enable = true | .appProfileId = 1
      | .fields |= map(
          if .name == "baseUrl" then .value = $b
          elif .name == "apiPath" then .value = "/api"
          elif .name == "apiKey" then .value = $k
          else . end)' <<<"$ischema")
    arr "$key" POST "$PROWLARR_URL/api/v1/indexer" "$body" >/dev/null
    ok "indexer $name -> $base"
  }
  add_newznab Spotweb "$SPOTWEB_INTERNAL" "${SPOTWEB_KEY:-}"

  # Download clients for Prowlarr's own search page (the arr apps use their
  # own clients). A grab there lands in the same client category as the
  # apps' grabs, mapped from the indexer category: Movies -> movies, TV ->
  # tv, Audio -> music, anything else -> "prowlarr". Entries are
  # kept, credentials and mappings refreshed, like in the apps.
  local clients cschema catmap
  clients=$(arr "$key" GET "$PROWLARR_URL/api/v1/downloadclient")
  cschema=$(arr "$key" GET "$PROWLARR_URL/api/v1/downloadclient/schema")
  catmap=$(arr "$key" GET "$PROWLARR_URL/api/v1/indexer/categories" | jq -c '
    [ {id: 2000, client: "movies"}, {id: 5000, client: "tv"}, {id: 3000, client: "music"} ] as $want
    | [ .[] as $c | $want[] | select(.id == $c.id) | {clientCategory: .client, categories: ([$c.id] + [$c.subCategories[].id])} ]')
  add_client() {                 # add_client DISPLAYNAME IMPLEMENTATION VALUES_JSON
    local display=$1 impl=$2 values=$3 body current
    current=$(jq -c --arg n "$display" 'first(.[] | select(.name == $n)) // empty' <<<"$clients")
    if [[ -n "$current" ]]; then
      body=$(jq -c --argjson v "$values" --argjson m "$catmap" '
        .categories = $m | .fields |= map(if $v[.name] != null then .value = $v[.name] else . end)' <<<"$current")
      arr "$key" PUT "$PROWLARR_URL/api/v1/downloadclient/$(jq -r .id <<<"$current")" "$body" >/dev/null
      ok "download client $display (credentials and category mappings refreshed)"; return
    fi
    body=$(jq -c --arg impl "$impl" --arg n "$display" --argjson v "$values" --argjson m "$catmap" '
      first(.[] | select(.implementation == $impl))
      | .name = $n | .enable = true | .categories = $m
      | .fields |= map(if $v[.name] != null then .value = $v[.name] else . end)' <<<"$cschema")
    arr "$key" POST "$PROWLARR_URL/api/v1/downloadclient" "$body" >/dev/null
    ok "download client $display -> movies/tv/music by indexer category, else prowlarr"
  }
  add_client qBittorrent QBittorrent "$(jq -cn --arg host "$QBT_INTERNAL_HOST" --argjson port "$QBT_INTERNAL_PORT" \
      --arg u "$WEBUI_USERNAME" --arg p "$WEBUI_PASSWORD" '{host:$host, port:$port, username:$u, password:$p, category:"prowlarr"}')"
  add_client SABnzbd Sabnzbd "$(jq -cn --arg host "$SAB_INTERNAL_HOST" --argjson port "$SAB_INTERNAL_PORT" \
      --arg k "$SAB_KEY" '{host:$host, port:$port, apiKey:$k, category:"prowlarr"}')"

  # FlareSolverr: Prowlarr routes an indexer through it only when the indexer
  # carries one of the proxy's tags AND a Cloudflare challenge is detected.
  # The tag is created here; which indexers get it is your call (README "Connecting Prowlarr").
  local tags tag_id proxies
  tags=$(arr "$key" GET "$PROWLARR_URL/api/v1/tag")
  tag_id=$(jq -r 'first(.[] | select(.label == "flaresolverr")) | .id // empty' <<<"$tags")
  if [[ -z "$tag_id" ]]; then
    tag_id=$(arr "$key" POST "$PROWLARR_URL/api/v1/tag" '{"label":"flaresolverr"}' | jq -r .id)
    ok "tag flaresolverr"
  fi
  proxies=$(arr "$key" GET "$PROWLARR_URL/api/v1/indexerproxy")
  local current_proxy
  current_proxy=$(jq -c 'first(.[] | select(.name == "FlareSolverr")) // empty' <<<"$proxies")
  if [[ -n "$current_proxy" ]]; then
    # Converge the host: it is flaresolverr:8191 normally and gluetun:8191 once
    # FlareSolverr answers on Gluetun's name too. Skipping on existence
    # alone left a stale address that resolves to nothing, and the only symptom
    # is that Cloudflare-protected indexers quietly stop returning results.
    if [[ "$(jq -r '.fields[] | select(.name == "host") | .value' <<<"$current_proxy")" == "$FLARESOLVERR_INTERNAL" ]]; then
      skip "indexer proxy FlareSolverr"
    else
      arr "$key" PUT "$PROWLARR_URL/api/v1/indexerproxy/$(jq -r .id <<<"$current_proxy")" \
        "$(jq -c --arg h "$FLARESOLVERR_INTERNAL" '.fields |= map(if .name == "host" then .value = $h else . end)' <<<"$current_proxy")" >/dev/null
      ok "indexer proxy FlareSolverr -> $FLARESOLVERR_INTERNAL (address refreshed)"
    fi
  else
    arr "$key" POST "$PROWLARR_URL/api/v1/indexerproxy" "$(arr "$key" GET "$PROWLARR_URL/api/v1/indexerproxy/schema" \
      | jq -c --arg h "$FLARESOLVERR_INTERNAL" --argjson t "$tag_id" '
        first(.[] | select(.implementation == "FlareSolverr"))
        | .name = "FlareSolverr" | .tags = [$t]
        | .fields |= map(if .name == "host" then .value = $h else . end)')" >/dev/null
    ok "indexer proxy FlareSolverr -> $FLARESOLVERR_INTERNAL (used by indexers tagged flaresolverr)"
  fi

  # Prowlarr writes its own address into every indexer it pushes, and only
  # re-pushes when its definition changes - so after the address moves, the
  # apps keep the old one until the periodic sync, up to six hours of searches
  # against a name that no longer resolves. Ask for the sync instead of waiting,
  # but only when it actually moved: a sync on every run is pointless traffic.
  if (( PROWLARR_MOVED )); then
    arr "$key" POST "$PROWLARR_URL/api/v1/command" '{"name":"ApplicationIndexerSync","forceSync":true}' >/dev/null
    ok "indexers re-pushed to the apps (Prowlarr's address moved)"
  else
    skip "indexers already point at $PROWLARR_INTERNAL"
  fi
}

# ---------------------------------------------------------------- seed criteria
# A public tracker keeps no account of what you give back, so the global limit
# in qBittorrent - ratio 1 or 24 hours - is the whole story there. A private
# one usually calls a torrent a hit and run unless it seeded a minimum time,
# whatever ratio it reached, and a ratio cap would stop it long before that:
# measured here, ratio 1 arrives after about three hours.
#
# So the private indexers get a seed *time* and deliberately no seed ratio,
# and the public ones get neither and fall back on the global limit. Which is
# which comes from Prowlarr, which knows each indexer's privacy - guessing it
# from a torrent's announce host would be wrong as often as right, because the
# announce domain and the site domain frequently differ.
#
# Radarr and Sonarr hand these to qBittorrent as that torrent's own share
# limit when they grab, so heal.sh has to leave such a torrent alone rather
# than pinning it back on the global pair; enforce_share_limits knows about
# TORRENT_PRIVATE_SEED_HOURS for exactly that reason.
configure_seed_criteria() {
  log "Seeding rules per tracker"
  local hours=${TORRENT_PRIVATE_SEED_HOURS:-72}
  [[ "$hours" =~ ^[0-9]+$ ]] || die "TORRENT_PRIVATE_SEED_HOURS must be a whole number of hours (got \"$hours\")"
  local pkey privacy minutes=$(( hours * 60 )) app name port v key indexers one id impl short want cur changed=0 private=0 public=0
  pkey=$(xml_apikey prowlarr)
  privacy=$(arr "$pkey" GET "$PROWLARR_URL/api/v1/indexer" | jq -c 'map({name, privacy}) | INDEX(.name)')

  for app in sonarr:8989:v3 radarr:7878:v3 lidarr:8686:v1; do
    IFS=: read -r name port v <<<"$app"
    key=$(xml_apikey "$name") || continue
    [[ -n "$key" ]] || continue
    indexers=$(arr "$key" GET "http://localhost:$port/api/$v/indexer") || continue
    while IFS= read -r one; do
      [[ -n "$one" ]] || continue
      id=$(jq -r .id <<<"$one"); impl=$(jq -r .implementation <<<"$one")
      # Usenet has no seeding at all, so Newznab entries have no criteria.
      [[ "$impl" == Torznab ]] || continue
      short=$(jq -r '.name | sub(" \\(Prowlarr\\)$"; "")' <<<"$one")
      if [[ $(jq -r --arg n "$short" '.[$n].privacy // "public"' <<<"$privacy") == private ]]; then
        want=$(jq -cn --argjson m "$minutes" '{ratio: "", time: ($m|tostring)}'); private=$(( private + 1 ))
      else
        want=$(jq -cn '{ratio: "", time: ""}'); public=$(( public + 1 ))
      fi
      cur=$(jq -c '{ratio: ((.fields[] | select(.name == "seedCriteria.seedRatio") | .value // "") | tostring),
                     time:  ((.fields[] | select(.name == "seedCriteria.seedTime")  | .value // "") | tostring)}' <<<"$one")
      [[ "$cur" == "$want" ]] && continue
      arr "$key" PUT "http://localhost:$port/api/$v/indexer/$id" \
        "$(jq -c --argjson w "$want" '.fields |= map(
             if .name == "seedCriteria.seedRatio" then (if $w.ratio == "" then del(.value) else .value = ($w.ratio|tonumber) end)
             elif .name == "seedCriteria.seedTime" then (if $w.time == "" then del(.value) else .value = ($w.time|tonumber) end)
             else . end)' <<<"$one")" >/dev/null
      changed=1
    done < <(jq -c '.[]' <<<"$indexers")
  done

  if (( changed )); then
    ok "$private private indexer entr(ies) seed for ${hours}h with no ratio cap; $public public one(s) use the global ratio ${TORRENT_SEED_RATIO:-1} / ${TORRENT_SEED_DAYS:-1}d"
  else
    skip "$private private indexer entr(ies) seed for ${hours}h with no ratio cap; $public public one(s) use the global limit"
  fi
}
