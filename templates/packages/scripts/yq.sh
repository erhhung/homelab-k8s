# https://github.com/mikefarah/yq

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2164 # Use cd ... || exit if cd fails
# shellcheck disable=SC2006 # Prefer $(...) over legacy `...`
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2086 # Double quote prevent globbing

set -eo pipefail

REL="https://github.com/mikefarah/yq/releases/latest"
VER=$(curl -Is $REL | sed -En 's/^location:.+\/tag\/v(.+)\r$/\1/p')

# check if latest version already installed
command -v yq &> /dev/null && {
  ver=$(v=(`yq --version`); echo ${v[-1]#v})
  [ "$ver" == "$VER" ] && exit 9 # no change
}
mkdir -p /tmp/yq
( cd     /tmp/yq
  ARCH=$(uname -m | sed -e 's/aarch64/arm64/' \
                        -e  's/x86_64/amd64/')
  curl -fsSL "$REL/download/yq_linux_$ARCH.tar.gz" | \
    tar -xz --no-same-owner
  cp -a "yq_linux_$ARCH" /usr/bin/yq
  ./install-man-page.sh
)
rm -rf /tmp/yq
