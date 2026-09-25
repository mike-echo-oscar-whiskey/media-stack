# Sonarr, Radarr and Lidarr: the settings all three share.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- Sonarr / Radarr
# set_arr_login KEY URL APIVERSION - forms authentication with the shared login.
set_arr_login() {
  local key=$1 url=$2 v=$3 host
  host=$(arr "$key" GET "$url/api/$v/config/host" | jq -c --arg u "$WEBUI_USERNAME" --arg p "$WEBUI_PASSWORD" '
    .authenticationMethod = "forms" | .authenticationRequired = "enabled"
    | .username = $u | .password = $p | .passwordConfirmation = $p')
  arr "$key" PUT "$url/api/$v/config/host/$(jq -r .id <<<"$host")" "$host" >/dev/null
  ok "Web UI login set (forms)"
}

# TRaSH-guide naming for Plex: folder ids in braces ({tvdb-…}, {tmdb-…}) are
# what Plex's agents read for an exact match; [imdbid-…] is the Jellyfin/Emby
# form. Quality/codec info stays in the file name. Applied only while the app
# still has its factory format, so edits made in the UI are never overwritten.
SONARR_NAMING='{
  "renameEpisodes": true,
  "standardEpisodeFormat": "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoCodec]}{-Release Group}",
  "dailyEpisodeFormat": "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo VideoDynamicRangeType]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{MediaInfo AudioLanguages}{[MediaInfo VideoCodec]}{-Release Group}",
  "animeEpisodeFormat": "{Series TitleYear} - S{season:00}E{episode:00} - {absolute:000} - {Episode CleanTitle} [{Custom Formats }{Quality Full}]{[MediaInfo VideoDynamicRangeType]}[{MediaInfo VideoBitDepth}bit]{[MediaInfo VideoCodec]}[{Mediainfo AudioCodec} { Mediainfo AudioChannels}]{MediaInfo AudioLanguages}{-Release Group}",
  "seriesFolderFormat": "{Series TitleYear} {tvdb-{TvdbId}}",
  "seasonFolderFormat": "Season {season:00}"
}'
RADARR_NAMING='{
  "renameMovies": true,
  "standardMovieFormat": "{Movie CleanTitle} {(Release Year)} {tmdb-{TmdbId}} {edition-{Edition Tags}} {[Custom Formats]}{[Quality Full]}{[MediaInfo 3D]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[Mediainfo VideoCodec]}{-Release Group}",
  "movieFolderFormat": "{Movie CleanTitle} ({Release Year}) {tmdb-{TmdbId}}"
}'

LIDARR_NAMING='{
  "renameTracks": true,
  "standardTrackFormat": "{Album Title} ({Release Year})/{Artist Name} - {Album Title} - {track:00} - {Track Title}",
  "multiDiscTrackFormat": "{Album Title} ({Release Year})/{Medium Format} {medium:00}/{Artist Name} - {Album Title} - {track:00} - {Track Title}",
  "artistFolderFormat": "{Artist Name}"
}'

# set_arr_naming KEY URL RENAMEFLAG NAMING_JSON [APIVERSION]
set_arr_naming() {
  local key=$1 url=$2 flag=$3 naming=$4 v=${5:-v3} current
  current=$(arr "$key" GET "$url/api/$v/config/naming")
  if jq -e --arg f "$flag" '.[$f] == true' <<<"$current" >/dev/null; then
    skip "naming (already customised)"; return
  fi
  arr "$key" PUT "$url/api/$v/config/naming/$(jq -r .id <<<"$current")" "$(jq -c --argjson n "$naming" '. + $n' <<<"$current")" >/dev/null
  ok "TRaSH-style renaming and folder naming"
}

