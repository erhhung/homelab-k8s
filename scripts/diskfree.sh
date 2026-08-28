#!/usr/bin/env bash

# show available disk space on all cluster
# nodes (assumes `ssh <host>` works without
# password for hosts: rancher & k8s1..k8sN)

# shellcheck disable=SC2086 # Double quote prevent globbing
# shellcheck disable=SC2207 # Prefer mapfile to split output
# shellcheck disable=SC2059 # Don't use vars in printf format

set -o pipefail

K8S_HOSTS=(rancher $(seq -f "k8s%g" 1 6))
DF_MOUNTS=(/ /data)

YELLOW='\033[1;33m'
LTCYAN='\x1B[1;36m'
 NOCLR='\033[0m'

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
reqcmds parallel sponge numfmt || exit

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

echo -en "\n${LTCYAN}Gathering disk information...${NOCLR}"
unset last_host

while IFS= read -r line; do
  # parallel --tag prefixes each
  # output line with `host<tab>`
  host="${line%%$'\t'*}"
  line="${line#*$'\t'}"

  [ "$host" == "$last_host" ] || {
    # hide the initial wait message
    [ "$last_host" ] && echo  || \
      printf '\r\033[2K'
    title "${YELLOW}$host${NOCLR}"
    last_host=$host
  }
  echo "$line"
done < <(
  parallel --tag --keep-order \
    ssh {} -- df -h "${DF_MOUNTS[@]}"  \
    ::: "${K8S_HOSTS[@]}" 2> /dev/null |
    sponge # buffer all host results
)

# show available storage from Longhorn perspective
# "allocatable" is size available for provisioning

echo -en "\n${LTCYAN}Gathering Longhorn information...${NOCLR}"
kubectl="kubectl --context homelab -n longhorn-system -o json"

COLS=(node replicas disk capacity
  allocatable available scheduled reserved)
FMTS='%-4s  %8s  %-25s  %8s  %11s  %9s  %9s  %8s'
printf -v header "$FMTS" "${COLS[@]^^}"

while IFS=$'\t' read -r node replicas disk capacity \
         allocatable available scheduled reserved; do
  [ "$header" ] && {
    printf '\r\033[2K'
    title "${YELLOW}$header${NOCLR}"
    unset header
  }
  sizes=($(numfmt --to=iec $capacity $allocatable \
                   $available $scheduled $reserved))
  printf "$FMTS\n" $node $replicas $disk "${sizes[@]}"
done < <(
  $kubectl get nodes.longhorn.io | \
    jq --slurpfile replicaList <(
      $kubectl get replicas.longhorn.io
      ) -r '(
        $replicaList[0].items
        | reduce .[] as $replica ({};
            if $replica.metadata.deletionTimestamp == null
              and ($replica.spec.nodeID // "") != ""
            then .[$replica.spec.nodeID] += 1
            else .
            end
          )
        ) as $replicaCounts
        | .items[] as $node
        |  $node.metadata.name            as $name
        | ($node.spec.disks        // {}) as $specdisks
        | ($node.status.diskStatus // {})
        |  to_entries[]
        | .key as $disk
        | ($specdisks[$disk].storageReserved // 0) as $reserved
        | ($replicaCounts[$name]             // 0) as $replicas
        | (.value.storageMaximum             // 0) as $capacity
        | (.value.storageAvailable           // 0) as $available
        | (.value.storageScheduled           // 0) as $scheduled
        | ($capacity - $reserved - $scheduled)     as $schedulable
        | (if   $available    < $schedulable
          then $available else $schedulable end)  as $allocatable
        | [$name, $replicas, $disk, $capacity,
          $allocatable, $available, $scheduled, $reserved]
        | @tsv
      '
)
