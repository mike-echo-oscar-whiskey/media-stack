# Jellyfin: setup wizard, libraries, users and playback.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- Jellyfin
# A second media server on the same read-only library, tried alongside Plex.
# One user for now: the administrator from WEBUI_USERNAME/WEBUI_PASSWORD.
# Every call below was checked against the server's own
# /api-docs/openapi.json (Jellyfin 12).
JELLYFIN_TOKEN=
jf() {                            # jf METHOD PATH [JSON]   (uses JELLYFIN_TOKEN once set)
  local auth='MediaBrowser Client="configure.sh", Device="media-stack", DeviceId="media-stack-configure", Version="1"'
  [[ -n "$JELLYFIN_TOKEN" ]] && auth+=", Token=\"$JELLYFIN_TOKEN\""
  if [[ -n "${3:-}" ]]; then
    curl -fsS -X "$1" -H "Authorization: $auth" -H 'Content-Type: application/json' -d "$3" "$JELLYFIN_URL$2"
  else
    curl -fsS -X "$1" -H "Authorization: $auth" "$JELLYFIN_URL$2"
  fi
}

configure_jellyfin() {
  log "Jellyfin"
  local info cc=${PLEX_CERTIFICATION_COUNTRY:-US}
  info=$(curl -fsS "$JELLYFIN_URL/System/Info/Public") || die "Jellyfin does not answer at $JELLYFIN_URL"
  if [[ $(jq -r .StartupWizardCompleted <<<"$info") != true ]]; then
    # The wizard as the web UI walks it: reading a step initialises it,
    # posting stores it; the first user becomes the administrator.
    jf GET /Startup/Configuration >/dev/null
    jf POST /Startup/Configuration "$(jq -cn --arg cc "${cc^^}" \
      '{ServerName:"Jellyfin", UICulture:"en-US", MetadataCountryCode:$cc, PreferredMetadataLanguage:"en"}')"
    jf GET /Startup/User >/dev/null
    jf POST /Startup/User "$(jq -cn --arg u "$WEBUI_USERNAME" --arg p "$WEBUI_PASSWORD" '{Name:$u, Password:$p}')"
    jf POST /Startup/RemoteAccess '{"EnableRemoteAccess":true}'
    jf POST /Startup/Complete
    ok "setup wizard completed; administrator $WEBUI_USERNAME (login from .env)"
  else
    skip "setup wizard"
  fi

  local login session
  login=$(jq -cn --arg u "$WEBUI_USERNAME" --arg p "$WEBUI_PASSWORD" '{Username:$u, Pw:$p}')
  if ! session=$(jf POST /Users/AuthenticateByName "$login" 2>/dev/null); then
    # .env and Jellyfin disagree (login changed on either side). .env is the
    # source of truth: Jellyfin's own forgot-password flow writes a PIN into
    # its config directory, which this host can read; redeeming it clears the
    # password, after which the .env one is set.
    echo "   .env login not accepted - resetting Jellyfin's stored password"
    jf POST /Users/ForgotPassword "$(jq -cn --arg u "$WEBUI_USERNAME" '{EnteredUsername:$u}')" >/dev/null
    local pin
    pin=$(jq -r '.Pin' "$CONFIG_ROOT/jellyfin/passwordreset.json" 2>/dev/null) || true
    [[ -n "$pin" ]] || die "no reset PIN in $CONFIG_ROOT/jellyfin/passwordreset.json (is $WEBUI_USERNAME a Jellyfin user?)"
    jf POST /Users/ForgotPassword/Pin "$(jq -cn --arg p "$pin" '{Pin:$p}')" >/dev/null
    session=$(jf POST /Users/AuthenticateByName "$(jq -cn --arg u "$WEBUI_USERNAME" '{Username:$u, Pw:""}')") \
      || die "login still refused after the reset; check: docker compose logs jellyfin"
    JELLYFIN_TOKEN=$(jq -r .AccessToken <<<"$session")
    jf POST /Users/Password "$(jq -cn --arg p "$WEBUI_PASSWORD" '{CurrentPw:"", NewPw:$p}')" >/dev/null
    session=$(jf POST /Users/AuthenticateByName "$login") || die "new credentials do not work"
    ok "Web UI login set"
  else
    skip "login with the credentials from .env"
  fi
  JELLYFIN_TOKEN=$(jq -r .AccessToken <<<"$session")
  local admin_id; admin_id=$(jq -r .User.Id <<<"$session")

  local folders; folders=$(jf GET /Library/VirtualFolders)
  add_jf_library() {             # add_jf_library NAME TYPE PATH [ONLINE_METADATA] [METADATA_LANGUAGE] [TRICKPLAY]
    local lang=${5:-en} trick=${6:-false}
    if jq -e --arg p "$3" '[.[].Locations[]] | index($p) != null' <<<"$folders" >/dev/null; then
      # Existing library: metadata language (the dubbed libraries follow
      # DUB_LANGUAGE) and the trickplay switch are kept in line; a language
      # change triggers a metadata refresh.
      local lib have
      lib=$(jq -c --arg p "$3" '.[] | select(.Locations | index($p))' <<<"$folders")
      have=$(jq -r '"\(.LibraryOptions.PreferredMetadataLanguage) \(.LibraryOptions.EnableTrickplayImageExtraction)"' <<<"$lib")
      if [[ "$have" == "$lang $trick" ]]; then
        skip "library $1 ($3)"
      else
        jf POST /Library/VirtualFolders/LibraryOptions \
          "$(jq -c --arg l "$lang" --argjson t "$trick" '{Id: .ItemId, LibraryOptions: (.LibraryOptions | .PreferredMetadataLanguage = $l | .EnableTrickplayImageExtraction = $t | .ExtractTrickplayImagesDuringLibraryScan = false)}' <<<"$lib")" >/dev/null
        if [[ "${have%% *}" != "$lang" ]]; then
          jf POST "/Items/$(jq -r .ItemId <<<"$lib")/Refresh?metadataRefreshMode=FullRefresh&replaceAllMetadata=true" >/dev/null
          ok "library $1: metadata language $lang (refresh started), trickplay $trick"
        else
          ok "library $1: trickplay $trick"
        fi
      fi
      return
    fi
    # Options not named here default to off, so what matters is explicit.
    local opts
    opts=$(jq -cn --arg p "$3" --arg cc "${cc^^}" --argjson online "${4:-true}" --arg l "$lang" --argjson t "$trick" '{LibraryOptions: {
      PathInfos: [{Path: $p}], EnableInternetProviders: $online, MetadataCountryCode: $cc,
      PreferredMetadataLanguage: $l, EnableRealtimeMonitor: true, EnableAutomaticSeriesGrouping: true,
      EnableChapterImageExtraction: false, EnableTrickplayImageExtraction: $t, ExtractTrickplayImagesDuringLibraryScan: false }}')
    jf POST "/Library/VirtualFolders?name=$(urlenc "$1")&collectionType=$2&refreshLibrary=true" "$opts" >/dev/null
    ok "library $1 -> $3 (metadata in $lang, trickplay $trick)"
  }
  # Trickplay (scrub previews) on the film and series libraries, built by the
  # nightly "Generate Trickplay Images" task (03:00), not during scans.
  add_jf_library "Movies"   movies  /data/media/movies true en true
  add_jf_library "TV Shows" tvshows /data/media/tv     true en true
  add_jf_library "Music"    music   /data/media/music
  if [[ -n "$DUB_CODE" ]]; then
    local dub; dub=$(dub_name "$DUB_CODE")
    # Dubbed libraries carry their metadata in that language too.
    add_jf_library "Movies ($dub)"   movies  "/data/media/movies-$DUB_CODE" true "$DUB_CODE" true
    add_jf_library "TV Shows ($dub)" tvshows "/data/media/tv-$DUB_CODE"     true "$DUB_CODE" true
  fi

  # One-time defaults for the administrator, the things the web UI offers no
  # "for everyone" switch for: preferred subtitle language from .env, missing
  # episodes visible (Sonarr-driven libraries show what is still to come),
  # dark dashboard, next-episode overlay, episode stills in Next Up. Applied
  # once and marked, so whatever is changed in the UI afterwards stays.
  local prefs
  prefs=$(jf GET "/DisplayPreferences/usersettings?userId=$admin_id&client=emby")
  if jq -e '.CustomPrefs.mediaStackDefaults == "1"' <<<"$prefs" >/dev/null; then
    skip "administrator defaults (subtitles, missing episodes, web UI)"
  else
    local sub3; sub3=$(iso639_2 "${SUBTITLE_LANGUAGES%%,*}")
    jf POST "/Users/Configuration?userId=$admin_id" \
      "$(jf GET /Users/Me | jq -c --arg s "$sub3" '.Configuration | .SubtitleLanguagePreference = $s | .DisplayMissingEpisodes = true')" >/dev/null
    jf POST "/DisplayPreferences/usersettings?userId=$admin_id&client=emby" \
      "$(jq -c '.CustomPrefs += {dashboardTheme: "dark", enableNextVideoInfoOverlay: "True", useEpisodeImagesInNextUpAndResume: "true", mediaStackDefaults: "1"}' <<<"$prefs")" >/dev/null
    ok "administrator defaults: subtitles $sub3, missing episodes shown, dark dashboard, next-episode overlay, episode stills in Next Up"
  fi

  if [[ -n "$(jellyfin_rich_ux "$admin_id")" ]]; then ok "administrator: rich display settings"; else skip "administrator: rich display settings"; fi
  configure_jellyfin_users

  # jellyfin_plugin NAME [REPO_NAME REPO_URL]: make sure a plugin is installed,
  # adding its repository first when it is not in Jellyfin's own catalogue.
  # Installed plugins load after a restart, done once at the end.
  local plugins_installed=0
  jellyfin_plugin() {
    local name=$1 rname=${2:-} rurl=${3:-} repos ver
    if [[ -n "$rurl" ]]; then
      repos=$(jf GET /Repositories)
      if ! jq -e --arg u "$rurl" 'any(.[]; .Url == $u)' <<<"$repos" >/dev/null; then
        jf POST /Repositories "$(jq -c --arg n "$rname" --arg u "$rurl" '. + [{Name: $n, Url: $u, Enabled: true}]' <<<"$repos")" >/dev/null
        ok "plugin repository $rname"
      fi
    fi
    if jf GET /Plugins | jq -e --arg n "$name" 'any(.[]; .Name == $n)' >/dev/null; then skip "plugin $name"; return; fi
    local pkg
    pkg=$(jf GET /Packages | jq -c --arg n "$name" 'first(.[] | select(.name == $n)) // empty')
    [[ -n "$pkg" ]] || { echo "   WARN plugin $name is not in the catalogue (repository unreachable?)"; return; }
    ver=$(jq -r '.versions[0].version' <<<"$pkg")
    jf POST "/Packages/Installed/$(urlenc "$name")?assemblyGuid=$(jq -r .guid <<<"$pkg")&version=$ver${rurl:+&repositoryUrl=$rurl}" >/dev/null
    ok "plugin $name $ver installed"; plugins_installed=1
  }
  jellyfin_plugin "Fanart"
  jellyfin_plugin "TMDb Box Sets"
  if (( plugins_installed )); then
    docker compose restart jellyfin >/dev/null 2>&1
    local i
    for i in $(seq 1 40); do curl -fsS -o /dev/null "$JELLYFIN_URL/health" 2>/dev/null && break; sleep 3; done
    ok "Jellyfin restarted to load the new plugin(s)"
  fi

  # Hardware transcoding: VA-API when the container can see a render node,
  # i.e. compose.hwaccel.amd.yml is active. Tone mapping (HDR -> SDR) needs an
  # OpenCL runtime the image does not ship for AMD; it stays off.
  if docker compose exec -T jellyfin sh -c 'ls /dev/dri/renderD* >/dev/null 2>&1'; then
    local enc want
    enc=$(jf GET /System/Configuration/encoding)
    want=$(jq -c '.HardwareAccelerationType = "vaapi" | .VaapiDevice = "/dev/dri/renderD128"
      | .EnableHardwareEncoding = true | .AllowHevcEncoding = true | .AllowAv1Encoding = false
      | .EnableDecodingColorDepth10Hevc = true | .EnableDecodingColorDepth10Vp9 = true
      | .HardwareDecodingCodecs = ["h264","hevc","mpeg2video","vc1","vp9","av1"]' <<<"$enc")
    if [[ "$want" == "$(jq -c . <<<"$enc")" ]]; then
      skip "hardware transcoding (VA-API)"
    else
      jf POST /System/Configuration/encoding "$want" >/dev/null
      ok "hardware transcoding: VA-API on /dev/dri/renderD128"
    fi
  else
    echo "        (no GPU in the Jellyfin container: enable a COMPOSE_FILE override in .env for hardware transcoding)"
  fi

  # Trickplay extraction decodes on the GPU when one is there (tile encoding
  # stays on the CPU: VA-API JPEG encoding is not a given on every driver),
  # runs at low priority and never blocks a library scan.
  local sys want_tp hw_decode=false
  [[ "$(jf GET /System/Configuration/encoding | jq -r .HardwareAccelerationType)" == vaapi ]] && hw_decode=true
  sys=$(jf GET /System/Configuration)
  want_tp=$(jq -c --argjson hw "$hw_decode" \
    '.TrickplayOptions | .EnableHwAcceleration = $hw | .EnableHwEncoding = false | .ScanBehavior = "NonBlocking" | .ProcessPriority = "BelowNormal"' <<<"$sys")
  if [[ "$want_tp" == "$(jq -c .TrickplayOptions <<<"$sys")" ]]; then
    skip "trickplay extraction settings"
  else
    jf POST /System/Configuration "$(jq -c --argjson t "$want_tp" '.TrickplayOptions = $t' <<<"$sys")" >/dev/null
    ok "trickplay extraction: GPU decode $(jq -r .EnableHwAcceleration <<<"$want_tp"), low priority, non-blocking"
  fi

  # The reverse proxy connects through Docker's port proxy, so Jellyfin sees
  # the bridge gateway as the client; trusting it as a proxy restores the real
  # client address from X-Forwarded-For.
  local gw net
  gw=$(docker network inspect "$(docker compose config --format json | jq -r '.networks.media.name')" \
       -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)
  if [[ -n "$gw" ]]; then
    net=$(jf GET /System/Configuration/network)
    if jq -e --arg gw "$gw" '.KnownProxies == [$gw]' <<<"$net" >/dev/null; then
      skip "reverse proxy $gw trusted for client addresses"
    else
      jf POST /System/Configuration/network "$(jq -c --arg gw "$gw" '.KnownProxies = [$gw]' <<<"$net")" >/dev/null
      ok "reverse proxy $gw trusted for client addresses"
    fi
  fi

  # The dashboard no longer shows a Jellyfin tile; a key left behind by an
  # earlier version would only be an unused credential.
  local stale
  stale=$(jf GET /Auth/Keys | jq -r '.Items[] | select(.AppName == "Homepage") | .AccessToken' | head -n1)
  if [[ -n "$stale" ]]; then
    jf DELETE "/Auth/Keys/$stale" >/dev/null
    ok "revoked the unused dashboard API key"
  fi
}

