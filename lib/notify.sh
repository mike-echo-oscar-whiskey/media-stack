# Failure alerts through the stack's own ntfy.
# Sourced by configure.sh, which loads .env, defines the URL constants and the
# log/ok/skip/die helpers.

# ------------------------------------------------------------------- events
# NTFY_EVENTS names what to be told about in app-neutral words, because the
# apps do not agree: "a file finished importing and is playable" is
# onImportComplete in Sonarr, onDownload in Radarr and onReleaseImport in
# Lidarr, and Radarr has no onImportComplete at all. Sonarr has both, and they
# are not the same thing - onDownload is "On File Import" and fires once per
# episode, onImportComplete fires once per download, so a 24-episode season
# pack is one alert instead of twenty-four.
#
# health and manual are deliberately not gated by NTFY_EVENT_APPS: an app left
# out of the list must still be able to say that it is broken.
# ntfy_priority INTENT -> 1-5. NTFY_PRIORITY is either a single level for
# everything, or a per-intent list such as "ready:2,failed:5,health:3".
# Anything not named falls back to 4, so a half-filled list still works.
ntfy_priority() {
  local intent=$1 spec=${NTFY_PRIORITY:-4} pair k lvl
  spec=${spec// /}
  [[ $spec =~ ^[1-5]$ ]] && { printf '%s' "$spec"; return 0; }
  local IFS=,
  for pair in $spec; do
    k=${pair%%:*} lvl=${pair##*:}
    [[ $k == "$intent" && $lvl =~ ^[1-5]$ ]] || continue
    printf '%s' "$lvl"; return 0
  done
  printf '4'
}

# ntfy_event_plan APP -> {"<level>": {"<onFlag>": true, ...}, ...}
# An app's ntfy connection carries one priority for everything it sends, so
# intents wanted at different levels cannot share one. They are grouped by
# level here and become one connection each, named ntfy-p<level>.
ntfy_event_plan() {
  local app=$1 pair flag intent lvl out='{}'
  local events=",${NTFY_EVENTS:-}," apps=",${NTFY_EVENT_APPS:-},"
  events=${events// /} apps=${apps// /}
  local -a map
  case $app in
    sonarr)   map=(onImportComplete:ready onGrab:grab onUpgrade:upgrade
                   onManualInteractionRequired:manual
                   onHealthIssue:health onHealthRestored:health) ;;
    radarr)   map=(onDownload:ready onGrab:grab onUpgrade:upgrade
                   onManualInteractionRequired:manual
                   onHealthIssue:health onHealthRestored:health) ;;
    lidarr)   map=(onReleaseImport:ready onGrab:grab onUpgrade:upgrade
                   onDownloadFailure:failed onImportFailure:failed
                   onHealthIssue:health onHealthRestored:health) ;;
    prowlarr) map=(onGrab:grab onHealthIssue:health onHealthRestored:health) ;;
    *)        map=() ;;
  esac
  for pair in "${map[@]}"; do
    flag=${pair%%:*} intent=${pair##*:}
    case $intent in
      health|manual) : ;;
      *) [[ $apps == *,"$app",* ]] || continue ;;
    esac
    [[ $events == *,"$intent",* ]] || continue
    lvl=$(ntfy_priority "$intent")
    out=$(jq -c --arg l "$lvl" --arg f "$flag" '.[$l] = ((.[$l] // {}) + {($f): true})' <<<"$out")
  done
  printf '%s' "$out"
}

