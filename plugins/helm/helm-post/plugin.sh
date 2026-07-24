#!/usr/bin/env bash
set -eo pipefail

[ "$1" ] || {
  echo "USAGE: plugin.sh <post-renderer-script>"
  echo "Specify script via --post-renderer-args"
  exit 1
} >&2
[ -x "$1" ] || {
  echo "ERROR: \"$1\" not found or executable!"
  exit 1
} >&2

# preserves Helm's manifest stdin/stdout stream
exec "$@"