# Family accounts from jellyfin-users.json (see jellyfin-users.example.json):
# created when missing, rights and language preferences re-applied on every
# run. Accounts not in the file are left alone; passwords are never touched
# unless "nopass" asks for none.
# The richest per-user experience Jellyfin keeps server-side (web client and
# the TV apps that read these): backdrops, theme songs and videos, details
# banner, next-episode overlay, episode stills in Next Up, Collections view.
# Applied to accounts with "rich" in the users file, and to the administrator.
jellyfin_rich_ux() {              # jellyfin_rich_ux USER_ID -> prints "changed" when something was set
  local id=$1 prefs want changed=0
  prefs=$(jf GET "/DisplayPreferences/usersettings?userId=$id&client=emby")
  # Jellyfin stores some of these back as "True": compare case-insensitively.
  if ! jq -e '[.CustomPrefs.enableBackdrops, .CustomPrefs.enableThemeSongs, .CustomPrefs.enableThemeVideos,
      .CustomPrefs.detailsBanner, .CustomPrefs.enableNextVideoInfoOverlay, .CustomPrefs.useEpisodeImagesInNextUpAndResume]
      | all(. != null and (ascii_downcase == "true"))' <<<"$prefs" >/dev/null; then
    want=$(jq -c '.CustomPrefs += {enableBackdrops: "true", enableThemeSongs: "true", enableThemeVideos: "true",
      detailsBanner: "true", enableNextVideoInfoOverlay: "true", useEpisodeImagesInNextUpAndResume: "true"}' <<<"$prefs")
    jf POST "/DisplayPreferences/usersettings?userId=$id&client=emby" "$want" >/dev/null; changed=1
  fi
  local cfg
  cfg=$(jf GET "/Users/$id" | jq -c .Configuration)
  if [[ "$(jq -r .DisplayCollectionsView <<<"$cfg")" != true ]]; then
    jf POST "/Users/Configuration?userId=$id" "$(jq -c '.DisplayCollectionsView = true' <<<"$cfg")" >/dev/null; changed=1
  fi
  (( changed )) && echo changed || true
}

