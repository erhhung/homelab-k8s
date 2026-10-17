#!/usr/bin/env bash

# Restore the replica counts captured on 2026-10-14. drainall.sh sources the
# shared functions below; sourcing this file never changes the clusters.
#
# Usage: uncordon.sh [--plan|--check] [TARGET|CONTEXT:TARGET]
# --check is read-only; --plan prints the dependency sets without API calls.
# Bare shared targets prefer homelab; e.g. uncordon.sh policyreporter or
# uncordon.sh rancher:certmanager. Resume assumes earlier targets are complete.
# Ctrl-C during a wait offers Enter to skip that wait; a second Ctrl-C aborts.
#
# Requires Bash 3.2+, kubectl, and jq. TIMEOUT is seconds per workload (1800).
# Keep MAINTENANCE_STATE on this workstation through the host reboots.

# FUTURE WORKLOAD UPDATES (read together with drainall.sh's maintenance notes):
# - Update this restore script FIRST, while workloads are still running. The
#   INVENTORY heredoc in load_inventory() is the shared baseline for both scripts:
#   context namespace deployment/name-or-statefulset/name desired-replicas.
#   Capture .spec.replicas, not .status.readyReplicas; retain intentional zeros.
#   For each context, obtain replacement rows with this READ-ONLY pipeline:
#     kubectl --context "$context" get deployments,statefulsets -A -o json |
#       jq -r --arg c "$context" '.items[] | [$c,.metadata.namespace,
#         ((.kind|ascii_downcase)+"/"+.metadata.name),(.spec.replicas // 1)] |
#         map(tostring) | join(" ")'
#   Also inspect ownerReferences, selectors, CR specs/schemas, HPAs, CronJobs,
#   admission webhook backends, and PVC retention; rows alone are insufficient.
# - main.yml import order is the dependency source of truth. Update stage() and
#   mapped_stage() for namespace aliases, shared namespaces, and new services;
#   never infer ordering solely from namespace names. Prometheus/Thanos and
#   OTel/Tempo currently share namespaces but belong to different playbooks.
# - phase() defines dependency sets WITHIN a playbook: lower phases start first
#   and stop last. Keep operators alive until their children finish scaling down,
#   and healthy before requesting child startup. Scale mutually dependent peers
#   together, then wait for ALL their desired pods before starting the next set.
#   DNS/Istiod bootstrap early because existing DNS/mesh dependencies need them.
# - For new operator kinds, extend BOTH check_owners() and set_replicas(), plus
#   drainall.sh's preflight where needed. Inspect the actual owning CR and its
#   installed schema: replicas may be nested, component-specific, immutable, or
#   unable to reach zero. Never delete a CR to stop its pods. MinIO/Kiali use
#   explicit operator-stop exceptions; Istio waypoints use temporary CM overlays.
# - Rancher must restore completely before homelab. xdev/xtest workloads restore
#   only AFTER their parent vCluster StatefulSets are healthy. New contexts or
#   renamed vClusters require updates to context loops, read_state()'s count,
#   stage/phase mapping, Gateway handling, and drainall.sh's synced-pod checks.
# - The first drain snapshots LIVE replica targets and reversible settings into
#   STATE_FILE; uncordon restores that snapshot, not the later embedded baseline.
#   Do not replace/delete an active journal, recapture stopped workloads, or change
#   the inventory/context/checkpoint contract midway through maintenance. Restore
#   the active run first; migrate/version the journal if its structure must change.
# - Preserve full readiness waits, per-workload timeouts, original node cordon
#   state, and restoration of HPA/CronJob/webhook/Gateway settings. Vault's chart
#   permits sealed Ready pods, so vault_unsealed() is an additional health gate.
#   Launch unseal.sh automatically in a supervised background subshell after pod
#   readiness; keep its expected sealed exit status out of the error/retry path.
# - Discover ALL live HPAs in each phase's contexts (including ones created after
#   the drain snapshot). Before restoring an HPA target, undo its saved maintenance
#   pin, use minReplicas (default 1), and scale only if BELOW that minimum. Wait
#   for >= minimum Ready/live pods; HPA-driven extra or terminating pods must not
#   prevent progress. Fixed-size workloads still require exact captured counts,
#   and shutdown still requires zero pods. Never rewrite captured replica targets.
# - Use log()/resource_log() for progress, including wait heartbeats: LOCAL time
#   [%Y-%m-%d %I:%M:%S %p] in ESC[1;37m, namespace in ESC[1;36m, type/name in
#   ESC[1;33m, target in ESC[1;35m; context immediately follows the timestamp.
#   Reset all surrounding text to normal. Keep Bash 3.2 support.
# - All kubectl calls, including the unseal helper, use three attempts with a
#   five-second delay. Buffer stdout and replay stdin: a failed apply/exec must
#   not lose its input or mix partial JSON with the next attempt's output.
# - Resume filtering must use saved workload ranks/phases, prefer homelab for a
#   shared bare name, and skip earlier clusters as well as earlier phase groups.
#   Keep version-1 journals readable; do not recapture replicas on a retry.
# - Waiting bodies only observe resources. Run them in separate process groups
#   so Ctrl-C can stop/skip the current wait without leaving kubectl children.
#   Record skipped checks and never report them as confirmed healthy replicas.
# - Validate updates with --plan on both scripts, drainall.sh --check while all
#   contexts are reachable, bash -n, ShellCheck, and mocked shutdown/restore with
#   interruption/resume. Ordinary runs mutate live clusters; they are not tests.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname -- "$SCRIPT_DIR")"
STATE_FILE="${MAINTENANCE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/homelab/drainall.json}"
TIMEOUT="${TIMEOUT:-1800}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
WHITE=$'\033[1;37m'
CYAN=$'\033[1;36m'
YELLOW=$'\033[1;33m'
PINK=$'\033[1;35m'
RESET=$'\033[0m'
THUMBUP=$'\360\237\221\215' # UTF-8 thumbs-up; Bash 3.2 does not support \U.
WAIT_PID=''
WAIT_SKIPPED=false
WAIT_PROMPT=false
WAIT_INTERRUPTED=false
UNSEAL_PID=''
UNSEAL_DIR=''
RUNTIME_DIR=''
TTY_SETTINGS=''
SKIPPED_WAIT_COUNT=0
RESUME_TARGET=''
RESUME_CLUSTER=''
RESUME_STAGE=''
RESUME_REACHED=true
RESTORE_HPAS='{}'

log() {
  printf '%s[%s]%s %s\n' "$WHITE" "$(LC_TIME=C date '+%Y-%m-%d %I:%M:%S %p')" "$RESET" "$*"
}

resource_log() {
  local action=$1 context=$2 namespace=$3 resource=$4 message=$5
  context_log "$context" "$action ${CYAN}${namespace}${RESET}:${YELLOW}${resource}${RESET}$message"
}

context_log() { local context=$1; shift; log "$context: $*"; }

phase_log() {
  context_log "$2" "Scaling $1 ${PINK}$3${RESET} (phase $4)..."
}

die() { log "ERROR: $*" >&2; exit 1; }

kube() {
  local context=$1
  shift
  kubectl_retry --context "$context" --request-timeout=30s "$@"
}

