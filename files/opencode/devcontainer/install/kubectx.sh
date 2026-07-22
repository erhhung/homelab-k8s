#!/usr/bin/env bash

# https://github.com/ahmetb/kubectx

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2086 # Double quote prevent globbing

set -eo pipefail

REL="https://github.com/ahmetb/kubectx/releases"
VER=$(curl -ILs "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
ARCH=$(uname -m | sed -e 's/aarch64/arm64/') # or x86_64
for tool in kubectx kubens; do
  curl -fsSL "$REL/download/v${VER}/${tool}_v${VER}_linux_${ARCH}.tar.gz" | \
    tar -xz -C /usr/local/bin --no-same-owner $tool
  $tool --version
done
