#!/usr/bin/env bash

# https://github.com/kamiyaa/joshuto#installation

# shellcheck disable=SC2148 # Tips depend on target shell
# shellcheck disable=SC2086 # Double quote prevent globbing

set -eo pipefail

API="https://api.github.com/repos/kamiyaa/joshuto/releases"
VER=$(curl -Lfs $API | jq -r '.[0].tag_name | ltrimstr("v")')
REL="https://github.com/kamiyaa/joshuto/releases"
curl -fsSL "$REL/download/v${VER}/joshuto-v${VER}-$(uname -m)-unknown-linux-gnu.tar.gz" | \
  tar -xz -C /usr/local/bin --no-same-owner --strip 1 "*/joshuto"
joshuto --version | head -1

# bootstrap config with defaults
URL="https://raw.githubusercontent.com/kamiyaa/joshuto/refs/tags/v${VER}/config"
DIR="$XDG_CONFIG_HOME/joshuto"

CONFIGS=(
  joshuto
  theme
  icons
  keymap
  bookmarks
  mimetype
  preview_file.sh
)

mkdir -p $DIR
for file in "${CONFIGS[@]}"; do
  [[ $file == *.* ]] || file+=.toml
  wget -qO "$DIR/$file" "$URL/$file"
done
chmod +x $DIR/*.sh

PATCHES=(
  'joshuto  s/" *#.*$/"/; s/gourp/group/'
  'joshuto /^show_hidden/ s/false/true/'
  'joshuto /^show_icons/  s/false/true/'
  'joshuto /^linemode/    s/size/size|mtime/'
  'theme   /^lscolors_enabled/ s/false/true/'
)

while read -r file regex; do
  [[ $file == *.* ]] || file+=.toml
  sed -i -E "$regex" "$DIR/$file"
done < <(printf "%s\n" "${PATCHES[@]}")