kubectl_retry() {
  local context='' previous='' argument input='' replay=false attempt status output error_file diagnostic
  for argument in "$@"; do
    [[ "$previous" != --context ]] || context=$argument
    case "$argument" in
      -i|--stdin|--filename=-|-f-) replay=true ;;
      -) [[ "$previous" != -f && "$previous" != --filename ]] || replay=true ;;
    esac
    previous=$argument
  done
  [[ -n "$context" ]] || die 'kubectl requires an explicit context.'
  if [[ "$replay" == true ]]; then input=$(< /dev/stdin); fi
  error_file=$(mktemp "${RUNTIME_DIR:-${TMPDIR:-/tmp}}/kubectl-error.XXXXXX")
  for attempt in 1 2 3; do
    if [[ "$replay" == true ]]; then
      if output=$(command kubectl "$@" 2>"$error_file" <<< "$input"); then status=0; else status=$?; fi
    else
      if output=$(command kubectl "$@" </dev/null 2>"$error_file"); then status=0; else status=$?; fi
    fi
    if (( status == 0 )); then
      rm -f -- "$error_file"
      [[ -z "$output" ]] || printf '%s\n' "$output"
      return 0
    fi
    diagnostic=$(< "$error_file")
    if (( status == 130 || status == 143 )); then rm -f -- "$error_file"; return "$status"; fi
    while IFS= read -r diagnostic; do
      [[ -z "$diagnostic" ]] || context_log "$context" "kubectl attempt $attempt/3: $diagnostic" >&2
    done <<< "$diagnostic"
    if (( attempt < 3 )); then
      context_log "$context" 'Retrying kubectl in 5 seconds...' >&2
      sleep 5
    fi
  done
  rm -f -- "$error_file"
  return "$status"
}

stop_process_group() {
  local pid=${1:-}
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  # Only observation/unseal workers get their own groups; never signal the
  # caller's foreground group or a VM/node process.
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

maintenance_cleanup() {
  restore_tty
  stop_process_group "$WAIT_PID"
  stop_process_group "$UNSEAL_PID"
  [[ -z "$UNSEAL_DIR" ]] || rm -rf -- "$UNSEAL_DIR"
  [[ -z "$RUNTIME_DIR" ]] || rm -rf -- "$RUNTIME_DIR"
}

restore_tty() {
  if [[ -n "$TTY_SETTINGS" ]]; then
    stty "$TTY_SETTINGS" < /dev/tty 2>/dev/null || true
    TTY_SETTINGS=''
  fi
}

abort_maintenance() {
  log "Interrupted; maintenance state is at $STATE_FILE. Rerun either script to resume." >&2
  exit 130
}

handle_interrupt() {
  if [[ -z "$WAIT_PID" || "$WAIT_PROMPT" == true ]]; then abort_maintenance; fi
  WAIT_INTERRUPTED=true
  kill -STOP -- "-$WAIT_PID" 2>/dev/null || true
}

prompt_wait_skip() {
  local answer
  # Prompt after returning from the signal trap. Bash defers another SIGINT
  # while an INT trap is running, so reading inside it would swallow Ctrl-C #2.
  WAIT_PROMPT=true
  if ! TTY_SETTINGS=$(stty -g < /dev/tty 2>/dev/null); then abort_maintenance; fi
  # Read Ctrl-C as a character here. This avoids Bash 3.2's signal/read races
  # when a second interrupt arrives immediately after the prompt is printed.
  stty -echo -icanon -isig min 1 time 0 < /dev/tty
  log 'Press Enter to skip the current step or Ctrl-C again to abort the script.' > /dev/tty
  while :; do
    if IFS= read -r -n 1 answer < /dev/tty; then
      case "$answer" in
        $'\003') restore_tty; abort_maintenance ;;
        ''|$'\r')
          restore_tty
          stop_process_group "$WAIT_PID"
          WAIT_SKIPPED=true
          WAIT_PROMPT=false
          return 0 ;;
      esac
    else
      abort_maintenance
    fi
  done
}

install_handlers() {
  RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/homelab-maintenance.XXXXXX")
  trap maintenance_cleanup EXIT
  trap handle_interrupt INT
  trap abort_maintenance TERM
}

waiting_step() {
  local context=$1 description=$2 pid status monitor=false
  shift 2
  WAIT_SKIPPED=false
  WAIT_INTERRUPTED=false
  [[ "$-" != *m* ]] || monitor=true
  set -m
  ( trap - INT TERM EXIT; trap '' INT; "$@" ) </dev/null &
  WAIT_PID=$!
  pid=$WAIT_PID
  [[ "$monitor" == true ]] || set +m
  if wait "$pid" 2>/dev/null; then status=0; else status=$?; fi
  if [[ "$WAIT_INTERRUPTED" == true ]]; then prompt_wait_skip; fi
  WAIT_PID=''
  if [[ "$WAIT_SKIPPED" == true ]]; then
    SKIPPED_WAIT_COUNT=$((SKIPPED_WAIT_COUNT + 1))
    context_log "$context" "Skipped waiting step: $description."
    if [[ -n "${STATE:-}" ]]; then
      STATE=$(jq --arg c "$context" --arg step "$description" \
        '.skippedWaits = ((.skippedWaits // []) + [{context:$c,step:$step}])' <<< "$STATE")
      save_state
    fi
    return 0
  fi
  return "$status"
}

parse_arguments() {
  MODE=run
  RESUME_TARGET=''
  while (( $# > 0 )); do
    case "$1" in
      --plan|--check)
        [[ "$MODE" == run ]] || die 'Choose only one of --plan and --check.'
        MODE=${1#--} ;;
      -*) die "Unknown option: $1. Usage: ${0##*/} [--plan|--check] [TARGET|CONTEXT:TARGET]" ;;
      *) [[ -z "$RESUME_TARGET" ]] || die 'Only one resume target is allowed.'; RESUME_TARGET=$1 ;;
    esac
    shift
  done
  resolve_resume_target
}

