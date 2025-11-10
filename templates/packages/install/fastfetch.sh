# https://github.com/fastfetch-cli/fastfetch

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2006 # Prefer $(...) over legacy `...`
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2086 # Double quote prevent globbing

set -eo pipefail

REL="https://github.com/fastfetch-cli/fastfetch/releases/latest"
VER=$(curl -Is $REL | sed -En 's/^location:.+\/tag\/(.+)\r$/\1/p')

# check if latest version already installed
command -v fastfetch &> /dev/null && {
  ver=$(v=(`fastfetch --version`); echo ${v[1]})
  [ "$ver" == "$VER" ] && exit 9 # no change
}
ARCH=$(uname -m | sed -e 's/x86_64/amd64/') # or aarch64
curl -fsSL "$REL/download/fastfetch-linux-$ARCH.tar.gz" | \
  tar -xz -C / --no-same-owner --strip-components=1 \
    "fastfetch-linux-$ARCH"

# remove "flashfetch" binary and other unnessary files
rm -rf /usr/bin/flashfetch /usr/share/{zsh,fish,licenses}