configure_jellyfin_users() {
  local file=jellyfin-users.json
  if [[ ! -f $file ]]; then
    echo "        (no $file: copy jellyfin-users.example.json to manage family accounts here)"; return
  fi
  jq -e 'type == "array"' "$file" >/dev/null 2>&1 || { echo "   WARN $file is not a JSON array - skipped"; return; }
  local folders users entry name role rating flags libs audio subs
  folders=$(jf GET /Library/VirtualFolders | jq -c '[.[] | {id: .ItemId, name: .Name}]')
  users=$(jf GET /Users)
  while IFS= read -r entry; do
    name=$(jq -r '.name // empty' <<<"$entry"); [[ -n "$name" ]] || continue
    role=$(jq -r '.role // empty' <<<"$entry"); rating=$(jq -r '.rating // empty' <<<"$entry")
    # Boolean fields become the flag list the rest of this function works with.
    flags=$(jq -r '. as $e | ["livetv","channels","hidden","nopass","rich"] | map(select($e[.] == true)) | join(",")' <<<"$entry")
    libs=$(jq -r 'if (.libraries|type) == "array" then (.libraries | join(",")) else (.libraries // "") end' <<<"$entry")
    audio=$(jq -r '.audio // empty' <<<"$entry"); subs=$(jq -r '.subtitles // empty' <<<"$entry")
    case "$role" in admin|adult|child) ;; *) echo "   WARN $file: '$name' has role '$role' (admin|adult|child) - skipped"; continue ;; esac
    local id created=0
    id=$(jq -r --arg n "$name" '.[] | select(.Name == $n) | .Id' <<<"$users")
    if [[ -z "$id" ]]; then
      id=$(jf POST /Users/New "$(jq -cn --arg n "$name" '{Name: $n}')" | jq -r .Id)
      [[ -n "$id" && $id != null ]] || { echo "   WARN could not create user $name"; continue; }
      created=1
    fi
    # Library ids from names; unknown names are reported, not silently dropped.
    local folder_ids all_folders=false
    if [[ ${libs,,} == all ]]; then all_folders=true; folder_ids='[]'; else
      folder_ids=$(jq -cn --arg l "$libs" --argjson f "$folders" '[$l | split(",") | .[] | gsub("^\\s+|\\s+$"; "") | . as $n | ($f[] | select(.name == $n) | .id) // ("?" + $n)]')
      for miss in $(jq -r '.[] | select(startswith("?")) | .[1:]' <<<"$folder_ids"); do echo "   WARN $file: library '$miss' for $name does not exist"; done
      folder_ids=$(jq -c '[.[] | select(startswith("?") | not)]' <<<"$folder_ids")
    fi
    local before after policy
    before=$(jf GET "/Users/$id")
    policy=$(jq -c --arg role "$role" --arg rating "$rating" --arg flags ",$flags," --argjson all "$all_folders" --argjson ids "$folder_ids" '
      .Policy
      | .IsAdministrator = ($role == "admin")
      | .IsHidden = ($flags | test(",hidden,"))
      | .EnableLiveTvAccess = ($role == "admin" or ($flags | test(",livetv,")))
      | .EnableLiveTvManagement = ($role == "admin")
      | .EnableContentDeletion = ($role == "admin")
      | .EnableRemoteControlOfOtherUsers = ($role == "admin")
      | .EnableSubtitleManagement = ($role == "admin") | .EnableCollectionManagement = ($role == "admin")
      | .SyncPlayAccess = (if $role == "child" then "None" else "CreateAndJoinGroups" end)
      | .MaxParentalRating = (if $role == "child" and $rating != "" then ($rating | tonumber) else null end)
      | .BlockUnratedItems = (if $role == "child" then ["Book","ChannelContent","LiveTvChannel","Movie","Music","Trailer","Series"] else [] end)
      | .EnableAllFolders = ($role == "admin" or $all) | .EnabledFolders = (if $role == "admin" or $all then [] else $ids end)
      | .EnableAllChannels = ($role == "admin" or ($flags | test(",channels,"))) | .EnabledChannels = []' <<<"$before")
    jf POST "/Users/$id/Policy" "$policy" >/dev/null
    jf POST "/Users/Configuration?userId=$id" "$(jq -c --arg a "$audio" --arg s "$subs" '
      .Configuration
      | .AudioLanguagePreference = $a | .PlayDefaultAudioTrack = ($a == "")
      | .SubtitleLanguagePreference = $s | .SubtitleMode = (if $s == "" then "Default" else "Always" end)' <<<"$before")" >/dev/null
    # nopass: sign in without a password (avatar tap on the TV). A password
    # set in the UI is removed again; without the flag passwords are never
    # touched. Jellyfin 12 no longer fills HasPassword, so the state is probed
    # with an empty-password sign-in. Administrators cannot be passwordless.
    local pw_note=""
    if [[ ",$flags," == *,nopass,* && $role != admin ]]; then
      local probe
      probe=$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: MediaBrowser Client="configure.sh", Device="probe", DeviceId="media-stack-probe", Version="1"' \
        -H 'Content-Type: application/json' -X POST "$JELLYFIN_URL/Users/AuthenticateByName" --data "$(jq -cn --arg n "$name" '{Username:$n, Pw:""}')")
      if [[ $probe != 200 ]]; then
        jf POST "/Users/Password?userId=$id" '{"ResetPassword": true}' >/dev/null && pw_note=" (password removed)"
      fi
    elif [[ ",$flags," == *,nopass,* ]]; then
      echo "   WARN $file: '$name' is an admin; Jellyfin refuses an empty password for administrators"
    fi
    local ux_note=""
    [[ ",$flags," == *,rich,* ]] && [[ -n "$(jellyfin_rich_ux "$id")" ]] && ux_note=" (display settings set)"
    after=$(jf GET "/Users/$id")
    local summary="$role${rating:+ $rating}${flags:+, $flags}; ${libs}${audio:+; audio $audio}${subs:+; subtitles $subs}$pw_note$ux_note"
    if (( created )); then ok "user $name created ($summary) - set a password in Dashboard > Users"
    elif [[ -z "$pw_note$ux_note" && "$(jq -c '{Policy, Configuration}' <<<"$before")" == "$(jq -c '{Policy, Configuration}' <<<"$after")" ]]; then skip "user $name ($summary)"
    else ok "user $name updated ($summary)"; fi
  done < <(jq -c '.[] | select(.name)' "$file")
}
