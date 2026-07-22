#!/usr/bin/env bash

# https://github.com/sharkdp/bat

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

REL="https://github.com/sharkdp/bat/releases"
VER=$(curl -ILs "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
curl -fsSL "$REL/download/v${VER}/bat-v${VER}-$(uname -m)-unknown-linux-gnu.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner --strip 1 "*/bat"
bat --version
