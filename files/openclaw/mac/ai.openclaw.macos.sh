#!/usr/bin/env bash
set -eo pipefail

APP="/Applications/OpenClaw.app/Contents/MacOS/OpenClaw"
# npm install --global openclaw
# installs into /usr/local/bin
CLI="/usr/local/bin/openclaw"

# launch the Mac companion app, which fails
# to register with remote gateway as a node:
# https://github.com/openclaw/openclaw/issues/57243
$APP 2> /dev/null &
app_pid=$!

$CLI node run --host openclaw.fourteeners.local --port 443 --tls &
node_pid=$!

cleanup() {
  kill $app_pid $node_pid 2> /dev/null || true
  wait $app_pid $node_pid 2> /dev/null || true
}
trap cleanup EXIT INT TERM

while :; do
  kill -0 $app_pid 2> /dev/null || {
    echo "OpenClaw app exited; stopping node"
    exit 1
  }
  kill -0 $node_pid 2> /dev/null || {
    echo "openclaw-node exited; stopping app"
    exit 1
  }
  sleep 1
done
