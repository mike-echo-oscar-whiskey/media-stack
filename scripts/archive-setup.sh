#!/usr/bin/env bash
# One-time setup of the archive tier's rclone remotes.
#
#   ./scripts/archive-setup.sh
#
# Two remotes get written: the provider, and a crypt layer named "media" on top
# of it. "media:" is the only name the rest of the stack ever mounts - compose,
# configure.sh and mover.sh all address that - so the provider underneath can be
# swapped later without touching anything else in this repo.
#
# Why a script rather than "run rclone config and answer carefully": three of
# the answers cannot be changed once a single file has been uploaded.
# filename_encryption, directory_name_encryption and filename_encoding decide
# how every name is stored, and changing one later means rclone can no longer
# find anything it wrote before. They are baked in here so they cannot be
# fat-fingered at a prompt.
#
# Secrets never reach the process list: passwords are read without echo and
# obscured through "rclone obscure -" on stdin, and the config file is written
# here rather than passed to rclone as arguments.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG_ROOT=$(sed -n 's/^CONFIG_ROOT=//p' .env 2>/dev/null | head -1); CONFIG_ROOT=${CONFIG_ROOT:-./config}
CONF=$CONFIG_ROOT/rclone/rclone.conf

die()  { printf '\n%s\n' "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
rule() { printf '%s\n' "------------------------------------------------------------"; }

# rclone from inside the image, so the host needs nothing installed - but as
# this user, not as root. The image's default user is root, and anything it
# writes to /config/rclone lands on the host owned by root with mode 600. The
# mount itself would still work (root can read anything), but configure.sh,
# heal.sh and mover.sh all read rclone.conf as you to decide whether an archive
# exists, and a file they cannot open reads exactly like a file that is not
# there - so the archive would silently look unconfigured.
RC_USER="$(id -u):$(id -g)"
rc() { docker compose run --rm -T --user "$RC_USER" rclone "$@"; }

[[ -f .env ]] || die "run this from the stack directory (no .env here)"

# A real terminal, or nothing. Every prompt here is a read, and three of them
# are passwords read without echo; with stdin closed or piped, read returns
# non-zero, set -e ends the run, and the only clue is a prompt with no answer
# after it. setup.sh learned the same lesson - say so instead.
if [[ ! -t 0 ]]; then
  die "This needs a real terminal: it asks for a client secret and an encryption
password, and reads them without echo.

Run it directly in a shell:

  cd $(pwd)
  ./scripts/archive-setup.sh

Not through a pipe, a here-document, or an agent that closes stdin."
fi

mkdir -p "$CONFIG_ROOT/rclone"

# Fail closed on a config that exists but cannot be read. grep exits 2 for
# "permission denied", which is not 1 for "no such remote", and taking the
# false branch here would write a fresh [media] over a remote that is already
# holding files - orphaning every byte uploaded under the old password.
if [[ -s "$CONF" && ! -r "$CONF" ]]; then
  rule
  say "$CONF exists but this user cannot read it."
  say "Refusing to continue: if it already holds a \"media\" remote, writing a"
  say "new one would orphan everything uploaded under the old password."
  say ""
  say "Make it readable by you, then run this again:"
  say "  docker compose run --rm --user 0 --entrypoint chown rclone $(id -u):$(id -g) /config/rclone/rclone.conf"
  exit 1
fi

if [[ -s "$CONF" ]] && grep -q '^\[media\]' "$CONF"; then
  rule
  say "A \"media\" remote already exists in $CONF."
  say "Rewriting it would orphan everything already uploaded: the encryption"
  say "password and the filename settings must stay exactly as they are, or"
  say "rclone can no longer find what it wrote."
  say ""
  say "To start over deliberately, move the file aside first:"
  say "  mv $CONF $CONF.old"
  exit 1
fi

rule
say "Archive tier setup"
rule
say "1) Google Drive"
say "2) SFTP  (Hetzner Storage Box, or any SSH host)"
printf 'Provider [1/2]: '; read -r choice

case "$choice" in
  1)
    backend=drive
    say ""
    say "You need an OAuth client of your own - rclone's shared one stops working"
    say "during 2026. See README \"The archive tier\" for how to make one."
    printf 'Client ID: ';     read -r client_id
    printf 'Client secret: '; read -rs client_secret; echo
    say ""
    say "The id of the Drive folder to keep the archive in - create one called"
    say "media-stack in My Drive if you have not already. Open it; the id is the"
    say "last part of the URL. Scoping the token to one folder means a leaked"
    say "config costs the archive and not the whole Drive."
    printf 'Folder id: '; read -r folder_id
    [[ -n "$client_id" && -n "$client_secret" && -n "$folder_id" ]] || die "all three are required"
    ;;
  2)
    backend=sftp
    say ""
    say "The archive goes in a directory called media-stack on the box."
    printf 'Host (e.g. u123456.your-storagebox.de): '; read -r host
    printf 'Username (e.g. u123456): ';                read -r user
    printf 'Path to the SSH private key: ';            read -r key_file
    [[ -n "$host" && -n "$user" ]] || die "host and username are required"
    [[ -f "$key_file" ]] || die "no such key file: $key_file"
    ;;
  *) die "pick 1 or 2" ;;
