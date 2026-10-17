#!/usr/bin/env bash

# shellcheck disable=SC1091 # Not following: not input file

# Gracefully stop replica-managed workloads before shutting down the node VMs.
#
# Usage: drainall.sh [--plan|--check] [TARGET|CONTEXT:TARGET]
# --check is read-only; --plan prints the dependency sets without API calls.
# Resume requires an active journal; bare shared targets prefer homelab.
# Earlier targets must already be stopped. Ctrl-C during a wait offers a skip.
#
# DaemonSets, static control-plane pods, and Longhorn/Mountpoint helper pods
# remain running until the VMs halt. This script does not power off any VM.

# FUTURE WORKLOAD UPDATES (the shared inventory/helpers live in uncordon.sh):
# - The XCP-ng hosts and Kubernetes nodes are fully utilized. Do NOT replace this
#   procedure with per-node draining, evictions, or pod migration: there is no
#   spare capacity, and one hypervisor can contain several Kubernetes nodes.
# - Refresh uncordon.sh FIRST while workloads are running, using live desired
#   replica counts and the current main.yml dependency graph. These scripts must
#   cover every Deployment/StatefulSet in the selected contexts; unknown/missing
#   inventory entries must fail preflight instead of being silently skipped.
# - Shutdown is homelab FIRST, rancher LAST; reverse the playbook/phase order used
#   for startup. Inside homelab, stop dev/test vCluster applications before their
#   databases/DNS and parent control planes. Stopping a vCluster StatefulSet alone
#   leaves its synced application pods running on the physical cluster.
# - When adding/renaming contexts or vClusters, update capture_state(), the
#   maintenance loops below, uncordon.sh's context count/mappings/restore loops,
#   and verify_stopped()'s synced namespace matching. Context names are explicit;
#   never fall back to the kubectl default context or discover contexts blindly.
# - Inspect operator ownership before changing shutdown behavior. Extend the
#   shared check_owners()/set_replicas() handlers and CR preflight checks together.
#   Patch the actual controlling field(s), never delete the CR. Operators must
#   stay alive until CR changes reconcile and ALL child pods terminate. If a CR
#   cannot express zero (currently MinIO/Kiali), stop its operator first and then
#   scale the generated workload; preserve the CR and restore the operator later.
# - All StatefulSets must have whenScaled=Retain (omission defaults to Retain).
#   Check operator CR retention too, and reject stale PVC Pod owner references;
#   PV reclaimPolicy is a different setting and cannot establish scale safety.
#   Recheck retention immediately before scaling, and leave PVCs/StatefulSets in
#   place. If a future update recreates a StatefulSet, follow AGENTS.md's separate
#   Kyverno-disable/whenDeleted=Retain/owner-reference procedure before doing so.
# - Capture replicas and original HPA/CronJob/webhook/node/Gateway settings once,
#   BEFORE any mutation, to STATE_FILE on the workstation (outside the clusters).
#   Retain the journal through VM/host reboots. Resume from it without overwriting
#   saved nonzero counts with current zeros; completed vCluster checkpoints must
#   remain usable after their APIs go offline. Preserve journal compatibility
#   when fixing a partially completed run; never recapture its zeroed replicas.
# - Suspend CronJobs and wait for active scheduled jobs before their dependencies
#   stop. Pin HPAs during shutdown; uncordon.sh restores their original limits at
#   target startup and waits for >= minReplicas, not a captured autoscaled count.
#   Discover live HPAs too, including ones created after this snapshot. Fail-open
#   only the saved admission webhook entries while their backends are offline;
#   restore original settings.
#   New reconcilers/webhooks may need additional reversible preflight handling.
# - Wait for each dependency set's pods to disappear before stopping the next;
#   wait for CSI detach while storage controllers still run, then verify zero
#   workloads before cordoning nodes. DaemonSets/static/storage-helper pods are
#   outside replica scaling and stop with the VMs; account for new helper types.
#   Match VolumeAttachments to live Pod -> PVC -> PV consumers: node-exporter's
#   retained RWX PVC has attachments on every node and will NEVER detach here.
#   Report retained consumers and wait only for attachments with no live consumer.
#   Never force-delete attachments. Ctrl-C can explicitly skip an observation;
#   retain the final zero-workload checks and journal the unconfirmed waits.
# - Keep the initial explanation and exact typed confirmation "drainall". Emit
#   progress through shared log()/resource_log(): LOCAL [%Y-%m-%d %I:%M:%S %p],
#   context immediately after timestamp; namespace ESC[1;36m, type/name ESC[1;33m,
#   scaling target ESC[1;35m, timestamp ESC[1;37m; other text normal. All kubectl
#   calls use the shared three-attempt/five-second retry and stdin replay helper.
# - Safe update checks: both --plan modes, drainall.sh --check, bash -n, ShellCheck,
#   and mocked cancellation/PVC rejection/operator ordering/shutdown/restore plus
#   failure-and-resume cases. Do not execute ordinary scripts or deployment
#   playbooks as validation unless the user explicitly requests live maintenance.

