#!/usr/bin/env bash

# run `xfs_repair` on specified Longhorn volume
# to fix errors like `mount system call failed:
# Structure needs cleaning.`
#
# usage: volrepair.sh pvc-<volume-uuid>

# shellcheck disable=SC2086 # Double quote prevent globbing

set -o pipefail

vol=$1
[ "$vol" ] || {
  echo "Usage: volrepair.sh pvc-<volume-uuid>"
  exit
}

[[ "$vol" == pvc-* && ${#vol} -eq 40 ]] || {
  echo >&2 "Longhorn volume names must start with"
  echo >&2 "pvc and be exactly 40 characters long!"
  exit 1
}

node=$(kubectl -n longhorn-system get volumes.longhorn.io \
  "$vol" -o jsonpath='{.status.currentNodeID}' 2> /dev/null)
[ "$node" ] || {
  echo >&2 "Volume $vol not attached!"
  exit 1
}

ssh_node() {
  ssh -i ~/.ssh/$USER -o StrictHostKeyChecking=no $node "$@"
}
ssh_node "sudo xfs_repair -L /dev/longhorn/$vol"
