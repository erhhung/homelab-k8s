#!/usr/bin/env bash

# https://github.com/rclone/rclone

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2086 # Double quote prevent globbing

set -eo pipefail

REL="https://github.com/rclone/rclone/releases"
VER=$(curl -ILs "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
curl -fsSLo /tmp/rclone.zip "$REL/download/v${VER}/rclone-v${VER}-linux-$ARCH.zip"
unzip -d /usr/local/bin -joq /tmp/rclone.zip '*/rclone'; rm -f /tmp/rclone.zip
rclone --version
