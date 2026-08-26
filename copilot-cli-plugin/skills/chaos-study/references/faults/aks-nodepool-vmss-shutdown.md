---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:virtualMachineScaleSet:shutdown/2.0"
displayName: "AKS node pool shutdown (VMSS shutdown)"
vertical: kubernetes
faultPath: service-direct
targetType: "Microsoft-VirtualMachineScaleSet"
resourceType: "Microsoft.Compute/virtualMachineScaleSets"
capabilityName: "Shutdown-2.0"
prerequisites:
  - "The node pool VMSS (in the MC_ managed resource group) has the Microsoft-VirtualMachineScaleSet target enabled"
  - "The experiment identity holds Virtual Machine Contributor on the VMSS"
  - "The cluster has more than one node pool, or the pool has more than one node"
  - "Pod disruption budgets are configured, otherwise this tests nothing but raw restart time"
parameters:
  jsonSpec:
    abruptShutdown: false
    duration: "PT10M"
    instances: ["<instance-id>"]
steadyStateSignals:
  - "All nodes in Ready condition"
  - "Ready replica count equals desired for the workloads under test"
  - "Request success rate at or above the service objective"
impactSignals:
  - "Node count drops"
  - "Pods enter Pending while rescheduling"
  - "Ready replica count drops"
  - "Cluster autoscaler scales out a replacement"
  - "p95 latency rises during rescheduling"
blastRadiusControls:
  - "instances - name specific instance ids, never shut down the whole scale set"
  - "abruptShutdown: false - graceful shutdown allows drain semantics"
  - "duration - must exceed expected reschedule time or you measure the wrong thing"
  - "Target a non-system node pool where possible"
abortConditions:
  - "System pods (CoreDNS, metrics-server) become unschedulable"
  - "Ready replicas reach zero for any workload"
  - "Cluster autoscaler fails to provision a replacement within the window"
knownLimitations:
  - "This is a coarse fault: it tests scheduling, capacity, PDBs and autoscaling simultaneously, so a failure is not attributable to one of them without follow-up"
  - "Recovery time depends on VM provisioning time, which is outside the cluster's control and varies by region and SKU"
  - "Shutting down a node hosting system components produces cluster-wide effects that swamp the workload signal"
dataPlaneProof:
  signal: "Node count and node Ready condition from the Kubernetes API, or kube_node_status_condition from managed Prometheus"
  coverage: "strong"
---

# AKS node pool shutdown

## The question this answers

*When we lose a node — or a whole node pool — does the cluster reschedule the
workload fast enough, and is there capacity to land it?*

This is an infrastructure study, not a workload study. It tests the cluster's
ability to absorb capacity loss.

## What it actually tests, all at once

This fault exercises four mechanisms simultaneously:

1. Pod disruption budgets during drain
2. Scheduler capacity on the remaining nodes
3. Cluster autoscaler reaction time
4. The workload's own tolerance of being rescheduled

That bundling is why it is a coarse fault. A failure needs a follow-up study
with `aks-chaosmesh-pod` to attribute it. Run the pod study *first*, so that
when this one fails you already know whether the workload itself is the problem.

## Graceful versus abrupt

`abruptShutdown: false` performs a graceful shutdown, which allows node drain
and respects pod disruption budgets. This is the correct first study — it tests
the path Azure actually uses for planned maintenance.

`abruptShutdown: true` simulates hardware failure. There is no drain and PDBs
are not honoured. Only run it after the graceful study passes, because
otherwise you cannot tell whether a failure was caused by the shutdown mode or
by an underlying capacity problem.

## Reading the result

| What you see | What it means |
|---|---|
| Pods reschedule, brief latency bump, success rate holds | Healthy. Note the reschedule time. |
| Pods stay Pending | No capacity on remaining nodes and the autoscaler was too slow or is disabled. Usually `critical`. |
| PDB blocks the drain | The PDB is stricter than the available capacity. That is a real finding, not an error. |
| Success rate drops to zero for one workload | All its replicas were on the shut-down node. Anti-affinity is missing. |

The last row is the most common finding and the most easily fixed.

## Blast radius

Name specific `instances`. Shutting down an entire scale set is not a study; it
is an outage with extra paperwork. And never target the system node pool in a
first study — losing CoreDNS makes every other signal in the study unreadable.
