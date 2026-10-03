#!/usr/bin/env bash

# https://github.com/darold/pgFormatter

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2086 # Double quote prevent globbing

set -eo pipefail

dnf install -y perl-ExtUtils-MakeMaker perl-FindBin perl-open perl-autodie
dnf clean all
rm -rf /var/log/* /var/cache/dnf

REPO="https://github.com/darold/pgFormatter"
VER=$(curl -ILs "$REPO/releases/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')
curl -fsSL "$REPO/archive/refs/tags/v${VER}.tar.gz" | tar -xz -C /tmp --no-same-owner
(cd /tmp/pgFormatter-$VER && perl Makefile.PL && make && make install)
rm -rf /tmp/pgFormatter-$VER
pg_format --version
