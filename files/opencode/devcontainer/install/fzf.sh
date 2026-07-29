#!/usr/bin/env bash

# https://github.com/junegunn/fzf#installation
# https://github.com/lincheney/fzf-tab-completion#installation

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

REL="https://github.com/junegunn/fzf/releases"
VER=$(curl -ILs "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
curl -fsSL "$REL/download/v${VER}/fzf-$VER-linux_${ARCH}.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner fzf
fzf --version

DIR="$XDG_CONFIG_HOME/fzf"
mkdir -p "$DIR"
wget -qO- https://raw.githubusercontent.com/lincheney/fzf-tab-completion/refs/heads/master/bash/fzf-bash-completion.sh \
                                                                                        > "$DIR/fzf-bash-completion.sh"
