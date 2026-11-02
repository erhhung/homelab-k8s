#!/usr/bin/env bash

# Trim mounted, healthy Longhorn filesystem PVCs in the current kubectl context.
#
# Usage: trimfs.sh [namespace...]
#
# Requires Bash 3.2+, kubectl, jq, awk, and curl in the Longhorn manager image.
# Uses the UI's trimFilesystem action, including share-manager handling for RWX.
# Snapshot retention is unchanged; blocks retained by snapshots stay allocated.
# Reads are retried; interrupted requests are not blindly replayed. Individual
# PVC failures do not stop the run, but cause a nonzero exit after the summary.

set -euo pipefail

 WHITE=$'\033[1;37m'
  CYAN=$'\033[1;36m'
   RED=$'\033[1;31m'
YELLOW=$'\033[1;33m'
 GREEN=$'\033[1;32m'
 RESET=$'\033[0m'

CONTEXT=''
RUNTIME_DIR=''

ELIGIBLE='def eligible:
  .state      == "attached" and
  .robustness ==  "healthy" and
  .disableFrontend  != true and
  .frontendDisabled != true and
  all(.controllers[]?;   .isExpanding  != true) and
  all(.replicas[]?;      .mode         != "WO") and
  all(.rebuildStatus[]?; .isRebuilding != true);'

# shellcheck disable=SC2016 # Expr won't expand in '' quotes
POD_CLAIMS='def mounted_claims:
  . as $pod |
  ([$pod.status.containerStatuses[]?,
    $pod.status.initContainerStatuses[]?,
    $pod.status.ephemeralContainerStatuses[]? |
      select(.state.running != null) | .name]) as $running |
  ([$pod.spec.containers[]?,
    $pod.spec.initContainers[]?,
    $pod.spec.ephemeralContainers[]? |
      select(.name as $name | $running | index($name)) |
        .volumeMounts[]?.name]) as $mounts |
  $pod.spec.volumes[]? |
    select(.persistentVolumeClaim != null and
      (.name as $name | $mounts | index($name))) |
      .persistentVolumeClaim.claimName;'

log() {
  local line
  while IFS= read -r line; do
    printf '%s[%s]%s %s\n' "$WHITE" "$(LC_TIME=C date '+%Y-%m-%d %I:%M:%S %p')" "$RESET" "$line"
  done <<< "$*"
}
warn() {
  log "${YELLOW}WARNING: $*${RESET}" >&2
}
error() {
  log "${RED}ERROR: $*${RESET}" >&2
}
die() {
  error "$@"; exit 1
}
cleanup() {
  [ "$RUNTIME_DIR" ] && \
    rm -rf "$RUNTIME_DIR"
}

request_error() {
  local line message='Request failed.'
  while IFS= read -r line; do
    [ "$line" ] && message=$line
  done < "$RUNTIME_DIR/error"
  printf '%s' "${message:0:500}"
}

kube_once() {
  kubectl --context "$CONTEXT" --request-timeout="${KUBE_TIMEOUT:-45s}" "$@" 2> "$RUNTIME_DIR/error"
}

kube_read() {
  local attempt output
  for attempt in 1 2 3; do
    if output=$(kube_once "$@"); then
      printf '%s\n' "$output"
      return 0
    fi
    if ((attempt < 3)); then
      warn "Kubernetes read failed; retrying ($attempt/3): $(request_error)"
      sleep "$((attempt * 2))"
    fi
  done
  return 1
}

