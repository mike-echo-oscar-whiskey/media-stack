# SABnzbd: folders, categories, rate cap and the Usenet provider.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- SABnzbd
configure_sabnzbd() {
  log "SABnzbd"
  SAB_KEY=$(sed -n 's/^api_key = //p' "$CONFIG_ROOT/sabnzbd/sabnzbd.ini")
  [[ -n "$SAB_KEY" ]] || die "no api_key in $CONFIG_ROOT/sabnzbd/sabnzbd.ini yet"
  sab() {                         # sab key=value ...   (values are URL-encoded)
    local args=()
    local kv; for kv in "$@"; do args+=(--data-urlencode "$kv"); done
    curl -fsS -G "$SAB_URL/api" --data-urlencode output=json --data-urlencode "apikey=$SAB_KEY" "${args[@]}"
  }
  sab_set() { sab mode=set_config section=misc "keyword=$1" "value=$2" >/dev/null; }

  sab_set download_dir /data/usenet/incomplete
  sab_set complete_dir /data/usenet/complete
  sab_set direct_unpack 1
  ok "incomplete /data/usenet/incomplete, complete /data/usenet/complete, direct unpack"

  # SABnzbd checks the Host header of every request against host_whitelist and
  # refuses anything unlisted with "External internet access denied", linking to
  # sabnzbd.org/access-denied - which reads as a network fault and is not one.
  # Alone among the apps here it has that guard, so reaching it through Caddy at
  # sabnzbd.<SITE_DOMAIN> fails until the name is listed, even though this repo is
  # what puts Caddy in front of it on that name.
  local wl="sabnzbd,localhost,127.0.0.1"
  [[ -n "${SITE_DOMAIN:-}" ]] && wl="$wl,sabnzbd.$SITE_DOMAIN"
  [[ -n "${LAN_IP:-}" ]] && wl="$wl,$LAN_IP"
  local wl_now
  wl_now=$(sab mode=get_config section=misc keyword=host_whitelist \
           | jq -r '[.config.misc.host_whitelist] | flatten | map(gsub("^ +| +$";"")) | join(",")')
  if [[ ",$wl_now," == *",sabnzbd.${SITE_DOMAIN},"* ]]; then
    skip "host whitelist"
  else
    sab_set host_whitelist "$wl"
    ok "host whitelist: $wl"
  fi

  # Whose request counts as local. With local_ranges empty SABnzbd asks Python
  # whether the address is private, and a Tailscale address is not: 100.64.0.0/10
  # is shared address space, so is_private answers False and every tailnet
  # browser gets the same access-denied page as a stranger. Caddy does not hide
  # it either - it forwards the client in X-Forwarded-For and SABnzbd checks
  # every hop. Spelling the ranges out restores the private networks and adds
  # the tailnet. local_ranges carries protect=True, which makes set_config a
  # silent no-op, so it has to go into the ini - and SABnzbd rewrites that file
  # as it shuts down, hence stop, edit, start rather than edit and restart.
  local ranges=${SAB_LOCAL_RANGES:-127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,::1/128,fc00::/7}
  local ranges_now
  ranges_now=$(sab mode=get_config section=misc keyword=local_ranges \
               | jq -r '[.config.misc.local_ranges] | flatten | join(",")' | tr -d ' ')
  if [[ "$ranges_now" == "${ranges// /}" ]]; then
    skip "local ranges"
  else
    local ini="$CONFIG_ROOT/sabnzbd/sabnzbd.ini"
    docker compose stop sabnzbd >/dev/null 2>&1
    if grep -q '^local_ranges *=' "$ini"; then
      sed -i "s|^local_ranges *=.*|local_ranges = ${ranges//,/, }|" "$ini"
    else
      sed -i "/^\[misc\]/a local_ranges = ${ranges//,/, }" "$ini"
    fi
    docker compose start sabnzbd >/dev/null 2>&1
    local i
    for i in $(seq 1 40); do sab mode=version >/dev/null 2>&1 && break; sleep 3; done
    ok "local ranges: $ranges"
  fi

  local cat
  for cat in tv movies music prowlarr; do
    sab mode=set_config section=categories "name=$cat" "dir=$cat" pp=3 script=Default priority=-100 >/dev/null
    ok "category $cat -> /data/usenet/complete/$cat"
  done
  sab_set username "$WEBUI_USERNAME"
  sab_set password "$WEBUI_PASSWORD"
  ok "Web UI login set"
  # Free-space floor. SABnzbd enforces this itself and continuously, which is
  # why the fastest client needs no help from heal.sh - see README "Keeping the
  # disk from filling". Its K/M/G are binary, and the value is written in whole
  # KiB so nothing depends on reading a suffix back the same way it went in.
  # fulldisk_autoresume goes with it: a queue that pauses and then waits for a
  # human defeats the point.
  sab_kib() {                     # "500M" | "25G" | "1024" | "" -> whole KiB
    local v=${1// /} n u
    [[ -n "$v" ]] || { echo 0; return 0; }
    n=${v%[KkMmGgTt]}; u=${v#"$n"}
    [[ "$n" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo 0; return 0; }
    n=${n%%.*}
    case "${u^^}" in
      K) echo "$n" ;;
      M) echo $(( n * 1024 )) ;;
      G) echo $(( n * 1024 * 1024 )) ;;
      T) echo $(( n * 1024 * 1024 * 1024 )) ;;
      *) echo $(( n / 1024 )) ;;   # bare number is bytes
    esac
  }
  local floor=${DISK_FLOOR_GIB:-0} want_k have_k resume
  if [[ "$floor" =~ ^[0-9]+$ ]] && (( floor > 0 )); then
    want_k=$(( floor * 1024 * 1024 ))
    have_k=$(sab_kib "$(sab mode=get_config section=misc keyword=download_free | jq -r '.config.misc.download_free // ""')")
    resume=$(sab mode=get_config section=misc keyword=fulldisk_autoresume | jq -r '.config.misc.fulldisk_autoresume')
    # get_config reports the boolean as "true", set_config takes 1.
    if [[ "$have_k" == "$want_k" && ( "$resume" == true || "$resume" == 1 ) ]]; then
      skip "downloading pauses below $floor GiB free"
    else
      sab_set download_free "${want_k}K"; sab_set fulldisk_autoresume 1
      ok "downloading pauses below $floor GiB free, and resumes by itself"
    fi
  else
    if [[ "$floor" =~ ^[0-9]+$ ]]; then
      skip "no DISK_FLOOR_GIB - downloading is never paused for disk space"
    else
      printf '   WARN DISK_FLOOR_GIB must be a whole number of GiB (got "%s")\n' "$floor"
    fi
  fi

  # Line speed cap.
  # The unrestricted window is its scheduler: "speedlimit 0" lifts the cap,
  # "speedlimit 100" (percent of the maximum) puts it back. Schedule lines
  # are read at start, hence the restart when they change.
  # KiB/s, which is what SABnzbd's "K" suffix means, so the value passes through
  # untouched. Its K/M/G are binary: "75M" would be 75 MiB/s = 629 Mbit/s, not
  # the 600 someone writing Mbit would expect. KiB = Mbit x 125000 / 1024.
  local kib=${USENET_MAX_KIB:-0} win lines before
  [[ "$kib" =~ ^[0-9]+$ ]] || die "USENET_MAX_KIB must be a whole number of KiB/s (got \"$kib\")"
  if (( kib > 0 )); then
    sab_set bandwidth_max "${kib}K"; sab_set bandwidth_perc 100
    ok "download speed capped at $kib KiB/s ($(( (kib * 1024 * 8 + 500000) / 1000000 )) Mbit/s)"
  else
    sab_set bandwidth_max ""
    ok "download speed unlimited"
  fi
  lines=""
  if (( kib > 0 )) && win=$(unrestricted_window); then
    set -- $win
    lines="1 $2 $1 1234567 speedlimit 0,1 $4 $3 1234567 speedlimit 100"
  fi
  before=$(sab mode=get_config section=misc keyword=schedlines | jq -r '.config.misc.schedlines | join(",")')
  if [[ "$before" != "$lines" ]]; then
    sab_set schedlines "$lines"
    docker compose restart sabnzbd >/dev/null 2>&1
    # Wait for the API to come back: the Usenet provider is configured right
    # after this, and a call into a restarting SABnzbd dies on a reset connection.
    local i
    for i in $(seq 1 40); do sab mode=version >/dev/null 2>&1 && break; sleep 3; done
    ok "unrestricted ${UNRESTRICTED_HOURS:-never} (scheduler set, SABnzbd restarted)"
  else
    skip "unrestricted ${UNRESTRICTED_HOURS:-never}"
  fi

  if [[ -n "${USENET_HOST:-}" && -n "${USENET_USERNAME:-}" ]]; then
    # set_config on an existing server name updates it, so this is idempotent.
    sab mode=set_config section=servers "name=$USENET_HOST" "host=$USENET_HOST" \
        "port=${USENET_PORT:-563}" "ssl=$([[ ${USENET_PORT:-563} == 119 ]] && echo 0 || echo 1)" \
        "username=$USENET_USERNAME" "password=${USENET_PASSWORD:-}" \
        "connections=${USENET_CONNECTIONS:-8}" enable=1 priority=0 >/dev/null
    ok "Usenet provider $USENET_HOST:${USENET_PORT:-563} (${USENET_CONNECTIONS:-8} connections)"
  else
    echo "        (no Usenet provider: set USENET_HOST/USENET_USERNAME/USENET_PASSWORD in .env and re-run)"
  fi
}
