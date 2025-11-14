# https://github.com/helmfile/vals

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2006 # Prefer $(...) over legacy `...`
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2086 # Double quote prevent globbing

set -eo pipefail

REL="https://github.com/helmfile/vals/releases"
VER=$(curl -Is "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')

# check if latest version already installed
command -v vals &> /dev/null && {
  ver=$(v=(`vals version`); echo ${v[1]})
  [ "$ver" == "$VER" ] && exit 9 # no change
}
ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
curl -fsSL "$REL/download/v${VER}/vals_${VER}_linux_${ARCH}.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner vals