resolve_resume_target() {
  local matches
  RESUME_CLUSTER=''
  RESUME_STAGE=''
  RESUME_REACHED=true
  [[ -n "$RESUME_TARGET" ]] || return 0
  RESUME_STAGE=${RESUME_TARGET#*:}
  if [[ "$RESUME_TARGET" == *:* ]]; then
    RESUME_CLUSTER=${RESUME_TARGET%%:*}
    [[ "$RESUME_CLUSTER" == homelab || "$RESUME_CLUSTER" == rancher ]] || die 'Resume context must be homelab or rancher.'
  fi
  matches=$(jq -r --arg stage "$RESUME_STAGE" '[.[] | select(.stage == $stage) |
    if .context == "rancher" then "rancher" else "homelab" end] | unique[]' <<< "$WORKLOADS")
  if [[ -z "$RESUME_CLUSTER" ]]; then
    if [[ "$matches" == *homelab* ]]; then RESUME_CLUSTER=homelab; else RESUME_CLUSTER=rancher; fi
  fi
  [[ "$matches" == *"$RESUME_CLUSTER"* ]] || die "Invalid resume target: $RESUME_TARGET. Valid targets: $(jq -r '[.[].stage]|unique|join(", ")' <<< "$WORKLOADS")"
  RESUME_REACHED=false
}

cluster_selected() {
  [[ -z "$RESUME_CLUSTER" || "$1" == "$RESUME_CLUSTER" ]] ||
    [[ "$2" == up && "$RESUME_CLUSTER" == rancher && "$1" == homelab ]] ||
    [[ "$2" == down && "$RESUME_CLUSTER" == homelab && "$1" == rancher ]]
}

group_selected() {
  [[ "$RESUME_REACHED" == false ]] || return 0
  [[ "$1" == "$RESUME_CLUSTER" && "$2" == "$RESUME_STAGE" ]] || return 1
  RESUME_REACHED=true
}

load_inventory() {
  # Updating rows is only part of a refresh: review the namespace-to-playbook
  # and within-playbook mappings below, plus every operator handler downstream.
  # The import parser currently expects alphabetic playbook filenames in main.yml.
  local order='_system' line playbook
  while IFS= read -r line; do
    if [[ "$line" =~ ansible\.builtin\.import_playbook:\ playbooks/([a-z]+)\.yml ]]; then
      playbook=${BASH_REMATCH[1]}
      order="$order $playbook"
    fi
  done < "$PROJECT_DIR/main.yml"

  WORKLOADS=$(jq -Rn --arg order "$order" '
    def stage:
      if .context == "xdev" or .context == "xtest" then "vclusters"
      elif .namespace == "kube-system" or .resource == "deployment/istiod" then "_system"
      elif (.namespace | startswith("cattle-")) then
        if .context == "rancher" then "rancher" else "cluster" end
      elif .namespace == "monitoring" then
        if (.resource | test("/thanos-")) then "thanos" else "monitoring" end
      elif .namespace == "observability" and .resource == "statefulset/tempo" then "tempo"
      elif .namespace == "otel-operator" then "observability"
      elif .namespace == "kiali-operator" or .namespace == "istio-system" then "istio"
      elif .namespace == "minio-operator" then "minio"
      elif .namespace == "nfd-system" or .namespace == "intel-system" then "nodefeatures"
      else .namespace end;
    def mapped_stage:
      if .namespace == "longhorn-system" or .namespace == "mount-s3-system" or .namespace == "nfs-provisioner" then "storage"
      elif .namespace == "cert-manager" then "certmanager"
      elif .namespace == "external-dns" then "externaldns"
      elif .namespace == "external-secrets" then "externalsecrets"
      elif .namespace == "metallb-system" then "metallb"
      elif .namespace == "trivy-system" then "trivy"
      elif .namespace == "policy-reporter" then "policyreporter"
      elif .namespace == "open-webui" then "openwebui"
      elif .namespace == "vcluster-platform" or (.namespace | startswith("vcluster-")) then "vclusters"
      elif .namespace == "xen-exporter" then "monitoring"
      else stage end;
    def phase:
      if .context == "xdev" or .context == "xtest" then
        if .namespace == "kube-system" then 2 elif .namespace == "postgresql" then 3 else 4 end
      elif .stage == "_system" then
        if (.resource | test("/.*coredns$")) then 0 elif .resource == "deployment/istiod" then 2 else 1 end
      elif .stage == "vclusters" then if .namespace == "vcluster-platform" then 0 else 1 end
      elif .stage == "storage" then if .resource == "deployment/longhorn-driver-deployer" then 2 else 1 end
      elif .stage == "postgresql" then if (.resource | startswith("statefulset/")) then 0 else 1 end
      elif .stage == "gitlab" then if (.resource | startswith("statefulset/")) then 0 else 1 end
      elif (.resource | test("/minio-operator$|/awx-operator-controller-manager$|/prometheus-stack-operator$|/otel-operator$|/kiali-operator$|/rancher-turtles-controller-manager$")) then 0
      else 1 end;
    [inputs | split(" ") | map(select(length > 0)) |
      {context:.[0],namespace:.[1],resource:.[2],replicas:(.[3]|tonumber)} |
      .stage = mapped_stage | .phase = phase]' <<'INVENTORY'
rancher kube-system deployment/coredns 1
rancher kube-system deployment/local-path-provisioner 1
rancher kube-system deployment/metrics-server 1
rancher kube-system deployment/traefik 1
rancher cattle-capi-system deployment/capi-controller-manager 1
rancher cattle-fleet-local-system deployment/fleet-agent 1
rancher cattle-fleet-system deployment/fleet-controller 1
rancher cattle-fleet-system deployment/gitjob 1
rancher cattle-fleet-system deployment/helmops 1
rancher cattle-system deployment/rancher 1
rancher cattle-system deployment/rancher-webhook 1
rancher cattle-system deployment/system-upgrade-controller 1
rancher cattle-turtles-system deployment/rancher-turtles-controller-manager 1
rancher cert-manager deployment/cert-manager 1
rancher cert-manager deployment/cert-manager-cainjector 1
rancher cert-manager deployment/cert-manager-webhook 1
rancher cert-manager deployment/step-issuer 1
rancher external-dns deployment/external-dns 1
rancher harbor deployment/harbor-core 1
rancher harbor deployment/harbor-exporter 1
rancher harbor deployment/harbor-jobservice 1
rancher harbor deployment/harbor-portal 1
rancher harbor deployment/harbor-registry 1
rancher harbor statefulset/harbor-database 1
rancher harbor statefulset/harbor-redis 1
rancher harbor statefulset/harbor-trivy 1
rancher intel-system deployment/inteldeviceplugins-controller-manager 1
rancher kyverno deployment/kyverno-admission-controller 1
rancher kyverno deployment/kyverno-background-controller 1
rancher kyverno deployment/kyverno-cleanup-controller 1
rancher kyverno deployment/kyverno-reports-controller 1
rancher nfd-system deployment/nfd-gc 1
rancher nfd-system deployment/nfd-master 1
rancher nfs-provisioner deployment/qnap-nfs-subdir-external-provisioner 1
rancher policy-reporter deployment/policy-reporter 1
rancher policy-reporter deployment/policy-reporter-kyverno-plugin 1
rancher policy-reporter deployment/policy-reporter-trivy-plugin 1
rancher trivy-system deployment/trivy-operator 1
rancher trivy-system deployment/trivy-operator-polr-adapter 1
rancher trivy-system deployment/trivy-redis-master 1
rancher trivy-system statefulset/trivy-server 1
homelab argocd deployment/argocd-applicationset-controller 1
homelab argocd deployment/argocd-commit-server 1
homelab argocd deployment/argocd-notifications-controller 1
homelab argocd deployment/argocd-repo-server 1
homelab argocd deployment/argocd-server 1
homelab argocd statefulset/argocd-application-controller 1
homelab awx deployment/awx-operator-controller-manager 1
homelab awx deployment/awx-task 1
homelab awx deployment/awx-web 1
homelab bentopdf deployment/bentopdf 1
homelab buildbuddy deployment/buildbuddy 1
homelab buildfarm deployment/buildfarm-exec-worker 2
homelab buildfarm deployment/buildfarm-server 1
homelab buildfarm statefulset/buildfarm-shard-worker 1
homelab buildkite deployment/agent-stack-k8s 1
homelab cattle-fleet-system deployment/fleet-agent 1
homelab cattle-system deployment/cattle-cluster-agent 2
homelab cattle-system deployment/rancher-webhook 1
homelab cattle-system deployment/system-upgrade-controller 1
homelab cert-manager deployment/cert-manager 1
homelab cert-manager deployment/cert-manager-cainjector 1
homelab cert-manager deployment/cert-manager-webhook 1
homelab cert-manager deployment/step-issuer 1
homelab external-dns deployment/external-dns 1
homelab external-secrets deployment/external-secrets 1
homelab external-secrets deployment/external-secrets-cert-controller 1
homelab external-secrets deployment/external-secrets-webhook 1
homelab flowise deployment/flowise 1
homelab flowise deployment/flowise-worker 1
homelab flowise statefulset/flowise-redis-master 1
homelab gitea deployment/gitea 1
homelab gitea statefulset/actions-runner 1
homelab gitlab deployment/gitlab-gitlab-exporter 1
homelab gitlab deployment/gitlab-gitlab-pages 1
homelab gitlab deployment/gitlab-gitlab-runner 1
homelab gitlab deployment/gitlab-gitlab-shell 1
homelab gitlab deployment/gitlab-pipelines-exporter 1
homelab gitlab deployment/gitlab-sidekiq-default-v2 2
homelab gitlab deployment/gitlab-toolbox 1
homelab gitlab deployment/gitlab-webservice-default 1
homelab gitlab statefulset/gitlab-gitaly-default 2
homelab gitlab statefulset/gitlab-praefect 1
homelab gitlab statefulset/gitlab-redis-master 1
homelab intel-system deployment/inteldeviceplugins-controller-manager 1
homelab istio-system deployment/istiod 1
homelab istio-system deployment/kiali 1
homelab jenkins statefulset/jenkins 1
homelab keycloak statefulset/keycloakx 1
homelab kiali-operator deployment/kiali-operator 1
homelab kube-system deployment/rke2-coredns-rke2-coredns 3
homelab kube-system deployment/rke2-coredns-rke2-coredns-autoscaler 1
homelab kube-system deployment/rke2-metrics-server 1
homelab kube-system deployment/rke2-snapshot-controller 1
homelab kyverno deployment/kyverno-admission-controller 2
homelab kyverno deployment/kyverno-background-controller 1
homelab kyverno deployment/kyverno-cleanup-controller 1
homelab kyverno deployment/kyverno-reports-controller 1
homelab litellm deployment/litellm 1
homelab litellm deployment/litellm-waypoint 1
homelab logging deployment/fluent-operator 1
homelab longhorn-system deployment/csi-attacher 2
homelab longhorn-system deployment/csi-provisioner 2
homelab longhorn-system deployment/csi-resizer 2
homelab longhorn-system deployment/csi-snapshotter 2
homelab longhorn-system deployment/longhorn-driver-deployer 1
homelab longhorn-system deployment/longhorn-ui 1
homelab mailpit deployment/mailpit 1
homelab metacontroller statefulset/metacontroller 1
homelab metallb-system deployment/metallb-controller 1
homelab minio-operator deployment/minio-operator 1
homelab minio statefulset/homelab-qnap-pool 4
homelab monitoring deployment/prometheus-stack-kube-state-metrics 1
homelab monitoring deployment/prometheus-stack-operator 1
homelab monitoring deployment/thanos-bucketweb 1
homelab monitoring deployment/thanos-compactor 1
homelab monitoring deployment/thanos-query 1
homelab monitoring deployment/thanos-query-frontend 1
homelab monitoring statefulset/alertmanager-prometheus-stack-alertmanager 1
homelab monitoring statefulset/prometheus-prometheus-stack-prometheus 1
homelab monitoring statefulset/prometheus-stack-grafana 1
homelab monitoring statefulset/thanos-ruler 1
homelab monitoring statefulset/thanos-storegateway 1
homelab mount-s3-system deployment/s3-csi-controller 1
homelab nfd-system deployment/nfd-gc 1
homelab nfd-system deployment/nfd-master 1
homelab nfs-provisioner deployment/qnap-nfs-subdir-external-provisioner 1
homelab observability deployment/otel-gateway-collector 1
homelab observability statefulset/tempo 1
homelab ollama deployment/ollama 1
homelab open-webui deployment/mcpo 1
homelab open-webui deployment/open-webui 1
homelab open-webui deployment/open-webui-pipelines 1
homelab open-webui deployment/open-webui-tika 1
homelab openclaw deployment/openclaw 1
homelab opencode statefulset/opencode-dev-container 1
homelab opensearch deployment/opensearch-dashboards 1
homelab opensearch statefulset/opensearch-master 3
homelab otel-operator deployment/otel-operator 1
homelab pgadmin deployment/pgadmin4 1
homelab playwright deployment/playwright 1
homelab policy-reporter deployment/policy-reporter 1
homelab policy-reporter deployment/policy-reporter-kyverno-plugin 1
homelab policy-reporter deployment/policy-reporter-redis-master 1
homelab policy-reporter deployment/policy-reporter-trivy-plugin 1
homelab policy-reporter deployment/policy-reporter-ui 1
homelab postgresql deployment/postgresql-pgpool 2
homelab postgresql statefulset/postgresql-postgresql 3
homelab pyrra deployment/pyrra 1
homelab qdrant statefulset/qdrant 3
homelab searxng deployment/searxng 1
homelab searxng deployment/searxng-waypoint 1
homelab trivy-system deployment/trivy-operator 1
homelab trivy-system deployment/trivy-operator-polr-adapter 1
homelab trivy-system deployment/trivy-redis-master 1
homelab trivy-system statefulset/trivy-server 1
homelab valkey statefulset/valkey 6
homelab vault statefulset/vault 3
homelab vcluster-platform deployment/loft 1
homelab vcluster-dev statefulset/dev 1
homelab vcluster-test statefulset/test 1
homelab velero deployment/velero 1
homelab velero deployment/velero-ui 1
homelab wave deployment/wave-wave 2
homelab xen-exporter deployment/xen-exporter 1
xdev kube-system deployment/coredns 1
xdev postgresql statefulset/postgresql 1
xdev workouts-explorer deployment/workouts-explorer-api 1
xdev workouts-explorer deployment/workouts-explorer-coverage-worker 1
xdev workouts-explorer deployment/workouts-explorer-tiles 1
xdev workouts-explorer deployment/workouts-explorer-ui 1
xdev workouts-explorer deployment/workouts-explorer-worker 1
xtest kube-system deployment/coredns 1
INVENTORY
  )
  # Rank lookup keeps shared namespaces (Thanos/Prometheus, Tempo/OTel) in
  # their actual playbook order. DNS and Istiod bootstrap before dependents.
  WORKLOADS=$(jq --arg order "$order" '
    ($order | split(" ")) as $order |
    map(.stage as $stage | .rank = ($order | index($stage)) |
      if .rank == null then error("Unmapped playbook: " + $stage) else . end)
  ' <<< "$WORKLOADS")
}

initialize() {
  local command
  for command in kubectl jq; do
    command -v "$command" >/dev/null || die "Required command not found: $command"
  done
  [[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die 'TIMEOUT must be positive integer seconds.'
  [[ "$POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die 'POLL_INTERVAL must be positive integer seconds.'
  load_inventory
}

print_plan() {
  local direction=$1 rows context stage phase namespace resource replicas action cluster
  rows=$(jq -r --arg direction "$direction" '
    sort_by((if .context == "rancher" then 0 else 1 end), .rank, .phase, .context, .namespace, .resource) |
    if $direction == "down" then reverse else . end | .[] |
    [.context,.stage,(.phase|tostring),.namespace,.resource,
      (if $direction == "down" then "0" else (.replicas|tostring) end)] | @tsv
  ' <<< "$WORKLOADS")
  log 'Dependency plan (read-only). MinIO/Kiali shutdown stops their operators before their generated workloads.'
  if [[ "$direction" == down ]]; then action='Plan: scale down'; else action='Plan: restore'; fi
  while IFS=$'\t' read -r context stage phase namespace resource replicas; do
    if [[ "$context" == rancher ]]; then cluster=rancher; else cluster=homelab; fi
    group_selected "$cluster" "$stage" || continue
    resource_log "$action" "$context" "$namespace" "$resource" " to $replicas replicas (${PINK}${stage}${RESET}, phase $phase)."
  done <<< "$rows"
}

read_state() {
  [[ -f "$STATE_FILE" ]] || die "Maintenance state missing: $STATE_FILE; run drainall.sh first."
  STATE=$(< "$STATE_FILE")
  jq -e '.version == 1 and (.workloads | length > 0) and (.contexts | length == 4)' \
    >/dev/null <<< "$STATE" || die "Invalid maintenance state: $STATE_FILE"
  WORKLOADS=$(jq '.workloads' <<< "$STATE")
}

save_state() {
  local parent temporary
  parent=$(dirname -- "$STATE_FILE")
  mkdir -p -- "$parent"
  temporary=$(mktemp "$parent/.drainall.XXXXXX")
  printf '%s\n' "$STATE" > "$temporary"
  chmod 600 "$temporary"
  mv -f -- "$temporary" "$STATE_FILE"
}

check_workloads() {
  local context=$1 live expected unknown missing unsafe
  context_log "$context" 'Checking inventory and PVC retention...'
  live=$(kube "$context" get deployments,statefulsets -A -o json | jq -c '{items:[.items[] |
    {kind,metadata:{namespace:.metadata.namespace,name:.metadata.name,ownerReferences:.metadata.ownerReferences},
     spec:{replicas:.spec.replicas,persistentVolumeClaimRetentionPolicy:.spec.persistentVolumeClaimRetentionPolicy,
       volumeClaimTemplates:[.spec.volumeClaimTemplates[]? | {metadata:{name:.metadata.name}}]}}]}')
  expected=$(jq --arg c "$context" '[.[] | select(.context == $c) | .namespace+":"+.resource]' <<< "$WORKLOADS")
  unknown=$(jq -r --argjson expected "$expected" '.items[] |
    (.metadata.namespace+":"+(.kind|ascii_downcase)+"/"+.metadata.name) as $key |
    select($expected | index($key) | not) | $key' <<< "$live")
  missing=$(jq -nr --argjson live "$live" --argjson expected "$expected" '
    [$live.items[] | .metadata.namespace+":"+(.kind|ascii_downcase)+"/"+.metadata.name] as $keys |
    $expected[] | . as $key | select($keys | index($key) | not)')
  [[ -z "$unknown" ]] || die "Uncaptured workloads in $context (update restore inventory): $unknown"
  [[ -z "$missing" ]] || die "Captured workloads missing in $context: $missing"
  # Omitted whenScaled defaults to Retain. PV reclaimPolicy is unrelated:
  # scale-to-zero must never delete the PVC, even if its PV uses Delete.
  unsafe=$(jq -r '.items[] | select(.kind == "StatefulSet") |
    select((.spec.persistentVolumeClaimRetentionPolicy.whenScaled // "Retain") != "Retain") |
    .metadata.namespace+":statefulset/"+.metadata.name' <<< "$live")
  [[ -z "$unsafe" ]] || die "whenScaled must be Retain in $context: $unsafe"
  LIVE_WORKLOADS=$live
}

check_owners() {
  local context=$1 unsafe
  unsafe=$(jq -r '.items[] | . as $w | .metadata.ownerReferences[]? |
    select(.controller != false) | . as $owner |
    select((["Prometheus","Alertmanager","AWX","OpenTelemetryCollector","Tenant","Kiali","Gateway","CAPIProvider"] | index($owner.kind)) == null) |
    $w.metadata.namespace+":"+($w.kind|ascii_downcase)+"/"+$w.metadata.name+" owned by "+.kind+"/"+.name' <<< "$LIVE_WORKLOADS")
  [[ -z "$unsafe" ]] || die "Unsupported operator owner in $context: $unsafe"
}

selector_for() {
  jq -r '.spec.selector |
    [(.matchLabels // {} | to_entries[] | .key+"="+.value),
     (.matchExpressions // [] | .[] |
       if .operator == "In" then .key+" in ("+(.values|join(","))+")"
       elif .operator == "NotIn" then .key+" notin ("+(.values|join(","))+")"
       elif .operator == "Exists" then .key
       elif .operator == "DoesNotExist" then "!"+.key
       else error("Unknown selector operator") end)] | join(",")'
}

refresh_restore_hpas() {
  local context=$1 live saved='[]'
  live=$(kube "$context" get hpa -A -o json | jq -c '[.items[] |
    {namespace:.metadata.namespace,resource:("hpa/"+.metadata.name),
     target:((.spec.scaleTargetRef.kind|ascii_downcase)+"/"+.spec.scaleTargetRef.name),
     minReplicas:(.spec.minReplicas // 1),maxReplicas:.spec.maxReplicas}]')
  if [[ -n "${STATE:-}" ]]; then saved=$(jq -c --arg c "$context" '.contexts[$c].hpas // []' <<< "$STATE"); fi
  live=$(jq -c --argjson saved "$saved" 'map(. as $live |
    ([$saved[] | select(.namespace==$live.namespace and .resource==$live.resource and .target==$live.target)][0] // $live) as $original |
    .restoreLimits=(.minReplicas!=$original.minReplicas or .maxReplicas!=$original.maxReplicas) |
    .minReplicas=$original.minReplicas | .maxReplicas=$original.maxReplicas)' <<< "$live")
  RESTORE_HPAS=$(jq -c --arg c "$context" --argjson live "$live" '.[$c]=$live' <<< "$RESTORE_HPAS")
}

prepare_restore_group() {
  local group=$1 context rows row namespace resource patch
  while IFS= read -r context; do refresh_restore_hpas "$context"; done < <(jq -r '[.[].context]|unique[]' <<< "$group")
  RESTORE_GROUP=$(jq -c --argjson hpas "$RESTORE_HPAS" 'map(. as $w |
    ([$hpas[$w.context][]? | select(.namespace==$w.namespace and .target==$w.resource)][0] // null) as $hpa |
    if $hpa == null then .readiness="exact"
    else .replicas=$hpa.minReplicas | .readiness="minimum" end)' <<< "$group")
  # Old journals may have min=max=captured replicas. Restore the original HPA
  # limits BEFORE waking its target, otherwise that pin would force it back up.
  rows=$(jq -c --argjson group "$group" 'to_entries[] | .key as $c | .value[] |
    select(.restoreLimits) |
    . as $hpa | select(any($group[]; .context==$c and .namespace==$hpa.namespace and .resource==$hpa.target)) |
    .context=$c' <<< "$RESTORE_HPAS")
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    context=$(jq -r '.context' <<< "$row")
    namespace=$(jq -r '.namespace' <<< "$row")
    resource=$(jq -r '.resource' <<< "$row")
    patch=$(jq -c '{spec:{minReplicas:.minReplicas,maxReplicas:.maxReplicas}}' <<< "$row")
    resource_log 'Restoring' "$context" "$namespace" "$resource" ' autoscaling limits before workload startup...'
    kube "$context" -n "$namespace" patch "$resource" --type=merge -p "$patch" >/dev/null
  done <<< "$rows"
}

vault_unsealed() {
  local context=$1 namespace=$2 resource=$3 desired=$4 index result
  for ((index=0; index<desired; index++)); do
    # Exit 2 is a valid sealed status, not a transport failure to retry. Translate
    # it inside the pod so kubectl does not print "command terminated ... 2".
    # shellcheck disable=SC2016 # Expanded by sh inside the Vault container.
    if ! result=$(kube "$context" -n "$namespace" exec "${resource#*/}-$index" -c vault -- sh -c \
      'vault status -format=json; code=$?; [ "$code" -eq 0 ] || [ "$code" -eq 2 ]'); then
      return 1
    fi
    jq -e '.initialized == true and .sealed == false' >/dev/null <<< "$result" || return 1
  done
}

start_vault_unseal() {
  local context=$1 namespace=$2 resource=$3 desired=$4 monitor=false
  [[ -f "$SCRIPT_DIR/unseal.sh" ]] || die "Unseal helper missing: $SCRIPT_DIR/unseal.sh"
  UNSEAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/homelab-unseal.XXXXXX")
  context_log homelab 'Starting scripts/unseal.sh in the background...'
  [[ "$-" != *m* ]] || monitor=true
  set -m
  (
    trap - INT TERM EXIT
    set +e
    if vault_unsealed "$context" "$namespace" "$resource" "$desired"; then
      printf '0\n' > "$UNSEAL_DIR/result"
      exit 0
    fi
    (
      # Source only in this isolated child: preserve the helper's key handling,
      # supply retries without modifying it, and prevent an interactive stdin.
      set +u
      set --
      # shellcheck disable=SC2329 # Invoked indirectly by the sourced helper.
      kubectl() { kubectl_retry --request-timeout=30s "$@"; }
      # shellcheck source=/dev/null
      source "$SCRIPT_DIR/unseal.sh"
    )
    code=$?
    printf '%s\n' "$code" > "$UNSEAL_DIR/result"
    exit "$code"
  ) </dev/null >"$UNSEAL_DIR/output" 2>&1 &
  UNSEAL_PID=$!
  [[ "$monitor" == true ]] || set +m
}

show_unseal_output() {
  local line ansi=$'\033\\[[0-9;]*[[:alpha:]]'
  [[ -f "$UNSEAL_DIR/output" ]] || return 0
  while IFS= read -r line; do
    while [[ "$line" =~ $ansi ]]; do line=${line/"${BASH_REMATCH[0]}"/}; done
    [[ -z "$line" ]] || context_log homelab "unseal.sh: $line"
  done < "$UNSEAL_DIR/output"
}

wait_vault_body() {
  local context=$1 namespace=$2 resource=$3 desired=$4 started=$SECONDS reported=$SECONDS code
  while ! vault_unsealed "$context" "$namespace" "$resource" "$desired"; do
    if [[ -f "$UNSEAL_DIR/result" ]]; then
      code=$(< "$UNSEAL_DIR/result")
      if [[ "$code" != 0 ]]; then
        show_unseal_output >&2
        die "Automatic Vault unsealing failed (exit $code). Check the helper's PKI/YubiKey access and rerun."
      fi
    fi
    (( SECONDS - started < TIMEOUT )) || { show_unseal_output >&2; die "Vault is still sealed after ${TIMEOUT}s."; }
    if (( SECONDS - reported >= 60 )); then
      resource_log 'Still waiting for' "$context" "$namespace" "$resource" ' to be unsealed...'
      reported=$SECONDS
    fi
    sleep "$POLL_INTERVAL"
  done
}

wait_workload_body() {
  local context=$1 namespace=$2 resource=$3 desired=$4 mode=${5:-exact} started=$SECONDS reported=$SECONDS workload selector pods count ready
  workload=$(kube "$context" -n "$namespace" get "$resource" -o json)
  selector=$(selector_for <<< "$workload")
  [[ -n "$selector" ]] || die "Empty pod selector: $context/$namespace/$resource"
  while :; do
    workload=$(kube "$context" -n "$namespace" get "$resource" -o json)
    pods=$(kube "$context" -n "$namespace" get pods -l "$selector" -o json | jq -c '{items:[.items[] |
      {metadata:{deletionTimestamp:.metadata.deletionTimestamp},status:{phase:.status.phase,conditions:.status.conditions}}]}')
    if jq -e --argjson n "$desired" --argjson pods "$pods" --arg mode "$mode" '
      (.status.observedGeneration // 0) >= .metadata.generation and
      (if $mode == "minimum" then
         .spec.replicas >= $n and (.status.readyReplicas // 0) >= $n and
         ([$pods.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running" and
           any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length) >= $n
       elif $n == 0 then .spec.replicas == 0 and ($pods.items | length) == 0 and (.status.replicas // 0) == 0
       else .spec.replicas == $n and (.status.replicas // 0) == $n and (.status.readyReplicas // 0) == $n and
         ($pods.items | length) == $n and
         all($pods.items[]; .metadata.deletionTimestamp == null and .status.phase == "Running" and
           any(.status.conditions[]?; .type == "Ready" and .status == "True")) end)
    ' >/dev/null <<< "$workload"; then
      return 0
    fi
    if (( SECONDS - started >= TIMEOUT )); then
      kube "$context" -n "$namespace" get "$resource" -o wide >&2
      kube "$context" -n "$namespace" get pods -l "$selector" -o wide >&2
      die "Timed out after ${TIMEOUT}s: $context/$namespace/$resource -> $desired. Fix the cause and rerun; state is preserved."
    fi
    if (( SECONDS - reported >= 60 )); then
      count=$(jq '.items | length' <<< "$pods")
      ready=$(jq '.status.readyReplicas // 0' <<< "$workload")
      if [[ "$mode" == minimum ]]; then
        resource_log 'Still waiting for' "$context" "$namespace" "$resource" " ($ready ready, HPA minimum $desired, $count pods present)..."
      else
        resource_log 'Still waiting for' "$context" "$namespace" "$resource" " ($ready/$desired ready, $count pods present)..."
      fi
      reported=$SECONDS
    fi
    sleep "$POLL_INTERVAL"
  done
}

wait_workload() {
  local context=$1 namespace=$2 resource=$3 desired=$4 mode=${5:-exact}
  if [[ "$mode" == minimum ]]; then
    resource_log 'Waiting for' "$context" "$namespace" "$resource" " to reach at least $desired healthy replicas (HPA minimum)..."
  elif (( desired == 0 )); then
    resource_log 'Waiting for' "$context" "$namespace" "$resource" ' pods to terminate...'
  else
    resource_log 'Waiting for' "$context" "$namespace" "$resource" " to reach $desired healthy replicas..."
  fi
  waiting_step "$context" "$namespace:$resource -> $desired replicas" \
    wait_workload_body "$context" "$namespace" "$resource" "$desired" "$mode"
  [[ "$WAIT_SKIPPED" == false ]] || return 0
  if [[ "$namespace" == vault && "$desired" != 0 ]]; then
    start_vault_unseal "$context" "$namespace" "$resource" "$desired"
    resource_log 'Waiting for' "$context" "$namespace" "$resource" ' to be unsealed automatically...'
    waiting_step "$context" 'Vault unsealing' wait_vault_body "$context" "$namespace" "$resource" "$desired"
    stop_process_group "$UNSEAL_PID"
    UNSEAL_PID=''
    rm -rf -- "$UNSEAL_DIR"
    UNSEAL_DIR=''
    [[ "$WAIT_SKIPPED" == false ]] || return 0
  fi
  if [[ "$mode" == minimum ]]; then
    resource_log 'Finished' "$context" "$namespace" "$resource" " (HPA minimum $desired healthy replicas satisfied)."
  else
    resource_log 'Finished' "$context" "$namespace" "$resource" " ($desired replicas)."
  fi
}

set_replicas() {
  local context=$1 namespace=$2 resource=$3 desired=$4 mode=${5:-exact} workload current owner kind name target patch
  workload=$(kube "$context" -n "$namespace" get "$resource" -o json)
  current=$(jq '.spec.replicas // 1' <<< "$workload")
  if [[ "$mode" == minimum ]] && (( current >= desired )); then
    resource_log 'Keeping' "$context" "$namespace" "$resource" " at $current replicas (HPA minimum $desired)..."
    return 0
  fi
  if (( desired == 0 )) && ! jq -e '
    .kind != "StatefulSet" or (.spec.persistentVolumeClaimRetentionPolicy.whenScaled // "Retain") == "Retain"
  ' >/dev/null <<< "$workload"; then
    die "whenScaled is not Retain: $context/$namespace/$resource"
  fi
  owner=$(jq -c '[.metadata.ownerReferences[]? | select(.controller != false)][0] // {}' <<< "$workload")
  kind=$(jq -r '.kind // ""' <<< "$owner")
  name=$(jq -r '.name // ""' <<< "$owner")
  case "$kind" in
    Prometheus|Alertmanager)
      if [[ "$kind" == Prometheus ]]; then target="prometheus.monitoring.coreos.com/$name"
      else target="alertmanager.monitoring.coreos.com/$name"; fi
      patch=$(jq -nc --argjson n "$desired" '{spec:{replicas:$n}}') ;;
    AWX)
      target="awx.awx.ansible.com/$name"
      # Per-component fields override spec.replicas and can differ.
      if [[ "$resource" == "deployment/$name-task" ]]; then
        patch=$(jq -nc --argjson n "$desired" '{spec:{replicas:$n,task_replicas:$n}}')
      elif [[ "$resource" == "deployment/$name-web" ]]; then
        patch=$(jq -nc --argjson n "$desired" '{spec:{replicas:$n,web_replicas:$n}}')
      else die "Unsupported AWX component: $namespace/$resource"; fi ;;
    OpenTelemetryCollector)
      target="opentelemetrycollector.opentelemetry.io/$name"
      patch=$(jq -nc --argjson n "$desired" '{spec:{replicas:$n}}') ;;
    CAPIProvider)
      target="capiprovider.turtles-capi.cattle.io/$name"
      patch=$(jq -nc --argjson n "$desired" '{spec:{deployment:{replicas:$n}}}') ;;
    Gateway)
      # Istio 1.28 waypoints use a ConfigMap overlay, not a replicas annotation.
      # Keep the Gateway CR, and attach a temporary infrastructure parametersRef.
      target="gateway.gateway.networking.k8s.io/$name"
      patch=$(jq -nc --arg name "$name" '{spec:{infrastructure:{parametersRef:{group:"",kind:"ConfigMap",name:("maintenance-"+$name)}}}}')
      resource_log 'Patching' "$context" "$namespace" "$target" " with deployment.spec.replicas=$desired..."
      kube "$context" -n "$namespace" create configmap "maintenance-$name" \
        --from-literal="deployment={\"spec\":{\"replicas\":$desired}}" --dry-run=client -o json |
        kube "$context" apply -f - >/dev/null
      kube "$context" -n "$namespace" patch "$target" --type=merge -p "$patch" >/dev/null
      return ;;
    Tenant|Kiali)
      # These CR schemas cannot express zero replicas. Their operators must
      # already have stopped before we touch the generated workloads.
      if (( desired == 0 )); then
        if [[ "$kind" == Tenant ]]; then
          wait_workload "$context" minio-operator deployment/minio-operator 0
        else
          wait_workload "$context" kiali-operator deployment/kiali-operator 0
        fi
      fi
      target='' ;;
    '') target='' ;;
    *) die "Unsupported owner: $context/$namespace/$resource -> $kind/$name" ;;
  esac
  if [[ -n "$target" ]]; then
    resource_log 'Patching' "$context" "$namespace" "$target" " with replicas=$desired..."
    kube "$context" -n "$namespace" patch "$target" --type=merge -p "$patch" >/dev/null
  else
    if (( desired == 0 )); then
      resource_log 'Scaling down' "$context" "$namespace" "$resource" " from $current to $desired..."
    else
      resource_log 'Scaling up' "$context" "$namespace" "$resource" " from $current to $desired..."
    fi
    kube "$context" -n "$namespace" scale "$resource" --replicas="$desired" >/dev/null
  fi
}

webhook_policy() {
  local context=$1 policy=$2 namespace=${3:-} entries entry resource current patch
  entries=$(jq -c --arg c "$context" --arg ns "$namespace" '
    .contexts[$c].webhooks[] | select($ns == "" or .namespace == $ns)' <<< "$STATE")
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    resource=$(jq -r '.resource' <<< "$entry")
    current=$(kube "$context" get "$resource" -o json)
    patch=$(jq -nc --argjson saved "$entry" --argjson current "$current" --arg policy "$policy" '
      [$current.webhooks | to_entries[] | . as $w |
       select(any($saved.entries[]; .name == $w.value.name)) |
       select(.value.failurePolicy != $policy) |
       {op:"test",path:("/webhooks/"+(.key|tostring)+"/name"),value:.value.name},
       {op:"add",path:("/webhooks/"+(.key|tostring)+"/failurePolicy"),value:$policy}]')
    if [[ "$patch" != '[]' ]]; then
      resource_log 'Patching' "$context" "$(jq -r '.namespace' <<< "$entry")" "$resource" " with failurePolicy=$policy..."
      kube "$context" patch "$resource" --type=json -p "$patch" >/dev/null
    fi
  done <<< "$entries"
}

group_webhook_policy() {
  local group=$1 policy=$2 pairs context namespace
  pairs=$(jq -r '[.[] | [.context,.namespace]] | unique[] | @tsv' <<< "$group")
  while IFS=$'\t' read -r context namespace; do
    webhook_policy "$context" "$policy" "$namespace"
  done <<< "$pairs"
}

run_groups() {
  local direction=$1 cluster=$2 groups group rows context namespace resource replicas mode stage phase key
  groups=$(jq -c --arg cluster "$cluster" --arg direction "$direction" '
    [.[] | select(if $cluster == "rancher" then .context == "rancher" else .context != "rancher" end)] |
    sort_by(.rank,.phase,.context,.namespace,.resource) | group_by([.rank,.phase]) |
    if $direction == "down" then reverse else . end | .[]' <<< "$WORKLOADS")
  while IFS= read -r group; do
    [[ -n "$group" ]] || continue
    stage=$(jq -r '.[0].stage' <<< "$group")
    phase=$(jq -r '.[0].phase' <<< "$group")
    group_selected "$cluster" "$stage" || continue
    key="$cluster:$stage:$phase"
    if [[ "$direction" == down ]] && jq -e --arg key "$key" \
      '(.downCompleted | index($key)) != null' >/dev/null <<< "$STATE" && \
      jq -e 'all(.[]; .context == "xdev" or .context == "xtest")' >/dev/null <<< "$group"; then
      context_log "$cluster" "Skipping completed vCluster dependency set $key (its control plane may be offline)."
      continue
    fi
    phase_log "$direction" "$cluster" "$stage" "$phase"
    if [[ "$direction" == up ]]; then
      prepare_restore_group "$group"
      group=$RESTORE_GROUP
    fi
    if [[ "$direction" == up && "$stage" == vclusters && "$phase" == 2 ]]; then
      webhook_policy xdev Ignore
      webhook_policy xtest Ignore
    fi
    if [[ "$direction" == down ]]; then
      if [[ "$cluster" == homelab && "$stage" == storage && "$phase" == 2 ]]; then
        wait_storage_detach
      fi
      # Exceptions for CRs whose schemas reject zero; stop reconcilers first.
      if [[ "$stage" == minio && "$phase" == 1 ]]; then
        set_replicas homelab minio-operator deployment/minio-operator 0
        wait_workload homelab minio-operator deployment/minio-operator 0
      elif [[ "$stage" == istio && "$phase" == 1 ]]; then
        set_replicas homelab kiali-operator deployment/kiali-operator 0
        wait_workload homelab kiali-operator deployment/kiali-operator 0
      fi
      group_webhook_policy "$group" Ignore
    fi
    # Start/stop the entire dependency set before waiting: e.g. Harbor core
    # and registry, or Argo CD controller and repo-server, need each other.
    rows=$(jq -r '.[] | [.context,.namespace,.resource,(.replicas|tostring),(.readiness // "exact")] | @tsv' <<< "$group")
    while IFS=$'\t' read -r context namespace resource replicas mode; do
      [[ "$direction" == up ]] || replicas=0
      set_replicas "$context" "$namespace" "$resource" "$replicas" "$mode"
    done <<< "$rows"
    while IFS=$'\t' read -r context namespace resource replicas mode; do
      [[ "$direction" == up ]] || replicas=0
      wait_workload "$context" "$namespace" "$resource" "$replicas" "$mode"
    done <<< "$rows"
    if [[ "$direction" == down ]]; then
      group_webhook_policy "$group" Ignore
      STATE=$(jq --arg key "$key" '.downCompleted += [$key] | .downCompleted |= unique' <<< "$STATE")
      save_state
    else
      group_webhook_policy "$group" Fail
    fi
  done <<< "$groups"
}

restore_nodes() {
  local context=$1 node
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    resource_log 'Uncordoning' "$context" kube-system "node/$node" '...'
    kube "$context" uncordon "$node" >/dev/null
  done < <(jq -r --arg c "$context" '.contexts[$c].nodes[] | select(.unschedulable == false) | .name' <<< "$STATE")
  context_log "$context" 'Waiting for all nodes to be Ready...'
  waiting_step "$context" 'all nodes Ready' wait_nodes_body "$context"
}

wait_nodes_body() {
  local context=$1 started=$SECONDS reported=$SECONDS nodes
  while :; do
    nodes=$(kube "$context" get nodes -o json)
    if jq -e '(.items|length)>0 and all(.items[]; any(.status.conditions[]?; .type=="Ready" and .status=="True"))' >/dev/null <<< "$nodes"; then return 0; fi
    (( SECONDS - started < TIMEOUT )) || die "Timed out waiting for $context nodes to be Ready."
    if (( SECONDS - reported >= 60 )); then
      context_log "$context" 'Still waiting for all nodes to be Ready...'
      reported=$SECONDS
    fi
    sleep "$POLL_INTERVAL"
  done
}

restore_auxiliary() {
  local context=$1 row namespace resource patch
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    namespace=$(jq -r '.namespace' <<< "$row")
    resource=$(jq -r '.resource' <<< "$row")
    patch=$(jq -c '{spec:{minReplicas:.minReplicas,maxReplicas:.maxReplicas}}' <<< "$row")
    resource_log 'Restoring' "$context" "$namespace" "$resource" ' autoscaling limits...'
    kube "$context" -n "$namespace" patch "$resource" --type=merge -p "$patch" >/dev/null
  done < <(jq -c --arg c "$context" '.contexts[$c].hpas[]' <<< "$STATE")
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    namespace=$(jq -r '.namespace' <<< "$row")
    resource=$(jq -r '.resource' <<< "$row")
    patch=$(jq -c '{spec:{suspend:.suspend}}' <<< "$row")
    resource_log 'Restoring' "$context" "$namespace" "$resource" ' scheduling...'
    kube "$context" -n "$namespace" patch "$resource" --type=merge -p "$patch" >/dev/null
  done < <(jq -c --arg c "$context" '.contexts[$c].cronjobs[]' <<< "$STATE")
}

restore_gateways() {
  local row namespace resource name patch
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    namespace=$(jq -r '.namespace' <<< "$row")
    name=$(jq -r '.name' <<< "$row")
    resource="gateway.gateway.networking.k8s.io/$name"
    resource_log 'Restoring' homelab "$namespace" "$resource" ' infrastructure settings...'
    if jq -e '.infrastructure == null' >/dev/null <<< "$row"; then
      kube homelab -n "$namespace" patch "$resource" --type=merge -p '{"spec":{"infrastructure":null}}' >/dev/null
    else
      patch=$(jq -c '[{op:"add",path:"/spec/infrastructure",value:.infrastructure}]' <<< "$row")
      kube homelab -n "$namespace" patch "$resource" --type=json -p "$patch" >/dev/null
    fi
    kube homelab -n "$namespace" delete configmap "maintenance-$name" --ignore-not-found >/dev/null
  done < <(jq -c '.gateways[]' <<< "$STATE")
}

uncordon_main() {
  initialize
  parse_arguments "$@"
  case "$MODE" in
    plan) print_plan up; return ;;
    check)
      local context
      for context in rancher homelab xdev xtest; do
        check_workloads "$context"
        check_owners "$context"
      done
      log 'Read-only checks passed.'
      return ;;
  esac
  read_state
  resolve_resume_target
  install_handlers
  log "Restoring workloads using $STATE_FILE..."
  STATE=$(jq '.status="restoring" | .downCompleted=[] | .skippedWaits=[]' <<< "$STATE")
  save_state
  for context in rancher homelab; do
    cluster_selected "$context" up || continue
    restore_nodes "$context"
    webhook_policy "$context" Ignore
    run_groups up "$context"
  done
  restore_gateways
  for context in rancher homelab xdev xtest; do
    [[ "$context" != rancher ]] || cluster_selected rancher up || continue
    webhook_policy "$context" Fail
    restore_auxiliary "$context"
  done
  STATE=$(jq '.status = "restored"' <<< "$STATE")
  save_state
  if (( SKIPPED_WAIT_COUNT > 0 )); then
    log "Restore steps complete with $SKIPPED_WAIT_COUNT skipped waits; those health checks were not confirmed. Maintenance settings are restored."
  else
    log "$THUMBUP" 'Restore complete: selected replica targets are healthy and maintenance settings are restored.'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  uncordon_main "$@"
fi
