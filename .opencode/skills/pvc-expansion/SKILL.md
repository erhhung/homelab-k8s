---
name: pvc-expansion
description: Safely performs online Kubernetes PVC expansion in homelab or vClusters such as xdev. Use when enlarging persistent volumes, recreating StatefulSets with orphaned pods, or coordinating virtual and host PVC resizing with the Kyverno pvc-retention-policy.
---

# PVC Expansion

Expand existing PVCs while preserving their identities, backing volumes, and
running pods. Follow `AGENTS.md` and inspect live resources before choosing the
procedure. A larger Helm value alone does not resize an existing StatefulSet
claim template or its PVCs.

## Context And Scope

- Always pass an explicit `--context` and namespace to kubectl. Never change the
  current context as a shortcut. Identically named namespaces may contain
  unrelated databases in `homelab` and a vCluster.
- Use `homelab` for primary-cluster resources and the host Kyverno policy. Use
  the requested vCluster context, such as `xdev`, for its virtual workload.
- Resolve vCluster backing resources from live labels, annotations, PVC volume
  names, and UIDs. Do not infer the mapping solely from names. A virtual
  namespace may map to a host namespace such as `xdev-<namespace>`.
- A virtual StatefulSet does not necessarily exist in the host cluster.
  Inspect both clusters: a vCluster may synchronize only pods and PVCs.
- Do not deploy repository playbooks as validation. Do not modify unrelated
  workloads or migrate replicas as part of a resize without authorization.
- The relevant vars file containing the Helm value for the PVC size should
  already specify the requested new size. If it does not, ask the user whether
  to update that vars file along with the live PVC expansion.

## 1. Preflight And Recovery Preparation

1. Identify the requested PVCs, their consumers, the controlling workload, and
   any operator or GitOps controller that could immediately recreate it.
2. Record original UIDs and settings: StatefulSet, pods, PVCs, bound PV names,
   storage classes, requested and actual capacities, replica count, retention
   policy, update strategy, readiness, and container restart counts. For a
   vCluster, record both virtual and host pod/PVC identities.
3. Inspect every PVC associated with a StatefulSet, including claims that are
   not being expanded. They all need protection when the controller is deleted.
4. Check that the storage class permits expansion and the CSI driver supports
   expansion of the mounted filesystem. Keep the existing storage class,
   access modes, volume mode, and bound volume.
5. For Longhorn, verify volume health, replica health, and capacity on every
   replica disk. Check free-space thresholds, reserved space, and scheduled
   capacity, not just aggregate cluster free space. A server-side dry run of
   the PVC size patch can expose admission failures before orphaning.
6. Verify the relevant vars file already sets the Helm PVC size to the requested
   new size. If not, ask the user whether to update that file along with the PVC
   expansion before editing it. For workloads managed through other manifests,
   verify their declarative size as well; avoid reverting user changes. For an
   operator-managed workload, its custom resource must also request the size.
7. Prepare a sanitized recreation manifest and a recovery path before deleting
   anything. Preserve the live pod template, selectors, service name, labels,
   annotations, owner references where appropriate, and unaffected claim
   templates. Remove server-generated metadata (`uid`, `resourceVersion`,
   `generation`, `creationTimestamp`, `managedFields`) and resource `status`.
   Remove claim-template `status` fields too. Treat exported manifests as
   potentially sensitive; do not commit transient backups.

Proceed with known workload health. Existing crash loops should be recorded and
diagnosed; disk-full failures may recover after expansion. Do not claim a resize
fixes an unrelated OOM or readiness failure.

## 2. Choose The Controller Path

### Standalone PVC Used By A Deployment

Patch the PVC storage request in place and verify expansion. StatefulSet
recreation and a Kyverno policy change are unnecessary when no StatefulSet is
being recreated. Keep the Deployment and pod running if online expansion works.

### StatefulSet Claim Template

The claim-template storage request is immutable on the existing StatefulSet.
Recreate that controller with the updated template while orphaning its pods.
Patch existing PVCs separately; changing the template does not resize them.

For operator-managed StatefulSets, pause reconciliation using the supported
custom-resource control before orphaning. Update the custom resource to the
target size and desired replica count, then let the operator recreate the
StatefulSet when resumed. Avoid competing with the operator by hand-creating
its managed resources.

## 3. Disable Kyverno And Protect All Claims

Before any StatefulSet recreation, temporarily disable **both** admission and
mutate-existing evaluations of `pvc-retention-policy` in `homelab`. It forces
`whenDeleted: Delete`, which defeats attempts to retain claims if left enabled.

```bash
kubectl --context homelab patch mutatingpolicy pvc-retention-policy \
  --type=merge \
  -p '{"spec":{"evaluation":{"admission":{"enabled":false},"mutateExisting":{"enabled":false}}}}'
```

Record the original evaluation settings and change only these fields. Verify
they are disabled by reading the policy back. Admission configuration changes
may take time to propagate: trust observed resource state, not patch success.

1. Set the affected StatefulSet retention to
   `whenDeleted: Retain` and `whenScaled: Retain` in the workload's context.
2. Read the StatefulSet back and verify both values persisted. If the policy
   still overrides them, wait for propagation and retry before proceeding.
3. Wait for the StatefulSet controller to remove deletion owner references
   from **all** associated PVCs. Verify none has a deletion timestamp. Do not
   manually strip unexpected owners without understanding them.