# ------------------------------------------------------------------- alerts
# Every app that can report something pushes to one ntfy topic. What counts as
# worth pushing is NTFY_EVENTS in .env, not a decision made here.
#
# The topic name is the whole secret - the server has no accounts, which is
# ntfy's own recommendation for a private instance - so it is generated once
# and kept in .env like the Web UI password. An empty NTFY_TOPIC means alerts
# were deliberately turned off, and every step here says so and does nothing.
configure_notify() {
  log "Alerts (ntfy)"
  if [[ -z "${NTFY_TOPIC:-}" ]]; then
    skip "no NTFY_TOPIC in .env - alerts are off"
    return 0
  fi
  NTFY_USER=${NTFY_USER:-media-stack}
  if [[ -z "${NTFY_PASSWORD:-}" ]]; then
    NTFY_PASSWORD=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    set_env NTFY_PASSWORD "$NTFY_PASSWORD"
    ok "password generated for the $NTFY_USER account and stored in .env"
  else
    skip "account password from .env"
  fi
  set_env NTFY_USER "$NTFY_USER"

  # The account and its access live in ntfy's own database, not in a config
  # file, so they are created through its CLI. The password goes in on stdin:
  # passing it as an environment argument to docker exec would put it in the
  # host's process list.
  if docker compose exec -T ntfy ntfy user list 2>/dev/null | grep -q "^user $NTFY_USER "; then
    skip "account $NTFY_USER"
  else
    if printf '%s' "$NTFY_PASSWORD" | docker compose exec -T ntfy sh -c \
         'read -r p; NTFY_PASSWORD="$p" ntfy user add "$0" >/dev/null' "$NTFY_USER" 2>/dev/null; then
      ok "account $NTFY_USER created"
    else
      printf '   WARN could not create the ntfy account %s\n' "$NTFY_USER"; return 0
    fi
  fi
  if docker compose exec -T ntfy ntfy access "$NTFY_USER" 2>/dev/null | grep -q "read-write access to topic $NTFY_TOPIC$"; then
    skip "read-write on $NTFY_TOPIC"
  else
    docker compose exec -T ntfy ntfy access "$NTFY_USER" "$NTFY_TOPIC" rw >/dev/null 2>&1 \
      && ok "read-write on $NTFY_TOPIC for $NTFY_USER" \
      || printf '   WARN could not grant access to %s\n' "$NTFY_TOPIC"
  fi

  # The apps reach ntfy by container name; a phone reaches it through the
  # reverse proxy, which is what the click on an alert has to open.
  local internal="http://ntfy" click="http://ntfy.$SITE_DOMAIN/$NTFY_TOPIC"

  local spec=${NTFY_PRIORITY:-4}; spec=${spec// /}
  if [[ ! $spec =~ ^([1-5]|[a-z]+:[1-5](,[a-z]+:[1-5])*)$ ]]; then
    printf '   WARN NTFY_PRIORITY is not a level or a level list, using 4 throughout\n'
  fi

  # add_arr_ntfy NAME URL [APIVERSION]
  # One connection per distinct priority the plan asks for, named ntfy-p<level>.
  # configure.sh owns every connection matching that name and the plain "ntfy"
  # earlier versions created, so one it no longer wants is removed - including
  # when NTFY_EVENTS is emptied, which leaves the app silent and connectionless.
  add_arr_ntfy() {
    local name=$1 url=$2 v=${3:-v3}
    local key schema supported plan existing lvl cname want desired current on body id
    local -a wanted=()
    key=$(xml_apikey "$name")
    [[ -n "$key" ]] || { echo "        ($name has no API key yet)"; return 0; }

    # The supported set comes from the app rather than a second list here:
    # Radarr has no onImportComplete, Lidarr no onManualInteractionRequired,
    # Prowlarr only four events at all.
    schema=$(arr "$key" GET "$url/api/$v/notification/schema")
    supported=$(jq -c 'first(.[] | select(.implementation == "Ntfy"))
      | [ to_entries[] | select(.key | startswith("supportsOn")) | select(.value == true)
          | .key | sub("^supports"; "") | (.[0:1] | ascii_downcase) + .[1:] ]' <<<"$schema")
    plan=$(ntfy_event_plan "$name" \
           | jq -c --argjson s "$supported" '
               with_entries(.value |= with_entries(select(.key as $k | $s | index($k))))
               | with_entries(select(.value | length > 0))')
    existing=$(arr "$key" GET "$url/api/$v/notification")

    for lvl in $(jq -r 'keys[]' <<<"$plan"); do
      cname="ntfy-p$lvl"
      wanted+=("$cname")
      want=$(jq -c --arg l "$lvl" '.[$l]' <<<"$plan")
      # Every flag the app has gets an explicit value, so one switched on by
      # hand in the web UI is switched back off.
      desired=$(jq -cn --argjson s "$supported" --argjson w "$want" \
        '$s | map({key: ., value: ($w[.] // false)}) | from_entries')
      on=$(jq -r '[to_entries[] | select(.value) | .key | sub("^on"; "")] | join(", ")' <<<"$desired")
      current=$(jq -c --arg n "$cname" 'first(.[] | select(.name == $n)) // empty' <<<"$existing")
      if [[ -n "$current" ]]; then
        if jq -e --arg s "$internal" --arg t "$NTFY_TOPIC" --arg u "$NTFY_USER" \
             --argjson d "$desired" --argjson p "$lvl" \
             '. as $cur
              | any(.fields[]; .name == "serverUrl" and .value == $s)
                and any(.fields[]; .name == "topics" and (.value | tostring | test($t)))
                and any(.fields[]; .name == "userName" and .value == $u)
                and any(.fields[]; .name == "priority" and (.value | tonumber) == $p)
                and ((first(.fields[] | select(.name == "tags") | .value) // []) | length == 0)
                and ($d | to_entries | all(.value == ($cur[.key] // false)))' <<<"$current" >/dev/null; then
          skip "$name -> $cname on $on"
        else
          arr "$key" PUT "$url/api/$v/notification/$(jq -r .id <<<"$current")" \
            "$(jq -c --arg s "$internal" --argjson t "[\"$NTFY_TOPIC\"]" --arg c "$click" \
               --arg u "$NTFY_USER" --arg pw "$NTFY_PASSWORD" --argjson d "$desired" --argjson p "$lvl" \
               '. * $d
                | .fields |= map(
                  if .name == "serverUrl" then .value = $s
                  elif .name == "topics" then .value = $t
                  elif .name == "clickUrl" then .value = $c
                  elif .name == "userName" then .value = $u
                  elif .name == "password" then .value = $pw
                  elif .name == "priority" then .value = $p
                  elif .name == "tags" then .value = []
                  else . end)' <<<"$current")" >/dev/null
          ok "$name -> $cname on $on (refreshed)"
        fi
      else
        body=$(jq -c --arg n "$cname" --arg s "$internal" --argjson t "[\"$NTFY_TOPIC\"]" --arg c "$click" \
          --arg u "$NTFY_USER" --arg pw "$NTFY_PASSWORD" --argjson d "$desired" --argjson p "$lvl" '
          first(.[] | select(.implementation == "Ntfy"))
          | .name = $n
          | . * $d
          | .fields |= map(
              if .name == "serverUrl" then .value = $s
              elif .name == "topics" then .value = $t
              elif .name == "clickUrl" then .value = $c
              elif .name == "userName" then .value = $u
              elif .name == "password" then .value = $pw
              elif .name == "priority" then .value = $p
              elif .name == "tags" then .value = []
              else . end)' <<<"$schema")
        arr "$key" POST "$url/api/$v/notification" "$body" >/dev/null
        ok "$name -> $cname on $on"
      fi
    done

    while IFS=$'\x1f' read -r id cname; do
      [[ -n "$id" ]] || continue
      if printf '%s\n' ${wanted[@]+"${wanted[@]}"} | grep -qx -- "$cname"; then continue; fi
      arr "$key" DELETE "$url/api/$v/notification/$id" >/dev/null
      ok "$name -> removed $cname"
    done < <(jq -r '.[] | select(.name | test("^ntfy(-p[1-5])?$")) | "\(.id)\u001f\(.name)"' <<<"$existing")
  }

  add_arr_ntfy sonarr   "$SONARR_URL"
  add_arr_ntfy radarr   "$RADARR_URL"
  add_arr_ntfy lidarr   "$LIDARR_URL"   v1
  add_arr_ntfy prowlarr "$PROWLARR_URL" v1

  # Sonarr and Radarr have no failure event of any kind - not on the ntfy
  # connection, not on any implementation in their schema. heal.sh watches
  # their history for downloadFailed instead and pushes those itself.
  if [[ ",${NTFY_EVENTS:-}," == *,failed,* ]]; then
    echo "        (failed: Sonarr and Radarr have no such event - heal.sh watches their history)"
  fi

  # Bazarr reaches ntfy through Apprise, which takes the whole thing as a URL.
  # Its settings endpoint updates notification providers by name from a
  # "notifications-providers" form field - no settings- prefix, unlike every
  # other key it takes - so only the one entry needs posting. Bazarr has no
  # per-event granularity at all, so NTFY_EVENTS does not reach it.
  local bkey bcur burl
  bkey=$(sed -n '/^auth:/,/^[^ ]/{s/^ *apikey: *//p}' "$CONFIG_ROOT/bazarr/config/config.yaml" 2>/dev/null | tr -d "\"'" | head -n1)
  burl="ntfy://$NTFY_USER:$NTFY_PASSWORD@ntfy/$NTFY_TOPIC"
  if [[ -n "$bkey" ]]; then
    bcur=$(curl -fsS -H "X-API-KEY: $bkey" "$BAZARR_URL/api/system/settings" 2>/dev/null \
           | jq -r '.notifications.providers[]? | select(.name == "ntfy") | "\(.enabled)|\(.url // "")"')
    if [[ "$bcur" == "true|$burl" ]]; then
      skip "bazarr -> ntfy"
    else
      if curl -fsS -o /dev/null -H "X-API-KEY: $bkey" -X POST "$BAZARR_URL/api/system/settings" \
           --data-urlencode "notifications-providers=$(jq -cn --arg u "$burl" '{name:"ntfy", enabled:true, url:$u}')"; then
        ok "bazarr -> ntfy"
      else
        printf '   WARN could not enable the ntfy provider in Bazarr\n'
      fi
    fi
  fi

  echo "        (subscribe: server http://ntfy.$SITE_DOMAIN, topic $NTFY_TOPIC, login from NTFY_USER/NTFY_PASSWORD in .env)"
}
