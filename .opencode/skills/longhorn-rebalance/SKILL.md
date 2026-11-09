---
name: longhorn-rebalance
description: Rebalances Longhorn storage replicas across homelab nodes using healthy replacement copies before removing source replicas. Use when disk usage is uneven, nodes exceed scheduling limits, or replica placement needs redistribution while preserving running workloads.
---

# Longhorn Rebalance

Balance physical disk usage and scheduled capacity across all eligible nodes,
preserving volume identities, configured replication, running workloads, and
node/zone separation. Follow `AGENTS.md`. Execute live migrations only when the
user requests or authorizes rebalancing.

## Scope And Operating Rules

- Use an explicit `--context homelab` and `-n longhorn-system` for Longhorn
  resources. For another parent cluster, establish its context explicitly.
  vCluster backing volumes are managed in the parent cluster, not the virtual
  cluster; resolve their host PVC mappings before inspecting consumers.
- Do not run repository playbooks as validation. Replica migration does not
  require StatefulSet recreation, PVC resizing, pod deletion, or disabling
  Kyverno's `pvc-retention-policy`. Leave both policy evaluations enabled.
- Preserve storage safety thresholds and original replica counts. Do not
  increase over-provisioning, lower minimum-free-space settings, or reduce
  replication to make a destination eligible.
- Prefer comparable disk-usage percentages rather than equal bytes or replica
  counts: disks differ in size, and replicas differ greatly in actual footprint.
- Plan a full-cluster balance when requested, not just enough moves to clear
  one scheduling error. Avoid excessive moves for negligible improvements.
- Longhorn auto-balancing is per-volume and does not guarantee cluster-wide
  byte balance. Inspect the installed version and settings; changing the global
  auto-balance mode is not part of this procedure.

## 1. Capture A Baseline

Read the Longhorn manager version and collect nodes, disks, volumes, replicas,
engines, settings, and orphan resources. Save a timestamped baseline and plan
outside the tracked workspace, without exporting credentials or unrelated pod
environment values. Never reuse old volume IDs or a previous migration plan
without validating current resources.

Record:

- Node readiness, scheduling/eviction flags, topology zones, and node/disk tags.
- Each disk's `storageMaximum`, `storageAvailable`, `storageScheduled`,
  `storageReserved`, UUID, path, and Ready/Schedulable conditions.
- Global over-provisioning, minimum-free-space, replica anti-affinity, and
  auto-balance settings, plus per-volume overrides.
- Volume UID, size, actual size, replica count, data locality, node/disk
  selectors, attachment state, robustness, and Kubernetes PVC/workload mapping.
- Replica names/UIDs, nodes/disks, health/failure timestamps, eviction state,
  and engine `replicaModeMap` and `rebuildStatus`.
- PVC UIDs, PV bindings, capacities/classes, and consuming pod UIDs, readiness,
  and per-container restart counts. Capture all affected consumers.

Calculate using bytes, converting to GiB only for display:

```text
physical_used = storageMaximum - storageAvailable
usage_percent = 100 * physical_used / storageMaximum
scheduling_limit = (storageMaximum - storageReserved)
                   * storage-over-provisioning-percentage / 100
scheduling_headroom = scheduling_limit - storageScheduled
minimum_free = storageMaximum * storage-minimal-available-percentage / 100
```

Physical usage and scheduled capacity are different constraints. A disk may
have substantial free space but exceed its scheduling limit. Conversely,
snapshots may make actual replica usage exceed the volume's provisioned size.
Database/filesystem usage inside a PVC is not Longhorn's physical footprint.

If the numbers do not match known replicas, investigate read-only disk usage
through an existing host-mounted management container or approved host access.
Include orphaned replicas and other files in physical usage. Do not delete
orphan data, purge snapshots, or trim filesystems as an implicit rebalance step;
report those separately for authorization.

## 2. Plan Ordered Moves

1. Establish the current health baseline. Prefer healthy, attached volumes
   whose existing replicas are running and `RW`, with ready consumers. Resolve
   missing/failed replicas or unexpected rebuilds before migrating that volume.
2. Relieve disk pressure and scheduling-limit violations first, then improve
   physical and scheduled utilization across the whole cluster. Prioritize
   moves with meaningful benefit, often larger occupied replicas.
3. Choose a destination without a copy of the same volume. Preserve distinct
   replica nodes and zones; nodes in the same zone are not independent failure
   domains. Respect node/disk selectors, tags, data locality, and affinity.
4. Check destination eligibility and capacity for the temporary extra copy:
   scheduled bytes plus provisioned volume size must fit its scheduling limit;
   free bytes minus the expected actual replica footprint must remain above
   its minimum-free threshold, with working headroom for rebuilds and writes.
   Conservatively consider `max(volume size, actual size)` for physical space.
5. Simulate both physical usage and scheduled capacity after every proposed
   move. Account for unchanged orphan data. Order prerequisite moves to free
   capacity before larger replacements; do not rely on future deletions to
   satisfy the current destination's capacity checks.
6. Start with a modest move where practical. Migrate one replica at a time,
   including when relocating both copies of a volume. Inspect actual results
   and revise projections as data grows or snapshot usage changes.

