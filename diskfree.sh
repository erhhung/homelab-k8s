#!/usr/bin/env bash

# show available disk space on all cluster
# nodes (assumes `ssh <host>` works without
# password for hosts: rancher & k8s1..k8sN)

  NOCLR='\033[0m'
 YELLOW='\033[1;33m'
NUM_K8S=6

# print given title with
# another line of dashes
title() {
  local s="$*" d l t
  echo -e "$s"

  # use PCRE (*SKIP)(*F) trick to preserve ANSI
  # color codes while replacing all other chars
  d="$(perl -pe 's/(?:\\(033|x1B)\[[0-9;]*[mGKHF])(*SKIP)(*F)|./-/g' <<< "$s")"

  #  remove  leading and trailing dashes
  # matching leading and trailing spaces
  l="${s%%[^[:space:]]*}" #  leading spaces
  t="${s##*[^[:space:]]}" # trailing spaces
  echo -e "$l${d:${#l}:${#d}-${#l}-${#t}}$t"
}

# run_df <host> <path> [path...]
run_df() {
  echo
  title "$YELLOW$1$NOCLR"
  # shellcheck disable=SC2029
  ssh "$1" -- df -h "${@:2}"
}

run_df rancher /
for i in $(seq 1 $NUM_K8S); do
  run_df "k8s$i" / /data
done
