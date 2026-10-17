#!/usr/bin/env bash

# run `xfs_repair` on specified Longhorn volume
# to fix errors like `mount system call failed:
# Structure needs cleaning.`
#
#   usage: volrepair.sh [extra-args] pvc-<volume-uuid>
# example: volrepair.sh -L pvc-fd70bcf7-244d-4502-840e-62bbec7bff4c
#    note: -L clears the XFS journal, potentially causing data loss

# shellcheck disable=SC2086 # Double quote prevent globbing

set -o pipefail

kubectl="kubectl --context homelab"

args=()
while [[ "$1" && "$1" != pvc-* ]]; do
  args+=("$1")
  shift
done

vol=$1
[ "$vol" ] || {
  echo "Usage: volrepair.sh [extra-args] pvc-<volume-uuid>"
  exit
}

[[ "$vol" == pvc-* && ${#vol} -eq 40 ]] || {
  echo >&2 "Longhorn volume names must start with"
  echo >&2 "pvc and be exactly 40 characters long!"
  exit 1
}

node=$($kubectl -n longhorn-system get volumes.longhorn.io \
  "$vol" -o jsonpath='{.status.currentNodeID}' 2> /dev/null)
[ "$node" ] || {
  echo >&2 "Volume $vol not attached!"
  exit 1
}

ssh_node() {
  ssh -i ~/.ssh/$USER.pem -o StrictHostKeyChecking=no $node "$@"
}
ssh_node "sudo xfs_repair ${args[*]} /dev/longhorn/$vol"