discover_manager() {
  local managers manager previous_namespace='' previous_pod=''
  if [[ -f "$RUNTIME_DIR/manager" ]]; then
    IFS=$'\t' read -r previous_namespace previous_pod _ < "$RUNTIME_DIR/manager"
  fi

  managers=$(kube_read get pods -A -l app=longhorn-manager -o json) || return 1
  manager=$(jq -r --arg namespace "$previous_namespace" --arg pod "$previous_pod" '
    [.items[] | select(.metadata.deletionTimestamp == null and
    .status.phase == "Running" and any(.status.conditions[]?;
      .type == "Ready" and .status == "True"))] |
    sort_by((.metadata.namespace == $namespace and .metadata.name == $pod),
      .metadata.namespace, .metadata.name) | .[0] // empty |
    [.metadata.namespace, .metadata.name, .status.podIP] | @tsv' <<< "$managers")

  if [[ -z "$manager" ]]; then
    printf '%s\n' 'No ready Longhorn manager found.' > "$RUNTIME_DIR/error"
    return 1
  fi
  # persist selection because callers also run in command-substitution subshells
  printf '%s\n' "$manager" > "$RUNTIME_DIR/manager"
}

api_once() {
  local path=$1 method=${2:-GET} namespace pod host output status body message timeout=45s
  IFS=$'\t' read -r namespace pod host < "$RUNTIME_DIR/manager"
  if [[ "$host" == *:* ]]; then host="[$host]"; fi

  printf '000\n' > "$RUNTIME_DIR/http-status"
  local args=(--silent --show-error --connect-timeout 10 --max-time 25)
  if [ "$method" == POST ]; then
    args=(--silent --show-error --connect-timeout 10 --max-time 120 --request POST --data '{}')
    timeout=150s
  fi
  if ! output=$(KUBE_TIMEOUT="$timeout" kube_once -n "$namespace" exec "$pod" -c longhorn-manager -- \
    curl "${args[@]}" --header 'Content-Type: application/json' \
      --write-out $'\n%{http_code}' "http://$host:9500/v1/$path"); then
    return 1
  fi

  status=${output##*$'\n'}
    body=${output%$'\n'*}
  printf '%s\n' "$status" > "$RUNTIME_DIR/http-status"
  case "$status" in
    2[0-9][0-9]) printf '%s\n' "$body" ;;
    *)
      message=$(jq -r '.message // .detail // empty' 2> /dev/null <<< "$body") || message=''
      printf 'HTTP %s: %s\n' "$status" "${message:-Longhorn request failed.}" > "$RUNTIME_DIR/error"
      return 1
      ;;
  esac
}

api_read() {
  local path=$1 attempt output status
  for attempt in 1 2 3; do
    if output=$(api_once "$path"); then
      if jq -e 'type == "object" and .type != "error"' > /dev/null 2>&1 <<< "$output"; then
        printf '%s\n' "$output"
        return 0
      fi
      printf '%s\n' 'Invalid JSON response from Longhorn.' > "$RUNTIME_DIR/error"
    fi

    status=$(< "$RUNTIME_DIR/http-status")
    # deleted volumes and permanent client errors don't benefit from retries
    case "$status" in 400 | 401 | 403 | 404 | 405 | 422) return 1 ;; esac

    if ((attempt < 3)); then
      warn "Longhorn read failed; retrying ($attempt/3): $(request_error)"
      sleep "$((attempt * 2))"
      discover_manager || true
    fi
  done
  return 1
}

size_bytes() {
  jq -er '[.controllers[]? | select(.running == true) | .actualSize | tonumber? |
    select(. >= 0 and floor == .)] | max // empty' 2> /dev/null
}

read_size() {
  local volume=$1 current=${2:-} attempt size
  for attempt in 1 2 3 4 5; do
    if [[ -z "$current" ]]; then
      current=$(api_read "volumes/$volume") || return 1
    fi
    if size=$(size_bytes <<< "$current"); then
      printf '%s\n' "$size"
      return 0
    fi
    if ((attempt < 5)); then sleep 2; fi
    current=''
  done
  printf '%s\n' 'Allocated size remained unavailable after five observations.' > "$RUNTIME_DIR/error"
  return 1
}

has_active_mount() {
  local namespace=$1 pvc=$2 pods
  pods=$(kube_read -n "$namespace" get pods --field-selector=status.phase=Running -o json) || return 2

  jq -e --arg pvc "$pvc" "$POD_CLAIMS"'any(.items[];
    .metadata.deletionTimestamp == null and .status.phase == "Running" and
    any(mounted_claims; . == $pvc))' > /dev/null <<< "$pods"
}