set -euo pipefail

# shellcheck source=uncordon.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/uncordon.sh"

capture_state() {
  local context live nodes webhooks cronjobs hpas gateways pvc unsafe
  STATE=$(jq -nc --argjson workloads "$WORKLOADS" \
    '{version:1,status:"prepared",workloads:$workloads,contexts:{},gateways:[],downCompleted:[]}')
  for context in rancher homelab xdev xtest; do
    check_workloads "$context"
    check_owners "$context"
    live=$LIVE_WORKLOADS
    # Capture once, before the first mutation. This also captures HPA changes
    # since the embedded baseline was written; never recapture during a resume.
    WORKLOADS=$(jq --arg c "$context" --argjson live "$live" 'map(
      if .context == $c then . as $w |
        .replicas = ($live.items[] | select(.metadata.namespace == $w.namespace and
          ((.kind|ascii_downcase)+"/"+.metadata.name) == $w.resource) | .spec.replicas // 1)
      else . end)' <<< "$WORKLOADS")
    nodes=$(kube "$context" get nodes -o json | jq '[.items[] |
      {name:.metadata.name,unschedulable:(.spec.unschedulable // false)}]')
    webhooks=$(kube "$context" get mutatingwebhookconfigurations,validatingwebhookconfigurations -o json |
      jq '[.items[] | . as $config | [.webhooks[]? | select((.failurePolicy // "Fail") == "Fail")] |
        group_by(.clientConfig.service.namespace)[] | select(.[0].clientConfig.service != null) |
        {resource:(($config.kind|ascii_downcase)+"/"+$config.metadata.name),
         namespace:.[0].clientConfig.service.namespace,entries:map({name:.name})}]')
    cronjobs=$(kube "$context" get cronjobs -A -o json | jq '[.items[] |
      {namespace:.metadata.namespace,resource:("cronjob/"+.metadata.name),suspend:(.spec.suspend // false)}]')
    hpas=$(kube "$context" get hpa -A -o json | jq '[.items[] |
      {namespace:.metadata.namespace,resource:("hpa/"+.metadata.name),
       minReplicas:(.spec.minReplicas // 1),maxReplicas:.spec.maxReplicas,
       target:((.spec.scaleTargetRef.kind|ascii_downcase)+"/"+.spec.scaleTargetRef.name)}]')
    pvc=$(kube "$context" get pvc -A -o json)
    # Stale Pod owner references from a previous Delete policy can still
    # garbage-collect claims despite the StatefulSet now reporting Retain.
    unsafe=$(jq -r --argjson live "$live" '.items[] | . as $pvc |
      select(any(.metadata.ownerReferences[]?; .kind == "Pod")) |
      select(any($live.items[]; .kind == "StatefulSet" and .metadata.namespace == $pvc.metadata.namespace and
        any(.spec.volumeClaimTemplates[]?; .metadata.name as $template |
          $pvc.metadata.name | startswith($template+"-")))) |
      .metadata.namespace+":pvc/"+.metadata.name' <<< "$pvc")
    [[ -z "$unsafe" ]] || die "PVCs still owned by Pods in $context: $unsafe"
    STATE=$(jq --arg c "$context" --argjson nodes "$nodes" --argjson webhooks "$webhooks" \
      --argjson cronjobs "$cronjobs" --argjson hpas "$hpas" \
      '.contexts[$c] = {nodes:$nodes,webhooks:$webhooks,cronjobs:$cronjobs,hpas:$hpas}' <<< "$STATE")
  done
  gateways=$(kube homelab get gateways.gateway.networking.k8s.io -A -o json |
    jq '[.items[] | select(.spec.gatewayClassName == "istio-waypoint") |
      {namespace:.metadata.namespace,name:.metadata.name,infrastructure:.spec.infrastructure}]')
  unsafe=$(jq -r '.[] | select(.infrastructure.parametersRef != null) | .namespace+":"+.name' <<< "$gateways")
  [[ -z "$unsafe" ]] || die "Gateway already has an infrastructure overlay (add an explicit handler): $unsafe"
  local row namespace name existing
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    namespace=$(jq -r '.namespace' <<< "$row")
    name=$(jq -r '.name' <<< "$row")
    existing=$(kube homelab -n "$namespace" get configmap "maintenance-$name" --ignore-not-found -o name)
    [[ -z "$existing" ]] || die "Temporary ConfigMap already exists: $namespace/$existing"
  done < <(jq -c '.[]' <<< "$gateways")
  local crs
  crs=$(kube homelab get prometheuses.monitoring.coreos.com,alertmanagers.monitoring.coreos.com -A -o json)
  unsafe=$(jq -r '.items[] |
    select(.spec.paused == true or (.spec.persistentVolumeClaimRetentionPolicy.whenScaled // "Retain") != "Retain") |
    .metadata.namespace+":"+.kind+"/"+.metadata.name' <<< "$crs")
  [[ -z "$unsafe" ]] || die "Prometheus/Alertmanager CR is paused or does not retain scaled PVCs: $unsafe"
  STATE=$(jq --argjson workloads "$WORKLOADS" --argjson gateways "$gateways" \
    '.workloads=$workloads | .gateways=$gateways' <<< "$STATE")
}

suspend_cronjobs() {
  local context=$1 row namespace resource jobs job
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    namespace=$(jq -r '.namespace' <<< "$row")
    resource=$(jq -r '.resource' <<< "$row")
    resource_log 'Suspending' "$context" "$namespace" "$resource" '...'
    kube "$context" -n "$namespace" patch "$resource" --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
    jobs=$(kube "$context" -n "$namespace" get "$resource" -o json | jq -r '.status.active[]?.name')
    while IFS= read -r job; do
      [[ -n "$job" ]] || continue
      resource_log 'Waiting for' "$context" "$namespace" "job/$job" ' to finish before stopping its dependencies...'
      waiting_step "$context" "$namespace:job/$job completion" wait_job_body "$context" "$namespace" "$job"
    done <<< "$jobs"
  done < <(jq -c --arg c "$context" '.contexts[$c].cronjobs[]' <<< "$STATE")
}

wait_job_body() {
  local context=$1 namespace=$2 job=$3 row started=$SECONDS reported=$SECONDS
  while :; do
    row=$(kube "$context" -n "$namespace" get job "$job" --ignore-not-found -o json)
    [[ -n "$row" ]] || return 0
    if jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' >/dev/null <<< "$row"; then return 0; fi
    if jq -e 'any(.status.conditions[]?; .type == "Failed" and .status == "True")' >/dev/null <<< "$row"; then
      die "Scheduled job failed: $context/$namespace/$job"
    fi
    (( SECONDS - started < TIMEOUT )) || die "Timed out waiting for scheduled job: $context/$namespace/$job"
    if (( SECONDS - reported >= 60 )); then
      resource_log 'Still waiting for' "$context" "$namespace" "job/$job" ' to finish...'
      reported=$SECONDS
    fi
    sleep "$POLL_INTERVAL"
  done
}

pin_hpas() {
  local context=$1 row namespace resource target replicas patch
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    namespace=$(jq -r '.namespace' <<< "$row")
    resource=$(jq -r '.resource' <<< "$row")
    target=$(jq -r '.target' <<< "$row")
    replicas=$(jq -r --arg c "$context" --arg ns "$namespace" --arg target "$target" \
      '.[] | select(.context == $c and .namespace == $ns and .resource == $target) | .replicas' <<< "$WORKLOADS")
    [[ -n "$replicas" ]] || die "HPA target not captured: $context/$namespace/$target"
    (( replicas > 0 )) || continue
    patch=$(jq -nc --argjson n "$replicas" '{spec:{minReplicas:$n,maxReplicas:$n}}')
    resource_log 'Pinning' "$context" "$namespace" "$resource" " to $replicas replicas until target startup..."
    kube "$context" -n "$namespace" patch "$resource" --type=merge -p "$patch" >/dev/null
  done < <(jq -c --arg c "$context" '.contexts[$c].hpas[]' <<< "$STATE")
}

verify_stopped() {
  local context=$1 workloads pods remaining
  workloads=$(kube "$context" get deployments,statefulsets -A -o json)
  remaining=$(jq -r '.items[] | select((.spec.replicas // 1) != 0 or (.status.replicas // 0) != 0) |
    .metadata.namespace+":"+(.kind|ascii_downcase)+"/"+.metadata.name' <<< "$workloads")
  [[ -z "$remaining" ]] || die "Workloads restarted or have not stopped in $context: $remaining"
  pods=$(kube "$context" get pods -A -o json)
  remaining=$(jq -r '.items[] |
    select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet" or .kind == "StatefulSet") or
      (.metadata.namespace | test("^x(dev|test)-"))) |
    select(.status.phase != "Succeeded" and .status.phase != "Failed") |
    .metadata.namespace+":pod/"+.metadata.name' <<< "$pods")
  [[ -z "$remaining" ]] || die "Workload pods are still running in $context: $remaining"
  log "$context: all Deployments/StatefulSets are at zero. DaemonSets, static pods, and storage helpers stop when the VMs halt."
}

wait_storage_detach() {
  context_log homelab 'Waiting for unused CSI volumes to detach before stopping storage controllers...'
  waiting_step homelab 'unused CSI volume detach' wait_storage_detach_body
}

attachment_consumers() {
  # Input is a compact PV/PVC/Pod list; stdin contains VolumeAttachments.
  jq -c --argjson resources "$1" '
    [$resources.items[] | select(.kind=="Pod" and .status.phase!="Succeeded" and .status.phase!="Failed") |
      . as $pod | .spec.volumes[]? | select(.persistentVolumeClaim) | .persistentVolumeClaim.claimName as $claim |
      $resources.items[] | select(.kind=="PersistentVolumeClaim" and .metadata.namespace==$pod.metadata.namespace and .metadata.name==$claim) |
      {pv:.spec.volumeName,node:$pod.spec.nodeName,namespace:$pod.metadata.namespace,pod:$pod.metadata.name}] as $consumers |
    [.items[] | select(.status.attached==true) | . as $va |
      {name:.metadata.name,pv:.spec.source.persistentVolumeName,node:.spec.nodeName,
       consumers:[$consumers[] | select(.pv==$va.spec.source.persistentVolumeName and .node==$va.spec.nodeName)]}] |
    {waiting:map(select(.consumers|length==0)),retained:map(select(.consumers|length>0))}'
}

storage_attachment_snapshot() {
  local resources
  resources=$(kube homelab get pv,pvc,pods -A -o json | jq -c '{items:[.items[] |
    {kind,metadata:{name:.metadata.name,namespace:.metadata.namespace},
     spec:{volumeName:.spec.volumeName,nodeName:.spec.nodeName,
       volumes:[.spec.volumes[]? | select(.persistentVolumeClaim) | {persistentVolumeClaim}]},
     status:{phase:.status.phase}}]}')
  kube homelab get volumeattachments -o json | attachment_consumers "$resources"
}

wait_storage_detach_body() {
  local started=$SECONDS reported=-60 details remaining retained previous='' row namespace name consumers
  while :; do
    details=$(storage_attachment_snapshot)
    retained=$(jq -c '.retained | sort_by(.name)' <<< "$details")
    if [[ "$retained" != "$previous" ]]; then
      while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        namespace=$(jq -r '.consumers[0].namespace' <<< "$row")
        name=$(jq -r '.name' <<< "$row")
        consumers=$(jq -r '[.consumers[] | .namespace+"/"+.pod] | unique | join(", ")' <<< "$row")
        resource_log 'Retaining' homelab "$namespace" "volumeattachment/$name" " for live consumers: $consumers."
      done < <(jq -c '.[]' <<< "$retained")
      previous=$retained
    fi
    remaining=$(jq -r '.waiting[] | .pv+" on "+.node+" ("+.name+")"' <<< "$details")
    if [[ -z "$remaining" ]]; then
      context_log homelab 'Unused CSI volumes have detached; attachments for retained consumers remain until those pods stop.'
      return 0
    fi
    if (( SECONDS - reported >= 60 )); then
      while IFS= read -r row; do context_log homelab "Still waiting for CSI detach: $row"; done <<< "$remaining"
      reported=$SECONDS
    fi
    (( SECONDS - started < TIMEOUT )) || die "CSI volumes still attached after ${TIMEOUT}s: $remaining"
    sleep "$POLL_INTERVAL"
  done
}

cordon_nodes() {
  local context=$1 node
  while IFS= read -r node; do
    [[ -n "$node" ]] || continue
    resource_log 'Cordoning' "$context" kube-system "node/$node" '...'
    kube "$context" cordon "$node" >/dev/null
  done < <(jq -r --arg c "$context" '.contexts[$c].nodes[].name' <<< "$STATE")
}

drainall_main() {
  initialize
  parse_arguments "$@"
  case "$MODE" in
    plan) print_plan down; return ;;
    check) capture_state; log 'Read-only preflight passed; no maintenance state was written.'; return ;;
  esac
  if [[ -n "$RESUME_TARGET" ]]; then
    read_state
    [[ "$(jq -r '.status' <<< "$STATE")" != restored ]] || die 'A shutdown resume target requires an active maintenance journal.'
    resolve_resume_target
  fi
  log 'All cluster Deployment/StatefulSet workloads will be scaled down to zero.'
  log 'Order: homelab (including dev/test vClusters), then rancher. Nodes will be cordoned.'
  log 'CronJobs will be suspended; admission webhooks will temporarily fail open while their controllers are offline.'
  log 'DaemonSets, static control-plane pods, and storage helpers remain until the VMs halt.'
  printf 'Type "drainall" to proceed: '
  local answer context
  IFS= read -r answer || die 'Confirmation was not received.'
  [[ "$answer" == drainall ]] || die 'Cancelled.'
  install_handlers
  if [[ -f "$STATE_FILE" ]] && [[ "$(jq -r '.status' "$STATE_FILE")" != restored ]]; then
    read_state
    log "Resuming maintenance using $STATE_FILE..."
  else
    capture_state
    save_state
    log "Replica targets and original maintenance settings saved to $STATE_FILE."
  fi
  resolve_resume_target
  STATE=$(jq '.status="draining" | .skippedWaits=[]' <<< "$STATE")
  save_state
  for context in homelab xdev xtest rancher; do
    if [[ "$context" == rancher ]]; then
      cluster_selected rancher down || continue
    else
      cluster_selected homelab down || continue
    fi
    # Completed vCluster sets may already have their control planes offline.
    if [[ "$context" == xdev || "$context" == xtest ]]; then
      if jq -e --arg c "$context" '.downCompleted | index("cronjobs:"+$c)' >/dev/null <<< "$STATE"; then continue; fi
    fi
    suspend_cronjobs "$context"
    pin_hpas "$context"
    STATE=$(jq --arg c "$context" '.downCompleted += ["cronjobs:"+$c] | .downCompleted |= unique' <<< "$STATE")
    save_state
  done
  for context in homelab rancher; do
    cluster_selected "$context" down || continue
    run_groups down "$context"
    verify_stopped "$context"
    cordon_nodes "$context"
  done
  STATE=$(jq '.status="drained"' <<< "$STATE")
  save_state
  if (( SKIPPED_WAIT_COUNT > 0 )); then
    log "$SKIPPED_WAIT_COUNT waiting checks were skipped; details are recorded in the maintenance journal."
  fi
  log "$THUMBUP" "Shutdown preparation complete. Halt the node VMs, reboot the XCP-ng hosts, then run $SCRIPT_DIR/uncordon.sh."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  drainall_main "$@"
fi
