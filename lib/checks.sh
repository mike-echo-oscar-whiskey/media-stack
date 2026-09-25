# Checks that report rather than change: hostnames and the host firewall.
# Sourced by configure.sh, which loads .env, defines the URL constants
# and the log/ok/skip/die helpers.

# ---------------------------------------------------------------- hostnames
check_hostnames() {
  log "Hostnames (*.$SITE_DOMAIN -> $LAN_IP via the reverse proxy on :80)"
  local name missing=() code
  for name in media plex jellyfin sonarr radarr lidarr prowlarr bazarr seerr sabnzbd qbittorrent spotweb; do
    if getent hosts "$name.$SITE_DOMAIN" >/dev/null; then
      code=$(curl -sS -o /dev/null -w '%{http_code}' -m 10 "http://$name.$SITE_DOMAIN/" || true)
      case "$code" in 200|30[0-9]|401) ok "http://$name.$SITE_DOMAIN ($code)" ;;
                      *) printf '   WARN http://%s.%s -> HTTP %s\n' "$name" "$SITE_DOMAIN" "$code" ;;
      esac
    else
      missing+=("$name")
    fi
  done
  if (( ${#missing[@]} )); then
    echo "   These names do not resolve yet. Add A records in your DNS server, e.g. Pi-hole"
    echo "   (Settings > Local DNS Records, or your records file):"
    for name in "${missing[@]}"; do printf '      %s %s.%s\n' "$LAN_IP" "$name" "$SITE_DOMAIN"; done
    echo "   Without a reverse proxy the dashboard is at http://$LAN_IP:3000/ (if APP_BIND allows it)."
  fi
}

# ---------------------------------------------------------------- host firewall
# Docker's published ports still pass the host firewall's INPUT chain when
# Docker does not manage iptables itself (common on a gateway host). Warn if
# firewalld would reject the LAN-facing ports; opening them needs root.
check_host_firewall() {
  command -v firewall-cmd >/dev/null 2>&1 || return 0
  systemctl is-active --quiet firewalld 2>/dev/null || return 0
  log "Host firewall (firewalld)"
  # Only unprivileged queries and the world-readable zone files are used here:
  # --state / --query-port need polkit authorisation.
  local iface zone zonefile
  iface=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n1)
  zone=$(firewall-cmd --get-active-zones 2>/dev/null | awk -v i="$iface" '/^[^ ]/{z=$1} /interfaces:/ && $0 ~ ("(^| )" i "( |$)") {print z; exit}')
  [[ -n "$zone" ]] || zone=$(firewall-cmd --get-default-zone 2>/dev/null)
  zonefile=/etc/firewalld/zones/$zone.xml
  [[ -r "$zonefile" ]] || zonefile=/usr/lib/firewalld/zones/$zone.xml
  if [[ ! -r "$zonefile" ]]; then
    echo "   (cannot read zone $zone; check with: sudo firewall-cmd --zone=$zone --list-all)"; return 0
  fi
  if grep -qE '<port port="32400" protocol="tcp"/>|<service name="plex"/>' "$zonefile"; then
    ok "zone $zone on $iface allows 32400/tcp"
  else
    printf '   WARN zone %s on %s rejects 32400/tcp - Plex is unreachable from the LAN and the internet.\n' "$zone" "$iface"
    printf '        Fix (root):  sudo firewall-cmd --permanent --zone=%s --add-port=32400/tcp && sudo firewall-cmd --reload\n' "$zone"
  fi
}