trim_volume() {
  local namespace=$1 pvc=$2 volume=$3 attempt status message current result
  for attempt in 1 2 3; do
    if api_once "volumes/$volume?action=trimFilesystem" POST > /dev/null; then return 0; fi

    status=$(< "$RUNTIME_DIR/http-status")
    message=$(request_error)
    if [[ "$status" == 000 ]]; then
      printf 'Trim outcome is unknown; request was not replayed: %s\n' "$message" > "$RUNTIME_DIR/error"
      return 1
    fi

    # this explicit server error occurs before fstrim starts, so it's safe to retry
    if [[ "$status" != 500 || "$message" != *'failed to find valid mountpoint'* ]]; then return 1; fi
    result=0

    has_active_mount "$namespace" "$pvc" || result=$?
    if ((result == 1)); then
      printf '%s\n' 'No running container mounts this PVC anymore.' > "$RUNTIME_DIR/error"
      return 2
    elif ((result != 0)); then
      return 1
    fi

    current=$(api_read "volumes/$volume") || return 1
    if ! jq -e "$ELIGIBLE eligible" > /dev/null <<< "$current"; then
      printf '%s\n' 'Volume is no longer eligible for trim.' > "$RUNTIME_DIR/error"
      return 2
    fi

    if ((attempt < 3)); then
      warn "$namespace/$pvc: mountpoint not ready; retrying ($attempt/3)."
      sleep "$((attempt * 2))"
    fi
  done
  printf '%s\n' "$message" > "$RUNTIME_DIR/error"
  return 1
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
  local command invalid requested inventory label plain_label
  local namespaces namespace volumes volume pvcs pvc rows
  local current before after reduction before_gib after_gib reduction_gib result
  local pvc_count namespace_count total=0 reduced_count=0 summary_color=$YELLOW
  local trimmed_count=0 skipped_count=0 failed_count=0 unmeasured_count=0

  log 'Taking inventory of eligible PVCs...'
  for command in kubectl jq awk; do
    command -v "$command" > /dev/null  ||
      die "Required command not found: $command"
  done
  if ! CONTEXT=$(kubectl config current-context 2>&1); then die "$CONTEXT"; fi
  [[ -n "$CONTEXT" ]] || die 'No current kubectl context is set.'
  RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/trimfs.XXXXXX")

  trap cleanup EXIT
  trap 'die "Interrupted; the current trim may still be finishing on the server."' INT TERM

  requested=$(jq -cn --args '$ARGS.positional | unique' -- "$@")
  if (($# > 0)); then
    namespaces=$(kube_read get namespaces -o json) ||
      die "Unable to list namespaces: $(request_error)"
    invalid=$(jq -r --argjson requested "$requested" \
      '($requested - [.items[].metadata.name]) | join(", ")' <<< "$namespaces")
    [[ -z "$invalid" ]] || die "Invalid namespace(s): $invalid"
  fi

  discover_manager || die "Unable to discover Longhorn managers: $(request_error)"
  volumes=$(api_read volumes) || die "Unable to list Longhorn volumes: $(request_error)"
  pvcs=$(kube_read get pvc -A -o json) || die "Unable to list PVCs: $(request_error)"
  kube_read get pods -A -o json > "$RUNTIME_DIR/pods.json" || \
    die "Unable to list running workloads: $(request_error)"
  printf '%s\n' "$volumes" > "$RUNTIME_DIR/volumes.json"

  inventory=$(jq -c --argjson requested "$requested" \
    --slurpfile volumes "$RUNTIME_DIR/volumes.json" \
    --slurpfile pods "$RUNTIME_DIR/pods.json" \
    "$ELIGIBLE $POD_CLAIMS"'

    ([$pods[0].items[] | select(.metadata.deletionTimestamp == null
                                 and .status.phase == "Running") |
      .metadata.namespace as $ns | mounted_claims |
      {key: ([$ns, .] | tojson), value: true}] | from_entries) as $used |
    [$volumes[0].data[] | select(eligible)] as $volumes |
    [.items[] | select(.metadata.deletionTimestamp == null
                        and .status.phase == "Bound" and
      (.spec.volumeMode // "Filesystem") == "Filesystem") |
      . as $pvc | select(($requested | length) == 0 or
        ($requested | index($pvc.metadata.namespace)) != null) |
      select($used[[$pvc.metadata.namespace, $pvc.metadata.name] | tojson] == true) |
      $volumes[] | select(.kubernetesStatus.namespace == $pvc.metadata.namespace and
                          .kubernetesStatus.pvcName   == $pvc.metadata.name      and
                          .kubernetesStatus.pvName    == $pvc.spec.volumeName)   |
      {namespace:$pvc.metadata.namespace, pvc:$pvc.metadata.name, volume:.name}] |
    unique_by(.volume) | sort_by(.namespace, .pvc)' <<< "$pvcs")

  pvc_count=$(jq 'length' <<< "$inventory")
  namespace_count=$(jq '[.[].namespace] | unique | length' <<< "$inventory")
  log "Trimming filesystems on $pvc_count PVC(s) across $namespace_count namespace(s)..."

  rows=$(jq -r '.[] | [.namespace, .pvc, .volume] | @tsv' <<< "$inventory")
  # redirected loop, rather than pipeline, keeps summary totals in this shell
  while IFS=$'\t' read -r namespace pvc volume; do
    [[ -n "$volume" ]] || continue

    plain_label="$namespace/$pvc"
    label="${CYAN}${namespace}${RESET}/${YELLOW}${pvc}${RESET}"
    log "Trimming $label..."

    result=0
    has_active_mount "$namespace" "$pvc" || result=$?
    if ((result == 1)); then
      log "$plain_label: ${YELLOW}Skipped (no running container mounts this PVC)${RESET}"
      skipped_count=$((skipped_count + 1))
      continue
    elif ((result != 0)); then
      error "$plain_label: unable to inspect workloads: $(request_error)"
      failed_count=$((failed_count + 1))
      continue
    fi

    if ! current=$(api_read "volumes/$volume"); then
      if [[ $(< "$RUNTIME_DIR/http-status") == 404 ]]; then
        log "$plain_label: ${YELLOW}Skipped (volume no longer exists)${RESET}"
        skipped_count=$((skipped_count + 1))
      else
        error "$plain_label: unable to inspect volume: $(request_error)"
        failed_count=$((failed_count + 1))
      fi
      continue
    fi

    if ! jq -e "$ELIGIBLE eligible" > /dev/null <<< "$current"; then
      log "$plain_label: ${YELLOW}Skipped (volume is no longer eligible)${RESET}"
      skipped_count=$((skipped_count + 1))
      continue
    fi
    if ! before=$(read_size "$volume" "$current"); then
      error "$plain_label: unable to determine allocated size: $(request_error)"
      failed_count=$((failed_count + 1))
      continue
    fi

    result=0
    trim_volume "$namespace" "$pvc" "$volume" || result=$?
    if ((result == 2)); then
      log "$plain_label: ${YELLOW}Skipped ($(request_error))${RESET}"
      skipped_count=$((skipped_count + 1))
      continue
    elif ((result != 0)); then
      error "$plain_label: filesystem trim failed: $(request_error)"
      failed_count=$((failed_count + 1))
      continue
    fi
    trimmed_count=$((trimmed_count + 1))
    sleep 5 # engine allocation statistics are refreshed asynchronously after fstrim

    if ! after=$(read_size "$volume"); then
      error "$plain_label: trim completed, but size is unavailable: $(request_error)"
      unmeasured_count=$((unmeasured_count + 1))
      continue
    fi
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
      log "$plain_label: ${before_gib}Gi to ${GREEN}${after_gib}Gi${RESET} (${GREEN}${reduction_gib}Gi${RESET})"
    else
      log "$plain_label: ${after_gib}Gi ${YELLOW}(no reduction)${RESET}"
    fi
  done <<< "$rows"

  if ((total > 0)); then summary_color=$GREEN; fi
  log "Reclaimed ${summary_color}$(format_gib "$total")Gi${RESET} across $reduced_count PVC(s)."
  log "Results: $trimmed_count trimmed, $skipped_count skipped, $failed_count failed, $unmeasured_count size unavailable."
  if ((unmeasured_count > 0)); then
    warn 'Reclaimed total excludes trimmed PVCs whose size could not be measured.'
  fi
  ((failed_count == 0 && unmeasured_count == 0))
}

main "$@"
