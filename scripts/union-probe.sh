#!/usr/bin/env bash
# Answers the one question the union design turns on, before anything is moved.
#
# The unit starts mergerfs Before=docker.service, so mergerfs is already running
# when the rclone container mounts the cloud branch underneath it. If mergerfs
# resolves its branches once at startup, the archive half of the library stays
# invisible and every app sees a half-empty library. If it resolves per
# operation, the ordering is harmless.
#
# The question is specifically about a FUSE *mount* appearing under a branch,
# not a file appearing in it - so the late arrival here is itself a mergerfs
# mount, which needs no root and reproduces the real case.
set -euo pipefail
command -v mergerfs >/dev/null || { echo "mergerfs is not installed yet - run scripts/union-setup.sh first" >&2; exit 1; }

t=$(mktemp -d)
cleanup() {
  fusermount -u "$t/union"    2>/dev/null || true
  fusermount -u "$t/b/media"  2>/dev/null || true
  rm -rf "$t"
}
trap cleanup EXIT

mkdir -p "$t/a/media" "$t/b/media" "$t/union" "$t/cloudish"
echo local > "$t/a/media/local.txt"
# cloudish is what gets mounted AT b/media, so its contents are b/media's
# contents - not a further "media" level, which is a mistake that makes the
# probe report a false negative.
echo cloud > "$t/cloudish/cloud.txt"

mergerfs -o use_ino,category.create=ff "$t/a:$t/b" "$t/union"
echo "  1. union up, b branch empty:        $(ls -1 "$t/union/media" 2>/dev/null | tr '\n' ' ')"

# A real FUSE mount appears under the b branch, after the union is running.
mergerfs -o use_ino "$t/cloudish" "$t/b/media"
echo "  2. a FUSE mount now under b/media:  $(ls -1 "$t/b/media" 2>/dev/null | tr '\n' ' ')"
echo "  3. what the union shows:            $(ls -1 "$t/union/media" 2>/dev/null | tr '\n' ' ')"

if [[ -e "$t/union/media/cloud.txt" ]]; then
  echo "  => branches resolve per operation: a late mount IS visible. Before=docker is safe."
else
  echo "  => a late mount is NOT visible. The unit must start AFTER the rclone"
  echo "     container, and compose needs a healthcheck gate so apps wait for it."
fi
