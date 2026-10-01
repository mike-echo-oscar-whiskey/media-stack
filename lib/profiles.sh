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
  ok "the other three stay available per title${DUB_CODE:+, all four preferring $(dub_name "$DUB_CODE") beside the original audio}"
}

# ---------------------------------------------------------------- custom formats
# cf_begin sets the app every cf_* call below works on; each of them prints its
# own ok/kept line to stderr and the format's id to stdout, so the caller can
# score it.
cf_begin() {                      # cf_begin APP URL [API_VERSION]
  # The version is a parameter because Lidarr is v1 where the others are v3, and
  # the custom-format endpoints are otherwise identical.
  CF_APP=$1 CF_URL=$2 CF_V=${3:-v3}
  CF_KEY=$(xml_apikey "$1")
  CF_SCHEMA=$(arr "$CF_KEY" GET "$CF_URL/api/$CF_V/customformat/schema")
  CF_FMT=$(arr "$CF_KEY" GET "$CF_URL/api/$CF_V/customformat")
}
cf_post() {                       # cf_post BODY -> id
  local id
  id=$(arr "$CF_KEY" POST "$CF_URL/api/$CF_V/customformat" "$1" | jq -r '.id // empty')
  [[ -n "$id" ]] || die "could not create a custom format in $CF_APP"
  CF_FMT=$(arr "$CF_KEY" GET "$CF_URL/api/$CF_V/customformat")
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
    arr "$CF_KEY" PUT "$CF_URL/api/$CF_V/customformat/$id" "$(jq -c --argjson i "$id" '.id = $i' <<<"$wanted")" >/dev/null
    ok "custom format \"$1\" (languages brought in line)" >&2
  fi
  printf '%s' "$id"
}
# ---------------------------------------------------------------- Lidarr quality
# Music is the one library nothing syncs. TRaSH has no Lidarr data and says so
# outright, pointing instead at Davo's community guide, which is itself an index
# into the Servarr wiki - so there is one community source, no dataset behind it
# and nothing to keep it current. That decides what is worth taking from it.
#
# Taken: the four formats whose meaning cannot rot. Vinyl is a hard block -
# surface noise and a different master are wrong for a library you stream. CD
# and WEB are source preferences on generic, stable words. Lossless is inert
# under the default profile, which allows none, and correct the moment somebody
# switches to the Lossless one - which is the point of shipping configuration
# rather than defaults.
#
# Left: the guide's three preferred release groups, because a hardcoded list of
# scene names with no sync tool goes stale and nothing here would notice - the
# equivalent lists for films and series are safe only because Recyclarr
# refreshes them. And its "minimum custom format score = 1", whose failure mode
# is that nothing is ever grabbed. It is a per-profile setting in Lidarr's UI
# for anyone who wants it, and the README says why this does not set it.
configure_lidarr_formats() {
  log "Lidarr quality"
  local key=$(xml_apikey lidarr)
  [[ -n "$key" ]] || { skip "Lidarr custom formats (no API key)"; return 0; }

  cf_begin lidarr "$LIDARR_URL" v1
  local vinyl cd web lossless
  vinyl=$(cf_title    "Vinyl"    '\bVinyl\b')
  cd=$(cf_title       "CD"       '\bCD\b')
  web=$(cf_title      "WEB"      '\bWEB\b')
  lossless=$(cf_title "Lossless" '\blossless\b')

  # Scores live on the profile, not on the format. Every profile gets them: a
  # release that is a vinyl rip is wrong whichever quality you asked for.
  local scores profiles id name current wanted changed=0
  scores=$(jq -cn --argjson v "$vinyl" --argjson c "$cd" --argjson w "$web" --argjson l "$lossless" \
    '{($v|tostring): -10000, ($c|tostring): 10, ($w|tostring): 5, ($l|tostring): 10}')
  profiles=$(arr "$key" GET "$LIDARR_URL/api/v1/qualityprofile")
  while IFS=$'\t' read -r id name; do
    [[ -n "$id" ]] || continue
    current=$(jq -c --argjson i "$id" 'first(.[] | select(.id == $i))' <<<"$profiles")
    wanted=$(jq -c --argjson s "$scores" '
      .formatItems |= map(.score = ($s[(.format|tostring)] // .score))' <<<"$current")
    if [[ "$(jq -c '[.formatItems[] | {format, score}] | sort_by(.format)' <<<"$current")" \
       == "$(jq -c '[.formatItems[] | {format, score}] | sort_by(.format)' <<<"$wanted")" ]]; then
      skip "scores on \"$name\""
    else
      arr "$key" PUT "$LIDARR_URL/api/v1/qualityprofile/$id" "$wanted" >/dev/null
      ok "scores on \"$name\" (vinyl -10000, CD 10, lossless 10, WEB 5)"
      changed=1
    fi
  done < <(jq -r '.[] | [.id, .name] | @tsv' <<<"$profiles")

  # FLAC size bounds from the same guide. Inert while the profile allows no
  # lossless, correct when it does, and fixed numbers that cannot go stale.
  local defs d did dmax want_max
  defs=$(arr "$key" GET "$LIDARR_URL/api/v1/qualitydefinition")
  for d in "FLAC:1400" "FLAC 24bit:1495"; do
    did=$(jq -r --arg n "${d%%:*}" 'first(.[] | select(.quality.name == $n)) | .id // empty' <<<"$defs")
    [[ -n "$did" ]] || continue
    want_max=${d##*:}
    dmax=$(jq -r --argjson i "$did" 'first(.[] | select(.id == $i)) | .maxSize // "null"' <<<"$defs")
    if [[ "$dmax" == "$want_max" ]]; then
      skip "${d%%:*} size ceiling"
    else
      arr "$key" PUT "$LIDARR_URL/api/v1/qualitydefinition/$did" \
        "$(jq -c --argjson i "$did" --argjson m "$want_max" \
           'first(.[] | select(.id == $i)) | .maxSize = $m' <<<"$defs")" >/dev/null
      ok "${d%%:*} size ceiling $want_max MB/min"
    fi
  done
  return 0
}

# ---------------------------------------------------------------- dubbed audio
# One file carrying the original audio and DUB_LANGUAGE, in the ordinary
# library. No second profile, no second root folder, no second Plex library.
#
# This follows TRaSH's own [French MULTi.VO] profiles. Those exist for French
# and German and for no other language - the guides ship no Dutch language
# format at all - so the two formats in dub_formats are ours and the shape
# around them is theirs:
#
#   - Bluray is folded into the WEB group at the same resolution. Quality rank
#     beats custom-format score, so without the merge a preference could never
#     pick a multi-language WEB-DL over an English-only Bluray - and the
#     multi-language masters are streaming rips. Remux stays above the group.
#   - "Language: Not Original" scores -10000, so a release that dropped the
#     original audio is refused. That is what keeps English in the file. The
#     format and the score are the guides' own and Recyclarr syncs both; only
#     the group that carries it is asked for here.
#   - The dub formats score +500: a preference, never a requirement.
#     minFormatScore stays at the guide's 0, so a film with no dub available
#     downloads exactly as it did before.
#
# See README "Dubbed audio (the original language plus one more)".
DUB_SCORE=500
# The most an existing file can gain from this change is the dub (500) plus the
# spread across the guides' release-group tiers (1800 down to 1600). Demanding
# more than that before an upgrade means nothing already on disk is re-grabbed
# just to pick up a second audio track, while a file sitting on a -10000
# penalty still upgrades, because that gain is far larger.
DUB_UPGRADE_FLOOR=$(( DUB_SCORE + 201 ))

configure_dub_preference() {      # configure_dub_preference APP URL
  local app=$1 url=$2 v
  log "$app - quality profiles and the default"
  cf_begin "$app" "$url"
  if [[ -n "$DUB_CODE" ]]; then
    dub_formats "$url"
    for v in $QUALITY_VARIANTS; do
      dub_prefer "$(recyclarr_profile "$app" "$v")"
    done
    retire_dub_twins "$app" "$url"
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

# Only the three scores. The quality merge is written into Recyclarr's own
# config instead (lib/recyclarr-config.py), because Recyclarr syncs nightly and
# puts a hand-merged profile straight back. Scores are the opposite case:
# reset_unmatched_scores is false in the configs it writes, so a score for a
# format it does not know survives its sync, and these are ours.
dub_prefer() {                    # dub_prefer GUIDE_PROFILE
  local base=$1 profiles current wanted id
  profiles=$(arr "$CF_KEY" GET "$CF_URL/api/v3/qualityprofile")
  current=$(jq -c --arg n "$base" 'first(.[] | select(.name == $n)) // empty' <<<"$profiles")
  [[ -n "$current" ]] || die "Recyclarr has not created the profile \"$base\" in $CF_APP yet"
  id=$(jq -r .id <<<"$current")
  # Only the dub formats. "Language: Not Original" is the guides' own and
  # Recyclarr now syncs it, score included, through the [Optional] Language
  # Profiles group in lib/recyclarr-config.py - so setting it here as well would
  # be two owners for one number.
  wanted=$(jq -c --argjson dub "$DUB_IDS" --argjson s "$DUB_SCORE" '
    .formatItems |= map(
      if (.format as $i | $dub | index($i)) then .score = $s else . end)' <<<"$current")
  if [[ "$(jq -cS . <<<"$wanted")" == "$(jq -cS . <<<"$current")" ]]; then
    skip "quality profile \"$base\""
  else
    arr "$CF_KEY" PUT "$CF_URL/api/v3/qualityprofile/$id" "$wanted" >/dev/null
    ok "quality profile \"$base\" prefers $(dub_name "$DUB_CODE") beside the original audio"
  fi
}

# The twins this stack used to build, and the root folder they wrote to. Both
# are gone; whatever still points at one is moved onto the ordinary profile
# before the twin is deleted. Idempotent: on a stack that never had them, or on
# a second run, there is nothing to find.
#
# Two things make this less obvious than it looks. A film that lives in another
# root folder - the archive tier - keeps the folder it has, because relocating
# it would drag the file back out of the cloud and the mover would then push it
# up again. And in Radarr a **collection** carries a quality profile of its own,
# so a twin with no film left on it is still "in use" and the delete answers
# 500 until the collections are repointed too.
retire_dub_twins() {              # retire_dub_twins APP URL
  local app=$1 url=$2 resource=movie label=films profiles twins target name
  local root nlroot here elsewhere editor count folders id fid cols
  [[ "$app" == sonarr ]] && { resource=series; label=series; }
  profiles=$(arr "$CF_KEY" GET "$url/api/v3/qualityprofile")
  twins=$(jq -c --arg s " (${DUB_CODE^^}-DUB)" '[.[] | select(.name | endswith($s)) | .id]' <<<"$profiles")
  [[ "$(jq length <<<"$twins")" != 0 ]] || { skip "no ${DUB_CODE^^}-DUB twins left to retire"; return 0; }
  name=$(recyclarr_profile "$app" "$Q_DEFAULT")
  target=$(jq -r --arg n "$name" 'first(.[] | select(.name == $n)) | .id' <<<"$profiles")
  [[ -n "$target" && "$target" != null ]] || die "Recyclarr has not created the profile \"$name\" in $app yet"
  case $app in
    radarr) root=/data/media/movies ;;
    sonarr) root=/data/media/tv ;;
  esac
  nlroot="${root}-$DUB_CODE"

  # Split by where the title actually lives: only the ones inside the retired
  # root are relocated, and moveFiles lets the app do the move itself so the
  # database and the disk cannot disagree.
  here=$(arr "$CF_KEY" GET "$url/api/v3/$resource" | jq -c --argjson t "$twins" --arg r "$nlroot" \
         '[.[] | select(.qualityProfileId as $p | $t | index($p)) | select(.path | startswith($r)) | .id]')
  elsewhere=$(arr "$CF_KEY" GET "$url/api/v3/$resource" | jq -c --argjson t "$twins" --arg r "$nlroot" \
         '[.[] | select(.qualityProfileId as $p | $t | index($p)) | select(.path | startswith($r) | not) | .id]')
  count=$(jq length <<<"$here")
  if (( count )); then
    editor=$(jq -cn --argjson ids "$here" --argjson p "$target" --arg r "$root" --arg k "${resource}Ids" \
             '{($k): $ids, qualityProfileId: $p, rootFolderPath: $r, moveFiles: true}')
    arr "$CF_KEY" PUT "$url/api/v3/$resource/editor" "$editor" >/dev/null
    ok "moved $count $label out of $nlroot into $root, onto \"$name\""
  fi
  count=$(jq length <<<"$elsewhere")
  if (( count )); then
    editor=$(jq -cn --argjson ids "$elsewhere" --argjson p "$target" --arg k "${resource}Ids" \
             '{($k): $ids, qualityProfileId: $p}')
    arr "$CF_KEY" PUT "$url/api/v3/$resource/editor" "$editor" >/dev/null
    ok "moved $count $label onto \"$name\", each keeping the root folder it is in"
  fi

  # Radarr only: a collection holds a profile too, and holds the twin open.
  if [[ "$app" == radarr ]]; then
    cols=$(arr "$CF_KEY" GET "$url/api/v3/collection" \
           | jq -c --argjson t "$twins" '[.[] | select(.qualityProfileId as $p | $t | index($p))]')
    count=$(jq length <<<"$cols")
    if (( count )); then
      for id in $(jq -r '.[].id' <<<"$cols"); do
        arr "$CF_KEY" PUT "$url/api/v3/collection/$id" \
          "$(jq -c --argjson i "$id" --argjson p "$target" \
             'first(.[] | select(.id == $i)) | .qualityProfileId = $p' <<<"$cols")" >/dev/null
      done
      ok "repointed $count collection(s) onto \"$name\""
    fi
  fi

  for id in $(jq -r '.[]' <<<"$twins"); do
    arr "$CF_KEY" DELETE "$url/api/v3/qualityprofile/$id" >/dev/null 2>&1 \
      && ok "removed the twin $(jq -r --argjson i "$id" 'first(.[] | select(.id == $i)) | .name' <<<"$profiles")" \
      || ok "the twin $(jq -r --argjson i "$id" 'first(.[] | select(.id == $i)) | .name' <<<"$profiles") is still in use - left in place"
  done
  # The root folder the twins wrote to goes with them.
  folders=$(arr "$CF_KEY" GET "$url/api/v3/rootfolder")
  fid=$(jq -r --arg p "$nlroot" 'first(.[] | select(.path == $p)) | .id // empty' <<<"$folders")
  if [[ -n "$fid" ]]; then
    arr "$CF_KEY" DELETE "$url/api/v3/rootfolder/$fid" >/dev/null 2>&1 \
      && ok "removed the root folder $nlroot"
  fi
  return 0
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
  # Radarr collections carry a root folder of their own, as well as a quality
  # profile. Retiring a root folder therefore leaves them pointing at a path that
  # no longer exists, and Radarr reports it as a health error naming each one -
  # "Missing root folder for movie collection". Films were repointed and
  # collections were not, because the two live in different endpoints and only
  # the profile was shared between them.
  if [[ "$app" == radarr ]]; then
    local roots default cols stranded
    roots=$(arr "$CF_KEY" GET "$url/api/v3/rootfolder" | jq -c '[.[].path]')
    default=$(jq -r '.[0] // empty' <<<"$roots")
    if [[ -n "$default" ]]; then
      cols=$(arr "$CF_KEY" GET "$url/api/v3/collection" \
             | jq -c --argjson r "$roots" '[.[] | select((.rootFolderPath // "") as $p | ($r | index($p)) == null)]')
      stranded=$(jq length <<<"$cols")
      if (( stranded )); then
        local one cid
        for cid in $(jq -r '.[].id' <<<"$cols"); do
          one=$(jq -c --argjson i "$cid" --arg p "$default" 'first(.[] | select(.id == $i)) | .rootFolderPath = $p' <<<"$cols")
          arr "$CF_KEY" PUT "$url/api/v3/collection/$cid" "$one" >/dev/null
        done
        ok "moved $stranded collection(s) onto $default - their root folder was gone"
      fi
    fi
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


# Some posters title a spot with no quality at all - "Ik Vertrek S27E07 2026" -
# and Sonarr parses that as Unknown, which every guide profile refuses. The
# episode is therefore found and then thrown away. About one in seven Dutch TV
# spots is posted that way, usually season packs written in prose.
#
# Allowing Unknown on the shared profile would accept anything unparseable from
# every indexer, so instead the series listed in SONARR_ALLOW_UNKNOWN_TVDBIDS
# get their own copy of the default profile that also accepts it. The copy
# follows the guide profile on every run, so it keeps whatever Recyclarr does to
# the original. See README "Quality: profiles, formats and guards".
configure_allow_unknown() {       # configure_allow_unknown URL
  local url=$1 ids=${SONARR_ALLOW_UNKNOWN_TVDBIDS:-}
  local key base name profiles source existing wanted pid series cur tvdb sid
  log "Sonarr - series posted without a quality"
  ids=${ids// /}
  if [[ -z "$ids" ]]; then
    skip "no SONARR_ALLOW_UNKNOWN_TVDBIDS - every series uses the shared profile"
    return 0
  fi
  key=$(xml_apikey sonarr)
  [[ -n "$key" ]] || { printf '   WARN sonarr has no API key yet\n'; return 0; }
  base=$(recyclarr_profile sonarr "$Q_DEFAULT")
  name="$base (+ unknown)"

  profiles=$(arr "$key" GET "$url/api/v3/qualityprofile")
  source=$(jq -c --arg n "$base" 'first(.[] | select(.name == $n)) // empty' <<<"$profiles")
  [[ -n "$source" ]] || { printf '   WARN Recyclarr has not created "%s" yet\n' "$base"; return 0; }
  wanted=$(jq -c --arg n "$name" '
    .name = $n
    | .items |= map(if (.quality.name? // "") == "Unknown" then .allowed = true else . end)
    | del(.id)' <<<"$source")
  existing=$(jq -c --arg n "$name" 'first(.[] | select(.name == $n)) // empty' <<<"$profiles")
  if [[ -z "$existing" ]]; then
    arr "$key" POST "$url/api/v3/qualityprofile" "$wanted" >/dev/null
    ok "quality profile \"$name\" created"
    existing=$(arr "$key" GET "$url/api/v3/qualityprofile" \
               | jq -c --arg n "$name" 'first(.[] | select(.name == $n))')
  else
    pid=$(jq -r .id <<<"$existing")
    wanted=$(jq -c --argjson id "$pid" '.id = $id' <<<"$wanted")
    if [[ "$(jq -cS . <<<"$wanted")" == "$(jq -cS . <<<"$existing")" ]]; then
      skip "quality profile \"$name\""
    else
      arr "$key" PUT "$url/api/v3/qualityprofile/$pid" "$wanted" >/dev/null
      ok "quality profile \"$name\" follows \"$base\" again"
    fi
  fi
  pid=$(jq -r .id <<<"$existing")

  series=$(arr "$key" GET "$url/api/v3/series")
  for tvdb in ${ids//,/ }; do
    if [[ ! "$tvdb" =~ ^[0-9]+$ ]]; then
      printf '   WARN SONARR_ALLOW_UNKNOWN_TVDBIDS takes TVDB ids (got "%s")\n' "$tvdb"
      continue
    fi
    cur=$(jq -c --argjson t "$tvdb" 'first(.[] | select(.tvdbId == $t)) // empty' <<<"$series")
    if [[ -z "$cur" ]]; then
      echo "        (tvdb $tvdb is not in the library)"
    elif [[ "$(jq -r .qualityProfileId <<<"$cur")" == "$pid" ]]; then
      skip "$(jq -r .title <<<"$cur")"
    else
      sid=$(jq -r .id <<<"$cur")
      arr "$key" PUT "$url/api/v3/series/$sid" \
        "$(jq -c --argjson p "$pid" '.qualityProfileId = $p' <<<"$cur")" >/dev/null
      ok "$(jq -r .title <<<"$cur") -> \"$name\""
    fi
  done
}
