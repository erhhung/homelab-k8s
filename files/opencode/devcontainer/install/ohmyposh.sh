#!/usr/bin/env bash

# https://ohmyposh.dev/docs/installation/linux

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

curl -s https://ohmyposh.dev/install.sh | \
  bash -s -- -d /usr/local/bin
oh-my-posh --version

install -D -m 644 /config/ohmyposh.yaml \
  "$XDG_CONFIG_HOME/oh-my-posh/theme.yaml"
