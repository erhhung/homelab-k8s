#!/usr/bin/env bash

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2086 # Double quote prevent globbing

# OpenTofu VSCode extension expects the tofu binary
# to be found in /usr/local/bin unless user setting
# `opentofu.languageServer.tofu.path` is configured

usr_local_bins=(
  tofu
)
for bin in "${usr_local_bins[@]}"; do
  if path=$(command -v $bin) && \
      [ "$path" != /usr/local/bin/$bin ]; then
    ln -sf "$path" /usr/local/bin/$bin
  fi
done
