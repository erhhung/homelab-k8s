#!/usr/bin/env bash

# Trim mounted, healthy Longhorn filesystem PVCs in the current kubectl context.
#
# Usage: trimfs.sh [namespace...]
#
# Requires Bash 3.2+, kubectl, jq, awk, and curl in the Longhorn manager image.
# Uses the UI's trimFilesystem action, including share-manager handling for RWX.
# Snapshot retention is unchanged; blocks retained by snapshots stay allocated.

set -euo pipefail

 WHITE=$'\033[1;37m'
  CYAN=$'\033[1;36m'
   RED=$'\033[1;31m'
YELLOW=$'\033[1;33m'
 GREEN=$'\033[1;32m'
 RESET=$'\033[0m'

CONTEXT=''
RUNTIME_DIR=''
MANAGER_NAMESPACE=''
MANAGER_POD=''
API_URL=''

log() {
  local line
  while IFS= read -r line; do
    printf '%s[%s]%s %s\n' "$WHITE" "$(LC_TIME=C date '+%Y-%m-%d %I:%M:%S %p')" "$RESET" "$line"
  done <<< "$*"
}

die() {
  log "${RED}ERROR: $*${RESET}" >&2
  exit 1
}

cleanup() {
  [[ -z "$RUNTIME_DIR" ]] || rm -rf -- "$RUNTIME_DIR"
}

kube() {
  local output status
  if output=$(kubectl --context "$CONTEXT" --request-timeout=150s "$@" 2> "$RUNTIME_DIR/error"); then
    [[ ! -s "$RUNTIME_DIR/error" ]] || \
      log "$(<"$RUNTIME_DIR/error")" >&2
    printf '%s\n' "$output"
  else
    status=$?
    [[ -z "$output" ]] || log "$output" >&2
    [[ ! -s "$RUNTIME_DIR/error" ]] || \
      log "$(<"$RUNTIME_DIR/error")" >&2
    return "$status"
  fi
}

api() {
  local path=$1
  shift
  kube -n "$MANAGER_NAMESPACE" exec "$MANAGER_POD" -c longhorn-manager -- \
    curl --silent --show-error --fail-with-body --connect-timeout 10 --max-time 120 \
    --header 'Content-Type: application/json' "$@" "$API_URL/$path"
}

size_bytes() {
  jq -er '[.controllers[]? | select(.running == true) | .actualSize | tonumber] |
    max // error("Longhorn did not report an allocated storage size")'
}

format_gib() {
  LC_ALL=C awk -v bytes="$1" 'BEGIN {
    size = bytes / 1073741824
    if (size >= 10) printf "%.1f", size
    else {
      value = sprintf("%.2f", size)
      sub(/0+$/, "", value)
      sub(/\.$/, "", value)
      printf "%s", value
    }
  }'
}

