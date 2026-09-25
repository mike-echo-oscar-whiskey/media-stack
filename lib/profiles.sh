# What a film or episode should be, and the profiles that carry it.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.
#
# Quality itself belongs to Recyclarr (lib/recyclarr.sh): the definitions, the
# custom-format collection and the four profiles per app come from the TRaSH
# Guides and are re-synced on a schedule. What lives here is what the guides do
# not cover: a dubbed twin of every profile, which profile is the default, and
# the guards against fakes, cams, screeners and upscales.

# ---------------------------------------------------------------- the plan
# MEDIA_QUALITY names the default of the four the guides build:
#
#   1080p-encode   1080p from Bluray and WEB, no remux
#   1080p-remux    1080p including the untouched disc
#   2160p-encode   2160p ("4K") from Bluray and WEB
#   2160p-remux    2160p including the untouched disc
#
# It is only the default: Seerr asks with it, and a film or series sitting on
# one of the apps' own stock profiles is moved onto it. Any title can be put on
# one of the others by hand, or in Seerr under "Advanced". 8K has no quality
# tier in Radarr or Sonarr, so it cannot be asked for yet.
QUALITY_VARIANTS='1080p-encode 1080p-remux 2160p-encode 2160p-remux'
# The stock profiles, the only ones anything is moved off.
Q_STOCK='["Any","SD","HD-720p","HD-1080p","Ultra-HD","HD - 720p/1080p"]'

quality_plan() {
  log "Quality"
  Q_DEFAULT=${MEDIA_QUALITY:-1080p-encode}
  case " $QUALITY_VARIANTS " in
    *" $Q_DEFAULT "*) ;;
    *) die "MEDIA_QUALITY must be one of: $QUALITY_VARIANTS (got \"$Q_DEFAULT\")" ;;
  esac
  # Seerr asks with the default unless .env names a profile itself.
  SEERR_QUALITY_PROFILE=${SEERR_QUALITY_PROFILE:-$(recyclarr_profile radarr "$Q_DEFAULT")}
  ok "default $Q_DEFAULT: \"$(recyclarr_profile radarr "$Q_DEFAULT")\" in Radarr, \"$(recyclarr_profile sonarr "$Q_DEFAULT")\" in Sonarr"
  ok "the other three stay available per title${DUB_CODE:+, each with a ${DUB_CODE^^}-DUB twin}"
}