4. In a vCluster, verify the same protections on the mapped host PVCs and on
   any actual host StatefulSet. Do not delete a host StatefulSet behind an
   active syncer; establish which controller owns reconciliation first.
5. Do not orphan while any claim still has a deletion relationship to a
   controller being removed. `--cascade=orphan` is not a substitute for these
   checks.

## 4. Orphan, Expand, And Recreate

The placeholders below must come from verified live resource mappings:

```bash
kubectl --context "$WORKLOAD_CONTEXT" -n "$NAMESPACE" \
  delete statefulset "$STATEFULSET" --cascade=orphan --wait=true

kubectl --context "$WORKLOAD_CONTEXT" -n "$NAMESPACE" \
  patch pvc "$PVC" --type=merge \
  -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"$TARGET_SIZE\"}}}}"

kubectl --context "$WORKLOAD_CONTEXT" -n "$NAMESPACE" \
  wait "pvc/$PVC" --for="jsonpath={.status.capacity.storage}=$TARGET_SIZE" \
  --timeout=240s
```

1. After deletion, verify the original pods still exist with the same UIDs,
   no deletion timestamps, and no owner reference to the removed StatefulSet.
2. Patch each requested PVC. For several claims, track every result and verify
   every claim individually. Never delete or replace PVCs or PVs to resize them.
3. For a vCluster, patch the virtual PVC and allow synchronization to update
   the host PVC. Verify the host request, host capacity, and virtual capacity
   all reach the target. If synchronization stalls, inspect syncer logs and
   events before considering any direct host patch.
4. Wait for capacity expansion and inspect resize conditions. If filesystem
   expansion requires a remount, establish the necessary controlled restart;
   do not repeatedly delete pods or promise uninterrupted service.
5. Recreate the StatefulSet from the prepared live manifest, modifying only
   the requested claim-template sizes and temporary controls. Use `create`
   for the absent resource. Keep the original desired replica count; a
   multi-replica service must not be reduced to one or zero for this recipe.
6. For manually recreated StatefulSets, temporarily use `OnDelete` to prevent
   an unintended rolling restart while adoption is verified. Preserve the
   original pod template exactly. For operator recreation, use supported
   controls and observe whether the operator initiates a rollout.
7. Ensure restoration is attempted even if a patch or wait fails. Recreate a
   missing controller using sizes consistent with accepted PVC requests.
   Never attempt to shrink an accepted request as rollback.

If retaining the `kubectl.kubernetes.io/last-applied-configuration` annotation,
update the stored claim size without persisting temporary update-strategy or
retention settings as desired configuration.

## 5. Verify Adoption And Restore Settings

Before re-enabling Kyverno after a successful expansion, verify:

- Every requested PVC reports the new request and actual capacity, with no
  unresolved resize condition or deletion timestamp.
- Original PVC UIDs, PV bindings, storage classes, and backing volume identities
  are preserved. Unaffected claim sizes remain unchanged.
- The recreated StatefulSet has a new UID, the target claim-template sizes, and
  the original desired replica count.
- Each original pod has been adopted by the new StatefulSet UID. In a vCluster,
  verify virtual ownership and host pod preservation separately; a host pod
  need not have a host StatefulSet owner.
- Longhorn reports the target volume size and healthy replicas at the original
  replication count. Confirm the mounted filesystem size with a read-only
  command such as `df -h <mount-path>` where practical.

Restore the original update strategy, including any rolling-update partition,
and original retention settings. Resume any paused reconciliation. Original
retention may be `Retain/Retain` in a vCluster; do not blindly impose the host
policy's `Delete/Retain` values on virtual resources.

Restore both Kyverno evaluations to their recorded values (normally `true`):

```bash
kubectl --context homelab patch mutatingpolicy pvc-retention-policy \
  --type=merge \
  -p '{"spec":{"evaluation":{"admission":{"enabled":true},"mutateExisting":{"enabled":true}}}}'
```

Read the policy back. Verify controller reconciliation, desired/ready replica
counts, pod UIDs, restart counts, volume health, and policy state again. A
successful rollout message alone does not prove pods are ready. Report any
operator-induced pod replacement or remaining workload failure accurately.

## Blocked Or Partial Expansion

- If Longhorn rejects a resize, inspect its admission message and the affected
  replica disks. Free space, expand storage, or propose a separately authorized
  replica migration. Do not lower disk safety thresholds or reduce replication
  to force the resize.
- If the request was rejected, restore the controller template to the actual
  original request. If accepted but not completed, keep the larger request and
  diagnose the pending expansion; PVC shrinking is not a recovery option.
- For a partial multi-PVC expansion, preserve successful increases and record
  which claims still need work. Do not roll them back or replace the claims.
- Never leave the controller absent or the global policy disabled silently.
  On abort, restore a safe controller, verify claim protection and pod adoption,
  restore original settings, and then restore policy evaluations. If that
  recovery is blocked, report the exact remaining temporary state explicitly.
- Distinguish storage completion from workload readiness: an unrelated OOM or
  startup failure should not leave the global policy disabled once expansion
  and adoption are verified.

## Completion Report

State the context and namespace, old/new size, PVC and backing-volume identity
preservation, claim-template size, desired/ready replicas, pod preservation or
restarts, storage health, and final Kyverno evaluation state. For a vCluster,
include the mapped host namespace and confirm both PVC representations reached
the target. If blocked, report the actual capacity and safe recovery state.