# add_plex_notification KEY URL [APIVERSION] - Plex refreshes the library right
# after an import, rename or delete instead of waiting for its own scan.
add_plex_notification() {
  local key=$1 url=$2 v=${3:-v3} token existing schema body
  token=$(plex_token)
  [[ -n "$token" ]] || { echo "        (Plex library refresh is added once the server is claimed)"; return; }
  existing=$(arr "$key" GET "$url/api/$v/notification")
  local current
  current=$(jq -c 'first(.[] | select(.name == "Plex")) // empty' <<<"$existing")
  if [[ -n "$current" ]]; then
    if jq -e --arg h "$PLEX_INTERNAL_HOST" 'any(.fields[]; .name == "host" and .value == $h)' <<<"$current" >/dev/null; then
      skip "Plex library refresh"
    else
      arr "$key" PUT "$url/api/$v/notification/$(jq -r .id <<<"$current")" \
        "$(jq -c --arg h "$PLEX_INTERNAL_HOST" '.fields |= map(if .name == "host" then .value = $h else . end)' <<<"$current")" >/dev/null
      ok "Plex library refresh now points at $PLEX_INTERNAL_HOST:32400"
    fi
    return
  fi
  schema=$(arr "$key" GET "$url/api/$v/notification/schema")
  body=$(jq -c --arg t "$token" --arg h "$PLEX_INTERNAL_HOST" '
    first(.[] | select(.implementation == "PlexServer"))
    | .name = "Plex"
    | with_entries(if (.key | test("^on(Download|Upgrade|Rename|ImportComplete|ReleaseImport|TrackRetag|.*Delete.*)$")) then .value = true else . end)
    | .fields |= map(
        if .name == "host" then .value = $h
        elif .name == "port" then .value = 32400
        elif .name == "useSsl" then .value = false
        elif .name == "authToken" then .value = $t
        elif .name == "updateLibrary" then .value = true
        else . end)' <<<"$schema")
  arr "$key" POST "$url/api/$v/notification" "$body" >/dev/null
  ok "Plex library refresh on import/rename/delete"
}

# jellyfin_api_key NAME - an API key named NAME in Jellyfin, created on first use.
# Needs the admin session configure_jellyfin opened (JELLYFIN_TOKEN).
jellyfin_api_key() {
  [[ -n "$JELLYFIN_TOKEN" ]] || return 0
  local k
  k=$(jf GET /Auth/Keys | jq -r --arg n "$1" '.Items[] | select(.AppName == $n) | .AccessToken' | head -n1)
  if [[ -z "$k" ]]; then
    jf POST "/Auth/Keys?app=$(urlenc "$1")" >/dev/null
    k=$(jf GET /Auth/Keys | jq -r --arg n "$1" '.Items[] | select(.AppName == $n) | .AccessToken' | head -n1)
  fi
  printf '%s' "$k"
}

# add_jellyfin_notification NAME KEY URL [APIVERSION] - the "Emby / Jellyfin"
# connection: Jellyfin refreshes its library right after an import, rename
# or delete instead of waiting for the next scan. Lives next to the Plex one.
add_jellyfin_notification() {
  local app=$1 key=$2 url=$3 v=${4:-v3} jkey existing schema body
  jkey=$(jellyfin_api_key "$app")
  [[ -n "$jkey" ]] || { echo "        (Jellyfin library refresh is added once Jellyfin is set up)"; return; }
  existing=$(arr "$key" GET "$url/api/$v/notification")
  if jq -e 'any(.[]; .name == "Jellyfin")' <<<"$existing" >/dev/null; then skip "Jellyfin library refresh"; return; fi
  schema=$(arr "$key" GET "$url/api/$v/notification/schema")
  jq -e 'any(.[]; .implementation == "MediaBrowser")' <<<"$schema" >/dev/null || { echo "        (no Emby/Jellyfin connection type in this app)"; return; }
  body=$(jq -c --arg k "$jkey" '
    first(.[] | select(.implementation == "MediaBrowser"))
    | .name = "Jellyfin"
    | with_entries(if (.key | test("^on(Download|Upgrade|Rename|ImportComplete|ReleaseImport|TrackRetag|.*Delete.*)$")) then .value = true else . end)
    | .fields |= map(
        if .name == "host" then .value = "jellyfin"
        elif .name == "port" then .value = 8096
        elif .name == "useSsl" then .value = false
        elif .name == "apiKey" then .value = $k
        elif .name == "notify" then .value = false
        elif .name == "updateLibrary" then .value = true
        else . end)' <<<"$schema")
  arr "$key" POST "$url/api/$v/notification" "$body" >/dev/null
  ok "Jellyfin library refresh on import/rename/delete"
}

# add_release_guard NAME KEY URL - scripts/release-guard.sh as a Custom Script
# connection on Grab and Import (README "Quality", "Fakes, cams and anything
# under 720p").
add_release_guard() {
  local app=$1 key=$2 url=$3 existing schema body
  existing=$(arr "$key" GET "$url/api/v3/notification")
  if jq -e 'any(.[]; .name == "Release guard")' <<<"$existing" >/dev/null; then skip "release guard"; return; fi
  schema=$(arr "$key" GET "$url/api/v3/notification/schema")
  body=$(jq -c '
    first(.[] | select(.implementation == "CustomScript"))
    | .name = "Release guard"
    | .onGrab = true | .onDownload = true | .onUpgrade = true
    | .fields |= map(if .name == "path" then .value = "/scripts/release-guard.sh" elif .name == "arguments" then .value = "" else . end)' <<<"$schema")
  arr "$key" POST "$url/api/v3/notification" "$body" >/dev/null
  ok "release guard on grab and import (scripts/release-guard.sh)"
}

# configure_arr NAME URL ROOTFOLDER CATEGORY_FIELD_PREFIX CATEGORY [APIVERSION]
configure_arr() {
  local name=$1 url=$2 root=$3 prefix=$4 category=$5 v=${6:-v3} key
  log "$name"
  key=$(xml_apikey "$name")
  [[ -n "$key" ]] || die "no ApiKey in $CONFIG_ROOT/$name/config.xml yet"
  set_arr_login "$key" "$url" "$v"
  configure_ui_dates "$key" "$url" "$v"

  if arr "$key" GET "$url/api/$v/rootfolder" | jq -e --arg p "$root" 'any(.[]; .path == $p)' >/dev/null; then
    skip "root folder $root"
  else
    local rf
    rf=$(jq -cn --arg p "$root" '{path:$p}')
    # Lidarr's root folders carry the defaults for new artists.
    [[ $name == lidarr ]] && rf=$(jq -cn --arg p "$root" '{path:$p, name:"Music", defaultQualityProfileId:3, defaultMetadataProfileId:1, defaultMonitorOption:"all", defaultNewItemMonitorOption:"all"}')
    arr "$key" POST "$url/api/$v/rootfolder" "$rf" >/dev/null
    ok "root folder $root"
  fi

  local existing schema
  existing=$(arr "$key" GET "$url/api/$v/downloadclient")
  schema=$(arr "$key" GET "$url/api/$v/downloadclient/schema")

  add_client() {                 # add_client DISPLAYNAME IMPLEMENTATION VALUES_JSON
    local display=$1 impl=$2 values=$3 body current
    current=$(jq -c --arg n "$display" 'first(.[] | select(.name == $n)) // empty' <<<"$existing")
    if [[ -n "$current" ]]; then
      # Keep the entry, refresh what may have changed (login, API key, host).
      body=$(jq -c --argjson v "$values" '.fields |= map(if $v[.name] != null then .value = $v[.name] else . end)' <<<"$current")
      arr "$key" PUT "$url/api/$v/downloadclient/$(jq -r .id <<<"$current")" "$body" >/dev/null
      ok "download client $display (credentials refreshed)"; return
    fi
    body=$(jq -c --arg impl "$impl" --arg n "$display" --argjson v "$values" '
      first(.[] | select(.implementation == $impl))
      | .name = $n | .enable = true | .removeCompletedDownloads = true | .removeFailedDownloads = true
      | .fields |= map(if $v[.name] != null then .value = $v[.name] else . end)' <<<"$schema")
    arr "$key" POST "$url/api/$v/downloadclient" "$body" >/dev/null
    ok "download client $display -> category $category"
  }
  add_client qBittorrent QBittorrent "$(jq -cn \
      --arg host "$QBT_INTERNAL_HOST" --argjson port "$QBT_INTERNAL_PORT" \
      --arg u "$WEBUI_USERNAME" --arg p "$WEBUI_PASSWORD" --arg f "${prefix}Category" --arg c "$category" \
      '{host:$host, port:$port, username:$u, password:$p, ($f):$c}')"
  add_client SABnzbd Sabnzbd "$(jq -cn \
      --arg host "$SAB_INTERNAL_HOST" --argjson port "$SAB_INTERNAL_PORT" \
      --arg k "$SAB_KEY" --arg f "${prefix}Category" --arg c "$category" \
      '{host:$host, port:$port, apiKey:$k, ($f):$c}')"

  case $name in
    sonarr) set_arr_naming "$key" "$url" renameEpisodes "$SONARR_NAMING" ;;
    radarr) set_arr_naming "$key" "$url" renameMovies "$RADARR_NAMING" ;;
    lidarr) set_arr_naming "$key" "$url" renameTracks "$LIDARR_NAMING" v1 ;;
  esac
  add_plex_notification "$key" "$url" "$v"
  add_jellyfin_notification "$name" "$key" "$url" "$v"
  case "$name" in sonarr|radarr) add_release_guard "$name" "$key" "$url" ;; esac

  # Two settings on one endpoint, so one GET and at most one PUT: keep subtitles
  # that come with a release instead of discarding them, and refuse an import
  # that would leave the disk under DISK_FLOOR_GIB. The free-space floor is the
  # only brake these apps have - see README "Keeping the disk from filling".
  # Lidarr has the floor but not the video extras.
  local mm want floor_mb=0
  if [[ "${DISK_FLOOR_GIB:-0}" =~ ^[0-9]+$ ]]; then
    floor_mb=$(( ${DISK_FLOOR_GIB:-0} * 1024 ))
  else
    printf '   WARN DISK_FLOOR_GIB must be a whole number of GiB, leaving the import floor alone\n'
  fi
  mm=$(arr "$key" GET "$url/api/$v/config/mediamanagement")
  want=$(jq -c --argjson f "$floor_mb" --arg n "$name" '
    (if $f > 0 then .minimumFreeSpaceWhenImporting = $f else . end)
    | if $n == "lidarr" then . else
        .importExtraFiles = true | .extraFileExtensions = "srt,sub,idx,ass,ssa"
      end' <<<"$mm")
  if [[ "$(jq -cS . <<<"$mm")" == "$(jq -cS . <<<"$want")" ]]; then
    skip "media management (import floor, extra files)"
  else
    arr "$key" PUT "$url/api/$v/config/mediamanagement/$(jq -r .id <<<"$mm")" "$want" >/dev/null
    if (( floor_mb > 0 )); then
      ok "imports refused below ${DISK_FLOOR_GIB} GiB free$([[ $name == lidarr ]] || echo '; extra files (subtitles) imported alongside the video')"
    else
      ok "extra files (subtitles) imported alongside the video"
    fi
  fi
}
