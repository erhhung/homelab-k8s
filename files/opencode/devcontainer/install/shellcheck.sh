#!/usr/bin/env bash

# https://github.com/koalaman/shellcheck

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

REL="https://github.com/koalaman/shellcheck/releases"
VER=$(curl -ILs "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
curl -fsSL "$REL/download/v${VER}/shellcheck-v${VER}.linux.$(uname -m).tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner --strip 1 "*/shellcheck"
shellcheck --version
