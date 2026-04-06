#!/usr/bin/env bash

# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2128 # Expanding array without index
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2329 # This function is never invoked

set -eo pipefail

# strip punctuations, replace spaces
# with dashes, convert to lower case
MAC_NODE_ID=$(scutil --get ComputerName | \
  perl -C -pe 's/[\p{P}\p{S}]//g;
               s/\s+/-/g;
               s/^-|-$//g;
               $_ = lc($_)')
GATEWAY_HOST="openclaw.fourteeners.local"
GATEWAY_PORT="443"

APP="/Applications/OpenClaw.app/Contents/MacOS/OpenClaw"
# npm install --global openclaw
# installs into /usr/local/bin
CLI="/usr/local/bin/openclaw"

kill_pgroup() {
  local pgid
  pgid=($(ps -o pgid= -p $1  2> /dev/null)) || return 0
  [ "$pgid" ] && kill -$pgid 2> /dev/null   || true
}

cleanup() {
  (( cleaning )) && return 0
  cleaning=1

  kill_pgroup  $app_pid
  kill_pgroup $node_pid

  wait $app_pid $node_pid 2> /dev/null || true
}
trap cleanup EXIT INT TERM

# launch the Mac companion app, which fails
# to register with remote gateway as a node:
# https://github.com/openclaw/openclaw/issues/57243
# setsid: brew install util-linux (append to
# PATH: $HOMEBREW_PREFIX/opt/util-linux/bin)
setsid $APP 2> /dev/null &
app_pid=$!

# --node-id is supposed to override the device
# ID, but, in practice, the node is still only
# addressable by its display name & device ID:
# https://github.com/openclaw/openclaw/issues/61569
setsid $CLI node run \
  --node-id $MAC_NODE_ID  \
  --host    $GATEWAY_HOST \
  --port    $GATEWAY_PORT \
  --tls  &
node_pid=$!

wait -n $app_pid $node_pid || true

if ! kill -0 $app_pid 2> /dev/null; then
  echo "OpenClaw app exited; stopping node"
elif ! kill -0 $node_pid 2> /dev/null; then
  echo "openclaw-node exited; stopping app"
fi
exit 1
