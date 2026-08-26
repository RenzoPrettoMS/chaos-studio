# Scenario: Kubernetes node loss

**The question:** *When the cluster loses a node, does the workload reschedule
fast enough, and is there capacity to land it?*

This is an infrastructure scenario. It tests the cluster's ability to absorb
capacity loss, which is a different property from the workload's ability to
survive pod loss.

## Preconditions

- [kubernetes-pod-resilience.md](kubernetes-pod-resilience.md) step 1 has
  **passed**. Without that, a failure here cannot be attributed to the node loss
  rather than to the workload.
- The cluster has **more than one node** in the target pool, or more than one
  pool.
- **Pod disruption budgets** are configured. Without them, a graceful drain
  behaves identically to an abrupt one and the study tests less than you think.
- The **cluster autoscaler** configuration is known, including whether it is
  enabled at all.

## Step 1 — Graceful node shutdown

**Fault:** [aks-nodepool-vmss-shutdown.md](../faults/aks-nodepool-vmss-shutdown.md)
**Blast radius:** one named instance, `abruptShutdown: false`, `PT10M`

**Hypothesis:** *Losing one node gracefully causes pods to reschedule within the
PDB constraints, and the success-rate objective is never breached.*

Graceful shutdown is the path Azure uses for planned maintenance, so this study
tests something that will genuinely happen to you.

Watch two numbers: **time to reschedule** (how long pods stay Pending) and
**time to ready** (how long until they serve traffic). They are different, and
the second one is what customers experience.

## Step 2 — Attribute the failure, if there was one

If step 1 failed, do **not** go to step 3. Run
[aks-chaosmesh-pod.md](../faults/aks-chaosmesh-pod.md) at
`mode: fixed-percent, value: "50"` instead.

Node shutdown bundles four mechanisms — PDBs, scheduler capacity, autoscaler,
and workload tolerance. A pod study at the same replica fraction isolates the
last one. If the pod study passes and the node study failed, the problem is
cluster capacity or autoscaling, not the workload.

This attribution step is the reason the scenario exists rather than a single
fault guide.

## Step 3 — Abrupt node loss

**Fault:** [aks-nodepool-vmss-shutdown.md](../faults/aks-nodepool-vmss-shutdown.md)
**Blast radius:** one named instance, `abruptShutdown: true`, `PT10M`

**Hypothesis:** *Losing one node abruptly breaches the success-rate objective
briefly, and recovery completes within the node-replacement window.*

This simulates hardware failure. There is no drain and PDBs are not honoured.
Expect a worse result than step 1 — that is the point. What matters is whether
the *shape* of the failure is acceptable: a brief breach that self-heals, or a
sustained one that needs intervention.

Run this only after step 1 is clean, otherwise a failure cannot be attributed to
the shutdown mode.

## Anti-affinity is the finding to look for

The single most common result of this scenario is discovering that all replicas
of a workload were scheduled onto the same node. The workload had three
replicas, the node died, and availability went to zero.

`podAntiAffinity` or `topologySpreadConstraints` fixes it, and this scenario is
usually the cheapest way to find out you need them.

## What this scenario cannot tell you

- Nothing about **zone** loss. A single-node study does not exercise
  zone-redundant scheduling.
- Recovery time depends on **VM provisioning time**, which varies by region and
  SKU and is outside the cluster's control. Treat it as a range, not a number.
- If the target node hosted system components (CoreDNS, metrics-server), the
  cluster-wide effects swamp the workload signal and limitation **L6** applies.
