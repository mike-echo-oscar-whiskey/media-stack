# Spotweb: the Spotnet indexer Prowlarr searches as a Newznab source.
# Sourced by configure.sh, which loads .env, defines the URL constants and the
# log/ok/skip/die helpers.

# Not a LinuxServer image, but it behaves like one: a single `abc` user and
# PUID/PGID/TZ. Everything here goes through Spotweb's own classes rather than
# SQL, so the schema stays the version upgrade-db.php expects.
#
# The image does more of the work than the standalone install does: it creates
# the schema itself, injects the database settings from DB_* environment
# variables instead of writing dbsettings.inc.php, routes /api in nginx, and
# runs retrieval on its own cron. What is left is the part it cannot know - the
# Usenet account, which this stack already has in .env for SABnzbd.
configure_spotweb() {
  log "Spotweb"
  docker compose ps --services --status running 2>/dev/null | grep -qx spotweb || {
    skip "not running"; return 0; }

  # Run PHP inside the container as the app user. A snippet that needs a secret
  # reads it from stdin: an argument would land in the host's process list.
  sw_php() { local code=$1; shift; docker compose exec -T -u abc spotweb php -r "$code" "$@"; }

  # sw_get KEY - one setting, as Spotweb itself reads it.
  sw_get() {
    sw_php 'chdir("/app"); require "vendor/autoload.php"; list($s) = (new Bootstrap())->boot();
            echo $s->get($argv[1]);' -- "$1"
  }

  # Spotweb's login is an XHR that answers JSON and wants the xsrf token from a
  # GET of the same page first.
  local jar; jar=$(mktemp); trap 'rm -f "$jar"' RETURN
  sw_login() {
    local x
    : > "$jar"
    x=$(curl -fsS -c "$jar" "$SPOTWEB_URL/?page=login" 2>/dev/null \
        | grep -oE 'name="loginform\[xsrfid\]" value="[^"]+"' | sed 's/.*value="//; s/"$//') || return 1
    [[ -n "$x" ]] || return 1
    curl -fsS -b "$jar" -c "$jar" -X POST "$SPOTWEB_URL/?page=login" \
      --data-urlencode "loginform[username]=$1" --data-urlencode "loginform[password]=$2" \
      --data-urlencode "loginform[xsrfid]=$x" --data-urlencode "loginform[submitlogin]=Login" 2>/dev/null \
      | jq -e '.result == "success"' >/dev/null 2>&1
  }

  # The container resets admin's password to the image default on every start
  # until admin has logged in once (its 40-initialize-db checks lastlogin). So
  # the order matters: set the password, then log in with it, and the reset
  # stops firing. Logging in is also the only honest proof it worked.
  if sw_login admin "$WEBUI_PASSWORD"; then
    skip "admin login from .env"
  elif sw_login admin spotweb; then
    printf '%s' "$WEBUI_PASSWORD" | docker compose exec -T -u abc spotweb php -r '
      chdir("/app"); require "vendor/autoload.php";
      $pw = stream_get_contents(STDIN);
      $b = new Bootstrap(); $d = $b->getDaoFactory(); $s = $b->getSettings($d, false);
      (new Services_Upgrade_Users($d, $s))->resetUserPassword("admin", $pw);' >/dev/null
    sw_login admin "$WEBUI_PASSWORD" || die "Spotweb would not accept the new admin password"
    ok "admin password set from .env (and the image will stop resetting it)"
  else
    printf '   WARN cannot sign in to Spotweb as admin, with either the .env password or the image default\n'
    return 0
  fi

  # A public system lets anyone who can reach the page register an account.
  if [[ "$(sw_get systemtype)" == single ]]; then
    skip "closed to registration (single-user system)"
  else
    # Switching type generates the signing keypair, and openssl warns that it
    # cannot write its random state while doing so. The key is generated anyway,
    # so the outcome is checked instead of the noise being reported.
    docker compose exec -T -u abc spotweb php /app/bin/upgrade-db.php --set-systemtype=single >/dev/null 2>&1
    [[ "$(sw_get systemtype)" == single ]] || die "Spotweb would not switch to a single-user system"
    ok "closed to registration (single-user system)"
  fi

  # The Usenet account, and the trap that costs a debugging session: Spotweb
  # stores THREE servers - nzb, hdr and post - and the settings page opens with
  # "use a different server for headers/posting" already ticked, so filling in
  # only the NZB one leaves retrieval pointed somewhere else and still reports
  # success. An empty hdr/post host falls back to the NZB server, so both are
  # blanked here. Port 119 is plain, anything else is SSL (.env.example says so).
  if [[ -z "${USENET_HOST:-}" ]]; then
    skip "no USENET_HOST in .env - Spotweb retrieves nothing"
  else
    # Compare what is STORED, not what get() returns: an empty hdr/post host
    # makes Spotweb hand back the NZB server instead, so a read through get()
    # can never see the blank this step is trying to achieve and the step would
    # rewrite itself on every run.
    local have want
    have=$(sw_php 'chdir("/app"); require "vendor/autoload.php";
      $raw = (new Bootstrap())->getDaoFactory()->getSettingDao()->getAllSettings();
      $n = $raw["nntp_nzb"]; printf("%s|%s|%s|%s|%s", $n["host"], $n["port"],
        ($n["user"] === "" ? "" : "set"), $raw["nntp_hdr"]["host"], $raw["nntp_post"]["host"]);')
    want="$USENET_HOST|${USENET_PORT:-563}|$([[ -n ${USENET_USERNAME:-} ]] && echo set)||"
    if [[ "$have" == "$want" ]]; then
      skip "usenet server $USENET_HOST:${USENET_PORT:-563} (headers and posting follow it)"
    else
      jq -cn --arg h "$USENET_HOST" --arg p "${USENET_PORT:-563}" \
             --arg u "${USENET_USERNAME:-}" --arg pw "${USENET_PASSWORD:-}" \
             '{host:$h, port:($p|tonumber), user:$u, pass:$pw}' \
      | docker compose exec -T -u abc spotweb php -r '
          chdir("/app"); require "vendor/autoload.php";
          $in = json_decode(stream_get_contents(STDIN), true);
          list($s) = (new Bootstrap())->boot();
          $port = (int) $in["port"];
          $s->set("nntp_nzb", ["host"=>$in["host"], "user"=>$in["user"], "pass"=>$in["pass"],
                               "enc"=>($port === 119 ? false : "ssl"), "port"=>$port,
                               "buggy"=>false, "verifyname"=>true]);
          $blank = ["host"=>"", "user"=>"", "pass"=>"", "enc"=>false, "port"=>119,
                    "buggy"=>false, "verifyname"=>true];
          $s->set("nntp_hdr", $blank); $s->set("nntp_post", $blank);' >/dev/null
      ok "usenet server $USENET_HOST:${USENET_PORT:-563} (headers and posting follow it)"
    fi
  fi

  # How far back to index, as a year. This seeds Spotweb's floor on what it
  # STORES; it is not a rolling window, so it is written once and then left
  # alone. Widening it afterwards needs the reader rewound too, which is what
  # scripts/spotweb-backfill.sh is for - see README "Spotweb, the Spotnet
  # indexer".
  local since=${SPOTWEB_SINCE_YEAR:-2025} floor
  if [[ ! "$since" =~ ^[0-9]{4}$ ]]; then
    printf '   WARN SPOTWEB_SINCE_YEAR must be a four-digit year (got "%s")\n' "$since"
  else
    floor=$(sw_get retrieve_newer_than)
    if [[ "$floor" =~ ^[0-9]+$ ]] && (( floor > 0 )); then
      skip "indexes spots from $(date -d "@$floor" +%Y) onwards"
    else
      printf '%s' "$since" | docker compose exec -T -u abc spotweb php -r '
        chdir("/app"); require "vendor/autoload.php"; list($s) = (new Bootstrap())->boot();
        $s->set("retrieve_newer_than", mktime(0, 0, 0, 1, 1, (int) trim(stream_get_contents(STDIN))));
        $s->set("retrieve_comments", false); $s->set("retrieve_reports", false);' >/dev/null
      ok "indexes spots from $since onwards, without comments or reports"
    fi
  fi

  # A dedicated user for Prowlarr, because the admin's key cannot work: the API
  # check in Services_User_Authentication::verifyApi requires the user id to be
  # GREATER than SPOTWEB_ADMIN_USERID, and admin is that id. With admin's key
  # Spotweb answers an HTML "invalid API key" page, which Prowlarr then reports
  # as a mismatched XML tag - a confusing way to be told to make a second user.
  #
  # The address is example.com because the validator rejects anything it does not
  # consider a valid address, and a .lan hostname is not one. Nothing is sent to
  # it. The password is random and never used; Prowlarr authenticates by key.
  local swuser=prowlarr
  if [[ -z "$(sw_php 'chdir("/app"); require "vendor/autoload.php";
        $b = new Bootstrap(); list($s, $d) = $b->boot();
        echo $d->getUserDao()->findUserIdForName($argv[1]);' -- "$swuser")" ]]; then
    # Creating the user generates its keypair, and openssl warns it cannot write
    # its random state while doing so; the key is made anyway, so the result is
    # checked rather than the noise reported.
    sw_php 'chdir("/app"); require "vendor/autoload.php";
      $b = new Bootstrap(); list($s, $d) = $b->boot();
      $r = (new Services_User_Record($d, $s))->createUserRecord([
        "username" => $argv[1], "firstname" => "Prowlarr", "lastname" => "Indexer",
        "mail" => $argv[1]."@example.com"]);
      if (!$r->isSuccess()) { fwrite(STDERR, implode("; ", $r->getErrors())); exit(1); }' \
      -- "$swuser" >/dev/null 2>&1 \
      || printf '   WARN could not create the %s user in Spotweb\n' "$swuser"
    ok "user $swuser created, for Prowlarr to search with"
  else
    skip "user $swuser"
  fi

  # Read by configure_prowlarr, which runs after us. Never printed: this key is
  # what lets anything search the indexer.
  SPOTWEB_KEY=$(sw_php 'chdir("/app"); require "vendor/autoload.php";
    $b = new Bootstrap(); list($s, $d) = $b->boot(); $u = $d->getUserDao();
    $id = $u->findUserIdForName($argv[1]);
    echo empty($id) ? "" : ($u->getUser($id)["apikey"] ?? "");' -- "$swuser")
  [[ -n "$SPOTWEB_KEY" ]] || \
    printf '   WARN no Spotweb API key for %s - Prowlarr will not get the indexer\n' "$swuser"

  # Prowlarr refuses to save an indexer whose test search returns nothing, and a
  # Spotweb with an empty database returns nothing however well it is configured.
  # So the count is published and configure_prowlarr waits for it, the way
  # configure_seerr waits for the Plex claim.
  SPOTWEB_SPOTS=$(sw_php 'chdir("/app"); require "vendor/autoload.php";
    $b = new Bootstrap(); list($s, $d) = $b->boot();
    echo (int) $d->getSpotDao()->getSpotCount("", "");')
  if [[ ! "${SPOTWEB_SPOTS:-0}" =~ ^[0-9]+$ ]] || (( SPOTWEB_SPOTS == 0 )); then
    skip "no spots yet - the container retrieves every ${SPOTWEB_INTERVAL_MIN:-30} min, and Prowlarr gets the indexer on the next run"
  fi

  # Configured deeper than the database actually goes? Say so once, with the way
  # to fix it. Widening is a twenty-minute retrieval, so it is never done from
  # here - configure.sh stays fast and re-runnable.
  local oldest
  oldest=$(sw_php 'chdir("/app"); require "vendor/autoload.php";
    $b = new Bootstrap(); list($s, $d) = $b->boot();
    $r = $d->getConnection()->arrayQuery("SELECT MIN(stamp) AS mn FROM spots", []);
    echo $r[0]["mn"] ? date("Y", (int) $r[0]["mn"]) : "";')
  if [[ "$oldest" =~ ^[0-9]{4}$ && "$since" =~ ^[0-9]{4}$ ]] && (( oldest > since )); then
    echo "        (indexed back to $oldest, configured for $since - ./scripts/spotweb-backfill.sh widens it)"
  fi

  # The mounted search fix masks a file inside the image, so the image's own
  # copy is checked against the version the patch was taken from. When upstream
  # moves, this says so rather than letting the override hide a newer fix.
  local want=898693b655fe95e123f47bfb4efc0b1380a67a497dd08e29e8c4933f4a7c57e2 have
  have=$(docker run --rm --entrypoint sha256sum "erikdevries/spotweb:${SPOTWEB_TAG:-latest}" \
         /app/lib/dbeng/dbfts_abs.php 2>/dev/null | cut -d' ' -f1)
  if [[ -z "$have" ]]; then
    : # could not read the image; not worth failing a run over
  elif [[ "$have" == "$want" ]]; then
    skip "search fix still applies to this image"
  else
    printf '   WARN the image changed lib/dbeng/dbfts_abs.php - check whether spotweb/dbfts_abs.php is still needed\n'
  fi

  echo "        (http://spotweb.$SITE_DOMAIN - ${SPOTWEB_SPOTS:-0} spots, retrieved every ${SPOTWEB_INTERVAL_MIN:-30} min by the container)"
}
