#!/usr/bin/env bash

# shellcheck disable=SC2059 # Don't use vars in printf format

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

# show available storage from Longhorn perspective
# "allocatable" is size available for provisioning

COL_FMT='%-4s  %-25s  %8s  %11s  %9s  %11s  %9s  %8s'
printf -v header "${COL_FMT}" NODE DISK CAPACITY \
  ALLOCATABLE AVAILABLE SCHEDULABLE SCHEDULED RESERVED
echo; title "${YELLOW}${header}${NOCLR}"

kubectl() {
  ssh k8s1 -- /var/lib/rancher/rke2/bin/kubectl \
     --kubeconfig /etc/rancher/rke2/rke2.yaml "$@"
}

kubectl get nodes.longhorn.io -n longhorn-system -o json | \
  jq -r '.items[] as $node
  |  $node.metadata.name            as $name
  | ($node.spec.disks        // {}) as $specdisks
  | ($node.status.diskStatus // {})
  |  to_entries[]
  | .key as $disk
  | ($specdisks[$disk].storageReserved // 0) as $reserved
  | (.value.storageMaximum             // 0) as $capacity
  | (.value.storageAvailable           // 0) as $available
  | (.value.storageScheduled           // 0) as $scheduled
  | ($capacity - $reserved - $scheduled)     as $schedulable
  | (if   $available    < $schedulable
     then $available else $schedulable end)  as $allocatable
  | [$name, $disk, $capacity, $allocatable,
     $available, $schedulable, $scheduled,
     $reserved]
  | @tsv
' | while IFS=$'\t' read -r node disk capacity \
      allocatable available schedulable scheduled reserved; do
    printf "$COL_FMT\n" \
      "$node" \
      "$disk" \
      "$(numfmt --to=iec "$capacity")" \
      "$(numfmt --to=iec "$allocatable")" \
      "$(numfmt --to=iec "$available")" \
      "$(numfmt --to=iec "$schedulable")" \
      "$(numfmt --to=iec "$scheduled")" \
      "$(numfmt --to=iec "$reserved")"
  done
