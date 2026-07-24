#!/usr/bin/env bash

# https://mise.jdx.dev/installing-mise.html

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

export MISE_INSTALL_PATH=/usr/local/bin/mise
export MISE_INSTALL_HELP=0

curl -s https://mise.run | sh
mise version --json
