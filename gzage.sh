#!/usr/bin/env bash

# gzips and then encrypts specified
# file using age encryption utility
#
# usage: ./gzage.sh <file>
#
# if <file> already has a .gz extension, then it will
# not be gzipped again prior to encryption; if <file>
# has a .gz.age extension, then it will be decrypted
# and then gunzipped into its original file without
# the .gz.age extension

[ "$1" ] || {
  echo "Usage: $0 <file>"
  exit 0
}
[ -f "$1" ] || {
  echo "File not found: $1"
  exit 1
}

# require given commands
# to be $PATH accessible
# example: reqcmds age || return
reqcmds() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" &> /dev/null && continue
    echo >&2 "Please install \"$cmd\" first!"
    return 1
  done
}

# ensure required tools installed
reqcmds ansible-vault age || exit

set -euo pipefail
cd "$(dirname "$0")"

     file="$1"
orig_file="$1"
orig_file="${orig_file%.age}"
orig_file="${orig_file%.gz}"
  gz_file="${orig_file}.gz"
 age_file="${gz_file}.age"

export ANSIBLE_CONFIG=./ansible.cfg
VAULTFILE="group_vars/all/vault.yml"

AGE_KEY=$(ansible-vault view "$VAULTFILE" | \
  grep age_secret_key | awk '{print $2}')

encrypt() {
  [ -f "$orig_file" ] && \
    gzip -9nfq "$orig_file"
  [ -f "$gz_file" ] && {
    age -e -i <(echo "$AGE_KEY") -a -o "$age_file" < "$gz_file"
    rm  -f "$gz_file"
  }
}

decrypt() {
   [ -f "$age_file" ] && {
    age -d -i <(echo "$AGE_KEY") -o "$gz_file" < "$age_file"
    rm  -f "$age_file"
   }
   [ -f "$gz_file" ] && \
     gzip -dfq "$gz_file"
}

if [[ "$file" == *.gz.age ]]; then
  decrypt
else
  encrypt
fi