esac

rule
say "Encryption"
rule
say "Everything is encrypted before it leaves this machine, so the provider"
say "stores ciphertext and nothing else. The password below is the only thing"
say "that can decrypt it."
say ""
say "  There is no reset. No recovery. No support path."
say "  Lose it and every archived file is permanently unreadable."
say ""
say "Generate it in your password manager and store it there BEFORE typing it"
say "here, along with the salt. Keep a copy somewhere other than this machine."
say ""
printf 'Encryption password: ';   read -rs pw1;  echo
printf 'Again to confirm: ';      read -rs pw2;  echo
[[ "$pw1" == "$pw2" ]] || die "the two passwords do not match"
[[ ${#pw1} -ge 12 ]]   || die "use at least 12 characters"
printf 'Salt (password2, different value): '; read -rs s1; echo
printf 'Again to confirm: ';                  read -rs s2; echo
[[ "$s1" == "$s2" ]] || die "the two salts do not match"
[[ "$s1" != "$pw1" ]] || die "the salt must differ from the password"

say ""
printf 'Type SAVED to confirm both are in your password manager: '; read -r ack
[[ "$ack" == SAVED ]] || die "nothing written - store them first, then run this again"

# Obscured through stdin, so neither value ever appears in the process list.
obs_pw=$(printf '%s' "$pw1" | rc obscure - | tr -d '\r\n')
obs_s=$(printf  '%s' "$s1"  | rc obscure - | tr -d '\r\n')
unset pw1 pw2 s1 s2
[[ -n "$obs_pw" && -n "$obs_s" ]] || die "rclone obscure failed"

umask 077
{
  if [[ "$backend" == drive ]]; then
    printf '[gdrive]\ntype = drive\nscope = drive\nclient_id = %s\nclient_secret = %s\nroot_folder_id = %s\nuse_trash = false\n\n' \
      "$client_id" "$client_secret" "$folder_id"
    base=gdrive:
  else
    printf '[hetzner]\ntype = sftp\nhost = %s\nuser = %s\nkey_file = %s\nshell_type = unix\nmd5sum_command = md5sum\nsha1sum_command = sha1sum\n\n' \
      "$host" "$user" "$key_file"
    base=hetzner:media-stack
  fi
  # The three irreversible settings, fixed rather than prompted.
  printf '[media]\ntype = crypt\nremote = %s\nfilename_encryption = standard\ndirectory_name_encryption = true\nfilename_encoding = base64\npassword = %s\npassword2 = %s\n' \
    "$base" "$obs_pw" "$obs_s"
} > "$CONF"
chmod 600 "$CONF"
unset obs_pw obs_s client_secret
say ""
say "Wrote $CONF (mode 600)."

if [[ "$backend" == drive ]]; then
  rule
  say "Authorising with Google"
  rule
  say "A URL will be printed. Open it, pick your account, and click through the"
  say "\"Google hasn't verified this app\" warning - expected, and shown once."
  say ""
  docker compose run --rm -p 53682:53682 -it --user "$RC_USER" rclone config reconnect gdrive: \
    || die "authorisation failed - rerun this script after moving $CONF aside"
fi

rule
say "Checking"
rule
rc lsd media: --max-depth 1 >/dev/null 2>&1 \
  || die "media: does not answer. Check: docker compose logs rclone"
say "media: answers - the remote and the password are both right."

# The scripts that decide whether an archive exists read this file as you.
if [[ ! -r "$CONF" ]]; then
  die "$CONF is not readable by $(id -un). Something in the container wrote it
as another user. Hand it back with:

  docker compose run --rm --user 0 --entrypoint chown rclone $(id -u):$(id -g) /config/rclone/rclone.conf"
fi

# The rclone service sits behind the "archive" compose profile so that a stack
# with nowhere to overflow to never starts a container that could only fail.
# Now that there is somewhere, turn it on.
if grep -q '^COMPOSE_PROFILES=' .env; then
  cur=$(sed -n 's/^COMPOSE_PROFILES=//p' .env | head -1)
  case ",$cur," in
    *,archive,*) : ;;
    *) sed -i "s|^COMPOSE_PROFILES=.*|COMPOSE_PROFILES=${cur:+$cur,}archive|" .env ;;
  esac
else
  printf 'COMPOSE_PROFILES=archive\n' >> .env
fi
say "Enabled the archive profile in .env."

say ""
say "Next:"
say "  docker compose up -d             start the mount"
say "  ./configure.sh                   add the archive root folders and library paths"
say "  ./mover.sh install               overflow there when the disk fills"
