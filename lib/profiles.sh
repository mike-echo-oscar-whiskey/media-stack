# What a film or episode should be, and the profiles that carry it.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.
#
# Quality itself belongs to Recyclarr (lib/recyclarr.sh): the definitions, the
# custom-format collection and the four profiles per app come from the TRaSH
# Guides and are re-synced on a schedule. What lives here is what the guides do
# not cover: which profile is the default, the guard against a release that puts
# a foreign audio track first, and the guards against fakes, cams, screeners and
# upscales.

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
  ok "the other three stay available per title"
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
  # Converges on the regex rather than merely creating the format, the same way
  # cf_language converges on its language list. Without that, a format whose
  # pattern this stack later changes would keep the pattern it was born with for
  # ever while configure.sh reported "kept" - a silent non-convergence.
  local id current wanted shape
  wanted=$(jq -c --arg n "$1" --arg re "$2" '
    {name:$n, includeCustomFormatWhenRenaming:false,
     specifications:[ first(.[] | select(.implementation == "ReleaseTitleSpecification"))
       | del(.presets, .infoLink, .implementationName)
       | .name = $n | .negate = false | .required = true
       | .fields |= map(if .name == "value" then .value = $re else . end) ]}' <<<"$CF_SCHEMA")
  current=$(jq -c --arg n "$1" 'first(.[] | select(.name == $n)) // empty' <<<"$CF_FMT")
  if [[ -z "$current" ]]; then
    id=$(cf_post "$wanted"); ok "custom format \"$1\"" >&2; printf '%s' "$id"; return
  fi
  id=$(jq -r .id <<<"$current")
  # Compare the pattern itself, not the schema noise around it.
  shape='[.specifications[] | .fields[] | select(.name == "value") | .value]'
  if [[ "$(jq -c "$shape" <<<"$current")" == "$(jq -c "$shape" <<<"$wanted")" ]]; then
    skip "custom format \"$1\"" >&2
  else
    arr "$CF_KEY" PUT "$CF_URL/api/$CF_V/customformat/$id" "$(jq -c --argjson i "$id" '.id = $i' <<<"$wanted")" >/dev/null
    ok "custom format \"$1\" (pattern brought in line)" >&2
  fi
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
cf_source() {                     # cf_source NAME SOURCE_NAME[,SOURCE_NAME...] -> id
  # One condition per source, OR-ed (same implementation, required false). The
  # option is resolved by *name* from the app's own schema, never by number:
  # Radarr counts UNKNOWN CAM TELESYNC TELECINE WORKPRINT DVD TV WEBDL WEBRIP
  # BLURAY where Sonarr counts Unknown Television TelevisionRaw Web WebRip DVD
  # Bluray BlurayRaw, so WEBDL is 7 in one and nothing at all in the other.
  local name=$1 want=$2 ids='[]' one id current wanted shape
  local IFS=,
  for one in $want; do
    id=$(jq -r --arg n "$one" '
      first(.[] | select(.implementation == "SourceSpecification"))
      | .fields[] | select(.name == "value") | .selectOptions[]
      | select(.name == $n) | .value // empty' <<<"$CF_SCHEMA")
    [[ -n "$id" ]] || die "$CF_APP has no release source called \"$one\""
    ids=$(jq -c --argjson i "$id" '. + [$i]' <<<"$ids")
  done
  unset IFS
  wanted=$(jq -c --arg n "$name" --argjson ids "$ids" '. as $s |
    {name:$n, includeCustomFormatWhenRenaming:false,
     specifications:[ $ids[] as $v
       | first($s[] | select(.implementation == "SourceSpecification"))
       | del(.presets, .infoLink, .implementationName)
       | .name = ($v|tostring) | .negate = false | .required = false
       | .fields |= map(if .name == "value" then .value = $v else . end) ]}' <<<"$CF_SCHEMA")
  current=$(jq -c --arg n "$name" 'first(.[] | select(.name == $n)) // empty' <<<"$CF_FMT")
  if [[ -z "$current" ]]; then
    id=$(cf_post "$wanted"); ok "custom format \"$name\"" >&2; printf '%s' "$id"; return 0
  fi
  id=$(jq -r .id <<<"$current")
  shape='[.specifications[] | .fields[] | select(.name == "value") | .value] | sort'
  if [[ "$(jq -c "$shape" <<<"$current")" == "$(jq -c "$shape" <<<"$wanted")" ]]; then
    skip "custom format \"$name\"" >&2
  else
    arr "$CF_KEY" PUT "$CF_URL/api/$CF_V/customformat/$id" "$(jq -c --argjson i "$id" '.id = $i' <<<"$wanted")" >/dev/null
    ok "custom format \"$name\" (sources brought in line)" >&2
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

# ---------------------------------------------------------------- foreign-first audio
# A release that puts another language's audio in track 1 is not merely untidy:
# it is what makes Plex freeze on a Tizen TV. The TV can only ever play the
# first audio track, so asking for any other one forces Plex to transcode the
# audio while passing the video through, and that combination is an unfixed
# Plex-for-Samsung defect - see the Plex entry under Traps in AGENTS.md.
#
# Measured on this library's own grab history (350 distinct release titles in
# Radarr's /api/v3/history, probed against the files Jellyfin reports): 31 films
# hold an English track that is not track 1, 27 of them said so in the release
# title, and the guides' own guards reject 3. The two that should have caught
# them both miss for structural reasons, which is why this matches the raw title:
#
#   - "Language: Not Original" goes silent whenever English is present at all.
#     An iTA-ENG release parses as [Italian, English], so nothing is "not
#     original" about it - Radarr has no concept of track *order*.
#   - "Bad Dual Groups" anchors on the *parsed* release group, and a repackager
#     rewrites that: "x264-iFT_EniaHD" parses as group "iFT", so three Russian
#     re-uploads came in as Tier 02 Blurays at +1750. The tag survives in the
#     title string, never in the parsed group.
#
# Only patterns that earned their place against those 350 titles are here:
# FOREIGN-ENG pairs and EniaHD and the French markers each matched 8, 3 and 2
# releases with no false positives, and [Esp] matched 6 of which 5 were
# genuinely foreign-first. DUAL (4 of 6) and MULTi (6 of 9) are deliberately
# out: both are too loose to block on, and MULTi says only that a release holds
# several audio tracks, never which or in what order.
FOREIGN_FIRST_NAME='Foreign Audio First (title)'
# A hard block, matching the guides' own -10000 rather than a mere penalty: a
# file that freezes on the only TV in the house is not a worse copy, it is an
# unplayable one. minFormatScore stays at the guide's 0, so this rejects rather
# than deprioritises.
FOREIGN_FIRST_SCORE=-10000
# Tags that name a language *before* ENG, in the order the track list follows.
FOREIGN_FIRST_PAIR='ITA FRE FRENCH GER GERMAN SPA ESP SPANISH RUS RUSSIAN POR TUR JAP KOR HIN POL CAT CZE HUN UKR'
# Tags that say it on their own, without naming English after it.
FOREIGN_FIRST_SOLO='TRUEFRENCH VFF VFQ VOSTFR'

# Dutch is deliberately absent from both lists above, and this is the one place
# that matters: a .DUTCH. release carries the Dutch track for the children, and
# the one such release whose tracks have been probed here put English first
# anyway. Blocking it would refuse exactly the content that is wanted. The guard
# is about a *foreign* language displacing English, not about a second track
# existing.
foreign_first_regex() {
  local pair='' solo='' t
  for t in $FOREIGN_FIRST_PAIR; do pair+="${pair:+|}$t"; done
  for t in $FOREIGN_FIRST_SOLO; do solo+="${solo:+|}$t"; done
  # [Esp] is a bracketed source tag rather than a language the parser reads, and
  # EniaHD names no language at all - it is a re-upload tag, and all three in
  # this library's history were Russian-first.
  printf '%s' "\b(${pair})[-. ]?ENG\b|\b(${solo})\b|EniaHD|\[Esp\]"
}

# Formats this stack once scored and no longer does. The Recyclarr configs set
# reset_unmatched_scores: false, so a score written once is never cleared by a
# later sync - deleting the code that set it leaves the number behind for ever.
# MULTi sat at 500 for days exactly that way. So anything given up has to be
# unset *explicitly*, and has to stay on this list: an install still carrying the
# old score may be upgraded long after the code that wrote it went.
#
# "Language: Not Original" is the one that matters. It scores -10000 on any
# release whose parsed language is not the film's own, which refuses every
# Dutch-dubbed release there is - 40 of 40 live ones measured through
# /api/v3/parse - and those are wanted here, for the children. It is also not
# requested by any profile template this stack uses; it arrived only because
# lib/recyclarr-config.py asked for its group by name, and that request is gone.
# The format is the guide's own definition and is left in place merely unscored,
# rather than deleted, because removing a format the guide defines invites it
# back on some later sync.
#
# The accessibility blocks (WiTH AD / ASL / BASL / BSL) are deliberately NOT
# here. They stay at -10000: an accessibility release carries a narration of what
# is on screen *instead of* the normal audio, nothing downstream can repair it,
# and eighteen such files once sat in this library looking perfectly ordinary.
# ---------------------------------------------------------------- audio and source
# A Samsung Tizen set cannot decode DTS or TrueHD. When the wanted track is one of
# those Plex transcodes the audio while passing the video through, which is the
# path that eventually freezes (see the Plex entry under Traps in AGENTS.md).
# Encanto arrived that way, ran 64 minutes and died.
#
# So the scores below prefer what the televisions can actually decode. Measured on
# this library's own files, by the codec of each film's first audio track:
#
#   eac3  186 tracks, median 5.1, up to 7.1, and 44 of the 48 Atmos tracks here
#   ac3    78 tracks, median 5.1, 5.1 ceiling
#   dts    41 tracks, median 5.1          <- needs a transcode
#   aac    37 tracks, median *2.0*        <- plays, but usually stereo
#   truehd  5 tracks, 7.1                 <- needs a transcode
#
# DD+ is the sweet spot rather than a compromise: it is the streaming standard, it
# carries 7.1, and DD+ Atmos is the one Atmos route a Samsung app passes over eARC
# to the Sonos Beam. DTS-HD MA and TrueHD are *lossless* and on paper better - but
# the set cannot decode either, so Plex re-encodes them, and in the Encanto test
# that came out as AAC. Preferring DD+ trades a lossless track that never plays
# losslessly for a 7.1 Atmos one that does.
#
# AAC is scored barely above nothing because 24 of its 37 tracks here are stereo:
# worth having over a transcode, not worth losing 5.1 for.
#
# DTS, DTS-ES, DTS-HD HRA, DTS-HD MA, DTS X, TrueHD, TrueHD ATMOS, FLAC and PCM are
# deliberately left at the guide's 0 rather than penalised. minFormatScore is 0, so
# a penalty would *reject* a film offered only with DTS, and one transcode beats no
# film at all.
AUDIO_SCORES='DD+ ATMOS	320
DD+	280
DD	200
AAC	60'

# The audio formats read the release *title*, so they only reach releases that name
# their codec. Measured against the 196 films here: when a title names a codec it is
# right 94% of the time, but 36% of titles say nothing at all - and 17 of those 72
# silent films turned out to carry DTS or TrueHD, Encanto among them. No regex fixes
# that; the information is absent.
#
# Source is the field that is always present, and it correlates: 35 of 98 Bluray
# files here have DTS or TrueHD on track 1 against 0 of 98 WEB files. So a WEB-DL
# preference reaches the 36% the codec formats cannot see.
#
# 150 is chosen against the guides' release-group tiers, which run 1600-1800 and put
# HD Bluray 100 above WEB at the same rank. 150 clears that, so a WEB-DL beats a
# Bluray of equal tier - and a top-tier Bluray still beats a bottom-tier WEB-DL,
# which is correct. WEBRIP is deliberately not included: it is a re-encode of a
# stream, 2.2 Mbit/s median here against WEB-DL's 6.8, and promoting it would buy
# safe audio with a bad picture.
#
# Radarr only. Sonarr's profiles are WEB-only by the guide's own design, so there is
# no Bluray there to out-rank.
WEB_SOURCE_NAME='WEB-DL Source'
WEB_SOURCE_SCORE=150

UNSCORED_FORMATS='Language: Not Original
MULTi'

# One format, several title conditions. They are all ReleaseTitleSpecification,
# so they OR - which is what is wanted here, and is also why they cannot be
# split across formats without turning the whole thing into an AND.
# Our scores, per profile. Two maps rather than one, because the guides own the
# audio hierarchy in the Remux and UHD profiles - TrueHD ATMOS 5000 above DTS X
# 4500 above DD+ ATMOS 3000 - and that is both a fight this cannot win (Recyclarr
# restores it on every sync, as the language group did in Sonarr) and the right
# answer there: a profile called Remux is chosen *for* lossless audio, by someone
# whose equipment can decode it. So the codec and source preference applies to the
# default profile only, and the rest get the guard and the zeroes.
apply_our_scores() {              # apply_our_scores APP
  local app=$1 v base default common extra name score id
  default=$(recyclarr_profile "$app" "$Q_DEFAULT")
  # The guard, by id: it is ours, so nothing else can be relied on to have made it.
  common="$(cf_title "$FOREIGN_FIRST_NAME" "$(foreign_first_regex)")	$FOREIGN_FIRST_SCORE"$'\n'
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    id=$(jq -r --arg n "$name" 'first(.[] | select(.name == $n)) | .id // empty' <<<"$CF_FMT")
    [[ -n "$id" ]] && common+="$id	0"$'\n'
  done <<<"$UNSCORED_FORMATS"

  extra=''
  if [[ $app == radarr ]]; then
    # Source is ours, so it is zeroed everywhere it does not belong rather than
    # merely left out: a score written once survives for ever otherwise.
    id=$(cf_source "$WEB_SOURCE_NAME" WEBDL)
    common+="$id	0"$'\n'
    extra+="$id	$WEB_SOURCE_SCORE"$'\n'
    # Audio, Radarr only. Sonarr holds none of these: its guide ships them only
    # inside an `audio-formats` group, and selecting a group hands Recyclarr the
    # scores too - the fidelity ordering, which is backwards for a television that
    # cannot decode lossless. Owning private copies of nine formats there is a
    # bigger change than the gap justifies: 17 of 319 episodes here carry TrueHD on
    # track 1 against 76% already EAC3, and every series profile is WEB, where DTS
    # does not appear at all. Revisit if that 17 grows.
    while IFS=$'\t' read -r name score; do
      [[ -n "$name" ]] || continue
      id=$(jq -r --arg n "$name" 'first(.[] | select(.name == $n)) | .id // empty' <<<"$CF_FMT")
      [[ -n "$id" ]] || die "$CF_APP has no custom format called \"$name\" - the guide renamed it"
      extra+="$id	$score"$'\n'
    done <<<"$AUDIO_SCORES"
  fi

  for v in $QUALITY_VARIANTS; do
    base=$(recyclarr_profile "$app" "$v")
    if [[ "$base" == "$default" ]]; then OUR_SCORES="$common$extra"; else OUR_SCORES="$common"; fi
    our_scores "$base"
  done
}

# Every score this stack owns in one profile, in one PUT: the foreign-first guard
# at -10000 and everything on UNSCORED_FORMATS back to 0. One pass rather than
# one per format, so a profile is read and written once and the log carries one
# line per profile instead of four.
our_scores() {                    # our_scores GUIDE_PROFILE   (reads OUR_SCORES)
  local base=$1 profiles current wanted id map
  profiles=$(arr "$CF_KEY" GET "$CF_URL/api/v3/qualityprofile")
  current=$(jq -c --arg n "$base" 'first(.[] | select(.name == $n)) // empty' <<<"$profiles")
  [[ -n "$current" ]] || die "Recyclarr has not created the profile \"$base\" in $CF_APP yet"
  id=$(jq -r .id <<<"$current")
  # id -> score, built from the tab-separated lines OUR_SCORES carries.
  # from_entries keeps the *last* value for a repeated key, which is what makes the
  # default profile's extra map override the common one for the same format id.
  map=$(jq -Rsc 'split("\n") | map(select(length > 0) | split("\t"))
                 | map({key: .[0], value: (.[1]|tonumber)}) | from_entries' <<<"$OUR_SCORES")
  # A profile that lists none of them would make the map a no-op and the compare
  # would then report "kept" for scores that were never written - the silent-skip
  # failure this repo keeps being bitten by.
  jq -e --argjson m "$map" 'any(.formatItems[]; (.format|tostring) as $f | $m | has($f))' \
    <<<"$current" >/dev/null || die "$CF_APP profile \"$base\" lists none of our formats"
  wanted=$(jq -c --argjson m "$map" '
    .formatItems |= map((.format|tostring) as $f
      | if ($m | has($f)) then .score = $m[$f] else . end)' <<<"$current")
  if [[ "$(jq -cS . <<<"$wanted")" == "$(jq -cS . <<<"$current")" ]]; then
    skip "quality profile \"$base\" scores"
  else
    arr "$CF_KEY" PUT "$CF_URL/api/v3/qualityprofile/$id" "$wanted" >/dev/null
    ok "quality profile \"$base\" scores (foreign-first refused, audio and source preferred)"
  fi
}

# The profiles themselves are Recyclarr's; what is left to do per app is score
# the one format of ours and move anything off a profile nobody should be using.
# This stack used to add a dubbed twin of every profile here, with its own root
# folder and its own Seerr destination, and later a pair of Dutch custom formats
# scored +500 in the ordinary profiles instead. Both are gone: a dub preference
# cannot reach releases whose title does not name the language, and the guide
# format that was keeping the original audio in the file refused every Dutch
# release there is - 40 of 40 measured live. Dutch now arrives by asking for a
# .DUTCH. release in an interactive search, and the children hear it through
# Jellyfin, whose per-user audio preference picks the track whatever position it
# sits in. See README "Dutch audio, and why nothing scores for it".
configure_profiles() {            # configure_profiles APP URL
  local app=$1 url=$2
  log "$app - quality profiles and the default"
  cf_begin "$app" "$url"
  apply_our_scores "$app"
  move_to_managed_profile "$app" "$url"
}

# Films and series sitting on a profile nobody should be using are moved onto
# the default - that is what makes it the default, including for anything added
# through the app's own UI. Two kinds count: the apps' own stock profiles, and
# the ones this stack managed itself before the guides took over, which are
# deleted once nothing points at them. Put something on a profile of your own
# and it stays there.
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