main() {
  local command requested namespaces invalid managers manager volumes pvcs inventory rows
  local namespace pvc volume label current before after reduction before_gib after_gib reduction_gib
  local pvc_count namespace_count total=0 reduced_count=0 summary_color=$YELLOW

  log 'Taking inventory of eligible PVCs...'
  for command in kubectl jq awk; do
    command -v "$command" > /dev/null || \
      die "Required command not found: $command"
  done
  if ! CONTEXT=$(kubectl config current-context 2>&1); then die "$CONTEXT"; fi
  [[ -n "$CONTEXT" ]] || die 'No current kubectl context is set.'
  RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trimfs.XXXXXX")

  trap cleanup EXIT
  trap 'die "Interrupted; the current trim may still be finishing on the server."' INT TERM

  requested=$(jq -cn --args '$ARGS.positional | unique' -- "$@")
  if (($# > 0)); then
    namespaces=$(kube get namespaces -o json) || \
      die 'Unable to list namespaces.'
    invalid=$(jq -r --argjson requested "$requested" \
      '($requested - [.items[].metadata.name]) | join(", ")' <<< "$namespaces")
    [[ -z "$invalid" ]] || die "Invalid namespace(s): $invalid"
  fi

  managers=$(kube get pods -A -l app=longhorn-manager -o json) || \
    die 'Unable to discover Longhorn managers.'
  manager=$(jq -r '[.items[] | select(.metadata.deletionTimestamp == null and
    .status.phase == "Running" and any(.status.conditions[]?;
      .type == "Ready" and .status == "True"))] |
    sort_by(.metadata.namespace, .metadata.name) | .[0] // empty |
    [.metadata.namespace, .metadata.name, .status.podIP] | @tsv' <<< "$managers")

  [[ -n "$manager" ]] || \
    die "No ready Longhorn manager found in context $CONTEXT."
  IFS=$'\t' read -r MANAGER_NAMESPACE MANAGER_POD API_URL <<< "$manager"
  # managers listen on their pod IP, so forwarding localhost:9500 doesn't work
  if [[ "$API_URL" == *:* ]]; then API_URL="[$API_URL]"; fi
  API_URL="http://$API_URL:9500/v1"

  volumes=$(api volumes) || die 'Unable to list Longhorn volumes.'
  pvcs=$(kube get pvc -A -o json) || die 'Unable to list PVCs.'
  printf '%s\n' "$volumes" > "$RUNTIME_DIR/volumes.json"

  inventory=$(jq -c --argjson requested "$requested" \
    --slurpfile volumes "$RUNTIME_DIR/volumes.json" '
    def eligible:
      .state == "attached" and .robustness == "healthy" and .disableFrontend != true and
      all(.controllers[]?; .isExpanding != true) and
      all(.replicas[]?; .mode != "WO") and all(.rebuildStatus[]?; .isRebuilding != true);
    [$volumes[0].data[] | select(eligible)] as $volumes |
    [.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Bound" and
      (.spec.volumeMode // "Filesystem") == "Filesystem") |
      . as $pvc | select(($requested | length) == 0 or
        ($requested | index($pvc.metadata.namespace)) != null) |
      $volumes[] | select(.kubernetesStatus.namespace == $pvc.metadata.namespace and
        .kubernetesStatus.pvcName == $pvc.metadata.name and
        .kubernetesStatus.pvName == $pvc.spec.volumeName) |
      {namespace:$pvc.metadata.namespace, pvc:$pvc.metadata.name, volume:.name}] |
    unique_by(.volume) | sort_by(.namespace, .pvc)' <<< "$pvcs")

  pvc_count=$(jq 'length' <<< "$inventory")
  namespace_count=$(jq '[.[].namespace] | unique | length' <<< "$inventory")
  log "Trimming filesystems on $pvc_count PVC(s) across $namespace_count namespace(s)..."

  rows=$(jq -r '.[] | [.namespace, .pvc, .volume] | @tsv' <<< "$inventory")
  # redirected loop, rather than pipeline, keeps summary totals in this shell
  while IFS=$'\t' read -r namespace pvc volume; do
    [[ -n "$volume" ]] || continue

    label="$namespace/$pvc"
    log "Trimming ${CYAN}${namespace}${RESET}/${YELLOW}${pvc}${RESET}..."
    current=$(api "volumes/$volume") || die "Unable to inspect $label."
    jq -e '
      .state == "attached" and
      .robustness == "healthy" and
      .disableFrontend != true and
      all(.controllers[]?; .isExpanding != true) and
      all(.replicas[]?; .mode != "WO") and
      all(.rebuildStatus[]?; .isRebuilding != true)' > /dev/null <<< "$current" || \
      die "$label is no longer eligible for filesystem trim."
    before=$(size_bytes <<< "$current") || \
      die "Unable to determine allocated size for $label."

    api "volumes/$volume?action=trimFilesystem" --request POST --data '{}' > /dev/null ||
      die "Filesystem trim failed for $label; stopping without retrying the request."
    sleep 5 # engine allocation statistics are refreshed asynchronously after fstrim

    current=$(api "volumes/$volume") || \
      die "Unable to inspect $label after trimming."
    after=$(size_bytes <<< "$current") || \
      die "Unable to determine allocated size for $label after trimming."
    before_gib=$(format_gib "$before")
     after_gib=$(format_gib "$after")
     reduction=$((before - after))
     reduction_gib=0

    if ((reduction > 0)); then
      reduction_gib=$(format_gib "$reduction")
    fi
    if [[ "$reduction_gib" != 0 ]]; then
      total=$((total + reduction))
      reduced_count=$((reduced_count + 1))
      log "$label: ${before_gib}Gi to ${GREEN}${after_gib}Gi${RESET} (${GREEN}${reduction_gib}Gi${RESET})"
    else
      log "$label: ${after_gib}Gi ${YELLOW}(no reduction)${RESET}"
    fi
  done <<< "$rows"

  if ((total > 0)); then summary_color=$GREEN; fi
  log "Reclaimed ${summary_color}$(format_gib "$total")Gi${RESET} across $reduced_count PVC(s)."
}

main "$@"
