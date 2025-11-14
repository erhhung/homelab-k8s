# https://github.com/helmfile/helmfile

# shellcheck disable=SC2148 # Tips depend on target shell

set -eo pipefail

REL="https://github.com/helmfile/helmfile/releases"
VER=$(curl -Is "$REL/latest" | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')

# check if latest version already installed
command -v helmfile &> /dev/null && {
  ver=$(helmfile version -o short 2> /dev/null)
  [ "$ver" == "$VER" ] && exit 9 # no change
}
ARCH=$(uname -m | sed -e 's/aarch64/arm64/' -e 's/x86_64/amd64/')
curl -fsSL "$REL/download/v${VER}/helmfile_${VER}_linux_${ARCH}.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner helmfile