Keep original settings and resource identities available for recovery. Explain
the plan and estimated outcome before starting; do not promise exact usage
percentages on a live system.

## 3. Rebuild Before Removing The Source

The established path for a healthy two-replica volume is temporarily requesting
three copies, directing the new copy to one destination, and removing only the
chosen source after all three are healthy. Check the installed Longhorn
version's selector and surplus-cleanup behavior before using these controls.
For other replica counts, validate the equivalent N-to-N+1 path and capacity;
never delete a sole healthy copy first.

For each move:

1. Re-read volume, replica, engine, destination disk, and consumer state.
   Verify source UID and both original copies' health. Record the exact
   original `numberOfReplicas`, `nodeSelector`, `replicaAutoBalance`, and target
   node tags; do not assume defaults.
2. Add a unique temporary node tag only to the destination. Preserve existing
   tags. For the validated empty-selector case, set the volume's `nodeSelector`
   to that tag. If existing selectors are nonempty, devise a compatible
   placement method rather than overwriting them blindly.
3. Set per-volume `replicaAutoBalance: disabled` and temporarily increase
   `numberOfReplicas` from two to three. This version-validated override prevents
   automatic surplus cleanup from choosing the wrong old copy during cutover.
   Leave the global auto-balance setting unchanged.
4. Poll live state, periodically reporting progress. Both original replica
   UIDs must remain present, running, and `RW` throughout the rebuild. The new
   replica must be on the intended node and disk. A running process alone is
   insufficient: wait for its engine mode to become `RW`, successful rebuild
   completion, healthy timestamps, no failure/deletion state, and a healthy
   volume with all three copies synchronized.
5. Restore the original selector and desired replica count while keeping the
   per-volume auto-balance override disabled for the cutover. Re-read the two
   intended survivors and verify both are still healthy `RW` copies.
6. Remove only the identified source replica resource, using a UID precondition
   where supported to avoid deleting a changed/replaced object. Never delete
   its PVC, PV, volume, pod, or files directly. Let Longhorn clean up the replica.
7. Wait for exactly the original replica count, healthy `RW` survivors on the
   intended nodes, no active rebuild, and healthy volume status. Allow node
   disk statistics to catch up after source cleanup.
8. Restore the original per-volume auto-balance setting. Remove only the unique
   temporary tag from the node's current tag list, preserving unrelated tags.
9. Verify original PVC/PV identities and sizes, workload pod identities,
   readiness, and restart counts. Proceed to the next move only after these
   checks and setting restoration succeed.

## Failure And Interruption Recovery

- Stop subsequent moves if a replica fails, a consumer becomes unhealthy,
  placement differs from the plan, or rebuild progress stalls. Inspect volume,
  engine, replica, event, and disk state before acting.
- A timeout is not authorization to remove the source. Keep original healthy
  copies until a replacement is fully synchronized. Long rebuilds may require
  extending observation, not starting another rebuild or deleting pods.
- If interrupted, rediscover current replica UIDs and engine modes before
  resuming. Do not blindly rerun a completed move or repeat a stale delete.
- On failure, clear temporary scheduling restrictions when safe, but do not
  blindly restore the lower replica count or enable surplus cleanup while
  uncertain which copies would survive. Retain extra copies and a temporary
  per-volume override if necessary; report and resolve that exact state.
- Cleanup should run on error as well as success, but preserving healthy data
  takes precedence over returning settings to defaults. Track restoration
  failures explicitly and finish safe recovery before continuing.

## 4. Final Verification

Compare fresh live state with the saved baseline:

- All volumes healthy; configured replica counts restored; every attached
  volume's replicas `RW`, with no pending rebuild, failure, eviction, or deletion.
- Expected final placement, preserving node/zone separation and all selectors.
- Original volume/PVC UIDs, PV bindings, storage classes, and capacities intact.
- Consumer pods ready with unchanged identities and restart counts, or any
  deviations explained accurately rather than attributed without evidence.
- Original node tags, volume selectors, auto-balance overrides, and global
  settings restored. Both Kyverno policy evaluations remain enabled.
- Physical free-space thresholds satisfied and scheduled capacity below each
  disk's limit. Report any pre-existing orphan data that remains.

Do not perform unrelated application changes to obtain a clean report. If
multiple Longhorn disks exist on a node, verify limits individually and label
the report rows by node/disk; aggregated totals can hide an overfull disk.

## Completion Report

Summarize completed replica moves and distinct volumes, health/continuity
checks, any remaining limitations, and temporary-setting restoration. Balance
percentages rather than bytes and distinguish scheduled allocations from
physical consumption. Use measured final values, not the plan's projections.

End the response with this table, including every node. `Usage Before` and
`Usage After` are physical usage percentages; `Free Now` and `Scheduled / Limit`
are GiB. Explain any multi-disk row labels before the table. Replace all
placeholders with current measurements; never reuse figures from an earlier run.

| Node | Usage Before | Usage After | Free Now | Scheduled / Limit |
|---|---:|---:|---:|---:|
| `<node>` | `<before>%` | `<after>%` | `<free>Gi` | `<scheduled> / <limit>Gi` |