# ---------------------------------------------------------------- custom formats
# cf_begin sets the app every cf_* call below works on; each of them prints its
# own ok/kept line to stderr and the format's id to stdout, so the caller can
# score it.
cf_begin() {                      # cf_begin APP URL
  CF_APP=$1 CF_URL=$2
  CF_KEY=$(xml_apikey "$1")
  CF_SCHEMA=$(arr "$CF_KEY" GET "$CF_URL/api/v3/customformat/schema")
  CF_FMT=$(arr "$CF_KEY" GET "$CF_URL/api/v3/customformat")
}
cf_post() {                       # cf_post BODY -> id
  local id
  id=$(arr "$CF_KEY" POST "$CF_URL/api/v3/customformat" "$1" | jq -r '.id // empty')
  [[ -n "$id" ]] || die "could not create a custom format in $CF_APP"
  CF_FMT=$(arr "$CF_KEY" GET "$CF_URL/api/v3/customformat")
  printf '%s' "$id"
}
cf_title() {                      # cf_title NAME REGEX -> id
  local id
  id=$(jq -r --arg n "$1" 'first(.[] | select(.name == $n)) | .id // empty' <<<"$CF_FMT")
  if [[ -n "$id" ]]; then skip "custom format \"$1\"" >&2; printf '%s' "$id"; return; fi
  id=$(cf_post "$(jq -c --arg n "$1" --arg re "$2" '
    {name:$n, includeCustomFormatWhenRenaming:false,
     specifications:[ first(.[] | select(.implementation == "ReleaseTitleSpecification"))
       | del(.presets, .infoLink, .implementationName)
       | .name = $n | .negate = false | .required = true
       | .fields |= map(if .name == "value" then .value = $re else . end) ]}' <<<"$CF_SCHEMA")")
  ok "custom format \"$1\"" >&2
  printf '%s' "$id"
}
cf_language() {                   # cf_language NAME '[LANGUAGE_ID, ...]' -> id
  # One condition per language id. They are all LanguageSpecification, so they
  # OR: a twin that wants Portuguese accepts a release in "Portuguese (Brazil)"
  # too. required stays false for that reason - true would AND them and no
  # release carries two languages at once.
  local id wanted current shape
  wanted=$(jq -c --arg n "$1" --argjson ids "$2" '. as $s |
    {name:$n, includeCustomFormatWhenRenaming:false,
     specifications:[ $ids[] as $l
       | first($s[] | select(.implementation == "LanguageSpecification"))
       | del(.presets, .infoLink, .implementationName)
       | .name = ($l|tostring) | .negate = false | .required = false
       | .fields |= map(if .name == "value" then .value = $l else . end) ]}' <<<"$CF_SCHEMA")
  current=$(jq -c --arg n "$1" 'first(.[] | select(.name == $n)) // empty' <<<"$CF_FMT")
  if [[ -z "$current" ]]; then
    id=$(cf_post "$wanted"); ok "custom format \"$1\"" >&2; printf '%s' "$id"; return
  fi
  id=$(jq -r .id <<<"$current")
  # Compare the languages themselves, not the schema noise around them.
  shape='[.specifications[] | .fields[] | select(.name == "value") | .value] | sort'
  if [[ "$(jq -c "$shape" <<<"$current")" == "$(jq -c "$shape" <<<"$wanted")" ]]; then
    skip "custom format \"$1\"" >&2
  else
    arr "$CF_KEY" PUT "$CF_URL/api/v3/customformat/$id" "$(jq -c --argjson i "$id" '.id = $i' <<<"$wanted")" >/dev/null
    ok "custom format \"$1\" (languages brought in line)" >&2
  fi
  printf '%s' "$id"
}
# ---------------------------------------------------------------- dubbed twins
# A copy of each guide profile that also requires DUB_LANGUAGE audio, with its
# own root folder so the dubbed copy lives next to the original. A release
# without that audio track scores below the minimum and is refused, so nothing
# is grabbed until a dubbed release exists. Chosen per request in Seerr under
# "Advanced"; nothing here decides it for you.
#
# The dub formats score above everything the guide's own formats can add up to,
# and the minimum is set to match, so no combination of release group, audio
# and streaming-service scores can satisfy a dubbed profile without the dub.
#
# A twin is a derived copy: it is rewritten whenever the profile it follows
# changes, so tune the guide profile rather than its twin.
configure_dub_profiles() {        # configure_dub_profiles APP URL [ROOT HOSTROOT]
  local app=$1 url=$2 root=${3:-} hostroot=${4:-} v base
  log "$app - dubbed twins and the default"
  cf_begin "$app" "$url"
  if [[ -n "$DUB_CODE" ]]; then
    dub_formats "$url"
    if [[ -n "$root" ]]; then
      mkdir -p "$hostroot"
      if arr "$CF_KEY" GET "$url/api/v3/rootfolder" | jq -e --arg p "$root" 'any(.[]; .path == $p)' >/dev/null; then
        skip "root folder $root"
      else
        arr "$CF_KEY" POST "$url/api/v3/rootfolder" "$(jq -cn --arg p "$root" '{path:$p}')" >/dev/null
        ok "root folder $root"
      fi
    fi
    for v in $QUALITY_VARIANTS; do
      base=$(recyclarr_profile "$app" "$v")
      dub_twin "$base" "$v"
    done
  fi
  move_to_managed_profile "$app" "$url"
}

# The two formats that recognise the language: the one the parser reports, and
# the spellings it leaves as Unknown (NLD, "NL Gesproken"). Either one matching
# is enough. Deliberately without the bare language word, which the language
# format already covers and which would also match a film called "The Dutch
# Job". Sets DUB_IDS.
dub_formats() {                   # dub_formats URL
  local url=$1 lang langs known ids audio title regex name
  lang=$(dub_name "$DUB_CODE")
  [[ -n "$lang" ]] || die "DUB_LANGUAGE=$DUB_CODE is not one of the codes this script knows (see .env.example)"
  known=$(arr "$CF_KEY" GET "$url/api/v3/language")
  langs=$(dub_languages "$DUB_CODE")
  ids='[]'
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local one
    one=$(jq -r --arg l "$name" 'first(.[] | select(.name == $l)) | .id // empty' <<<"$known")
    # A regional variant the app does not carry is simply left out.
    [[ -n "$one" ]] && ids=$(jq -c --argjson i "$one" '. + [$i]' <<<"$ids")
  done <<<"$langs"
  [[ "$ids" != "[]" ]] || die "$CF_APP does not know the language \"$lang\""
  audio=$(cf_language "$lang Audio" "$ids")
  regex=$(dub_title_regex "$DUB_CODE")
  if [[ -n "$regex" ]]; then title=$(cf_title "$lang Dub (title)" "$regex"); fi
  DUB_IDS=$(jq -cn --argjson a "$audio" --arg t "${title:-}" \
    '[$a] + (if $t == "" then [] else [($t|tonumber)] end)')
}

dub_twin() {                      # dub_twin GUIDE_PROFILE VARIANT
  local base=$1 variant=$2 name profiles source existing legacy wanted id was
  name="$base (${DUB_CODE^^}-DUB)"
  profiles=$(arr "$CF_KEY" GET "$CF_URL/api/v3/qualityprofile")
  source=$(jq -c --arg n "$base" 'first(.[] | select(.name == $n)) // empty' <<<"$profiles")
  [[ -n "$source" ]] || die "Recyclarr has not created the profile \"$base\" in $CF_APP yet"
  # Names this stack used before the guides took over, renamed in place so the
  # films and series pointing at a twin keep pointing at it.
  case $variant in
    1080p-encode) legacy=$(jq -cn --args '$ARGS.positional' "Dutch 1080p" "1080p Encode (${DUB_CODE^^}-DUB)") ;;
    1080p-remux)  legacy=$(jq -cn --args '$ARGS.positional' "1080p Remux (${DUB_CODE^^}-DUB)") ;;
    2160p-encode) legacy=$(jq -cn --args '$ARGS.positional' "2160p Encode (${DUB_CODE^^}-DUB)") ;;
    2160p-remux)  legacy=$(jq -cn --args '$ARGS.positional' "2160p Remux (${DUB_CODE^^}-DUB)") ;;
  esac
  existing=$(jq -c --arg n "$name" --argjson old "$legacy" \
    'first(.[] | . as $p | select($p.name == $n or any($old[]; . == $p.name))) // empty' <<<"$profiles")
  wanted=$(jq -c --arg n "$name" --argjson ids "$DUB_IDS" '
    (([.formatItems[] | select(.score > 0) | .score] | add // 0) + 1000) as $dub
    | .name = $n
    | .minFormatScore = $dub
    | .cutoffFormatScore = (.cutoffFormatScore + $dub)
    | .formatItems |= map(if (.format as $f | $ids | index($f)) then .score = $dub else . end)
    | del(.id)' <<<"$source")
  if [[ -z "$existing" ]]; then
    arr "$CF_KEY" POST "$CF_URL/api/v3/qualityprofile" "$wanted" >/dev/null
    ok "quality profile \"$name\" created"
    return
  fi
  id=$(jq -r .id <<<"$existing"); was=$(jq -r .name <<<"$existing")
  wanted=$(jq -c --argjson id "$id" '.id = $id' <<<"$wanted")
  if [[ "$(jq -cS . <<<"$wanted")" == "$(jq -cS . <<<"$existing")" ]]; then
    skip "quality profile \"$name\""
  else
    arr "$CF_KEY" PUT "$CF_URL/api/v3/qualityprofile/$id" "$wanted" >/dev/null
    if [[ "$was" == "$name" ]]; then ok "quality profile \"$name\" follows \"$base\" again"
    else ok "quality profile \"$name\" (was \"$was\", same profile so nothing moved)"; fi
  fi
}

# Films and series sitting on a profile nobody should be using are moved onto
# the default - that is what makes it the default, including for anything added
# through the app's own UI. Two kinds count: the apps' own stock profiles, and
# the ones this stack managed itself before the guides took over, which are
# deleted once nothing points at them. Put something on a profile of your own,
# or on a dubbed twin, and it stays there.
Q_RETIRED='["HD-1080p Encode","1080p Encode","1080p Remux","2160p Encode","2160p Remux"]'

move_to_managed_profile() {       # move_to_managed_profile APP URL
  local app=$1 url=$2 resource=movie label=films profiles target name off ids count editor left id
  [[ "$app" == sonarr ]] && { resource=series; label=series; }
  name=$(recyclarr_profile "$app" "$Q_DEFAULT")
  profiles=$(arr "$CF_KEY" GET "$url/api/v3/qualityprofile")
  target=$(jq -r --arg n "$name" 'first(.[] | select(.name == $n)) | .id' <<<"$profiles")
  [[ -n "$target" && "$target" != null ]] || die "Recyclarr has not created the profile \"$name\" in $app yet"
  off=$(jq -c --argjson s "$Q_STOCK" --argjson r "$Q_RETIRED" \
        '[.[] | . as $p | select(any(($s + $r)[]; . == $p.name)) | $p.id]' <<<"$profiles")
  ids=$(arr "$CF_KEY" GET "$url/api/v3/$resource" \
        | jq -c --argjson off "$off" '[.[] | select(.qualityProfileId as $p | $off | index($p)) | .id]')
  count=$(jq length <<<"$ids")
  if (( count )); then
    editor=$(jq -cn --argjson ids "$ids" --argjson p "$target" --arg k "${resource}Ids" \
             '{($k): $ids, qualityProfileId: $p}')
    arr "$CF_KEY" PUT "$url/api/v3/$resource/editor" "$editor" >/dev/null
    ok "moved $count $label onto \"$name\" (nothing is re-downloaded)"
  else
    skip "all $label are on \"$name\" or a profile of your own"
  fi
  # The retired ones can go now that nothing uses them.
  left=$(arr "$CF_KEY" GET "$url/api/v3/$resource" | jq -c '[.[] | .qualityProfileId] | unique')
  for id in $(jq -r --argjson r "$Q_RETIRED" '.[] | . as $p | select(any($r[]; . == $p.name)) | $p.id' <<<"$profiles"); do
    jq -e --argjson i "$id" 'index($i)' <<<"$left" >/dev/null && continue
    arr "$CF_KEY" DELETE "$url/api/v3/qualityprofile/$id" >/dev/null 2>&1 \
      && ok "removed the retired profile $(jq -r --argjson i "$id" 'first(.[] | select(.id == $i)) | .name' <<<"$profiles")"
  done
  return 0
}

