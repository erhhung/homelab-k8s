#!/usr/bin/env bash

# https://github.com/ajeetdsouza/zoxide#installation

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | \
  bash -s -- --bin-dir /usr/local/bin --man-dir /usr/local/share/man
zoxide --version
