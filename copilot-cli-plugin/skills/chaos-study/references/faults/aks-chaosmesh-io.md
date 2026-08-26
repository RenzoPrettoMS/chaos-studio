---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:IOChaos/2.2"
displayName: "AKS I/O fault (Chaos Mesh IOChaos)"
vertical: kubernetes
faultPath: agent
targetType: "Microsoft-AzureKubernetesServiceChaosMesh"
resourceType: "Microsoft.ContainerService/managedClusters"
capabilityName: "IOChaos-2.2"
prerequisites:
  - "Chaos Mesh is installed in the cluster"
  - "The AKS cluster has the Microsoft-AzureKubernetesServiceChaosMesh target enabled"
  - "The workload performs file I/O on a known path; a stateless workload that only logs will show nothing"
  - "The volume mount path under test is known"
parameters:
  jsonSpec:
    action: "latency"
    mode: "one"
    selector:
      namespaces: ["<namespace>"]
      labelSelectors:
        app: "<app-label>"
    volumePath: "/data"
    path: "/data/**/*"
    delay: "100ms"
    percent: 50
    duration: "PT3M"
steadyStateSignals:
  - "p95 latency within the service objective"
  - "Disk read and write latency at baseline"
  - "Error rate at baseline"
impactSignals:
  - "p95 latency rises on I/O-bound paths"
  - "Read or write error count rises (fault action)"
  - "Readiness probe failures if the probe touches disk"
blastRadiusControls:
  - "path - restrict to the specific directory under test, never /"
  - "percent - fraction of operations affected, start at 50 or lower"
  - "mode: one - affect a single pod"
  - "volumePath - must match an actual mount, not the container root"
  - "duration - keep the first study at or under PT3M"
abortConditions:
  - "Data-integrity errors appear in application logs"
  - "Readiness probes fail on pods that were not targeted"
  - "Write errors on a path that is not the study target"
knownLimitations:
  - "IOChaos operates via a sidecar injection mechanism; pods must be restarted for it to attach, which is itself a disruption"
  - "Only the declared volumePath is affected, so I/O to other mounts or to the container filesystem is untouched"
  - "Filesystem caching can absorb injected latency entirely on read-heavy workloads with a warm cache"
dataPlaneProof:
  signal: "Application-level I/O latency or error counters, or storage-layer latency metrics for the mounted volume"
  coverage: "partial"
---

# AKS I/O fault

## The question this answers

*When the disk gets slow or starts returning errors, does the workload surface a
clean failure, or does it hang?*

Storage is the dependency people forget is a dependency. A workload with a
correct HTTP timeout and no I/O timeout will hang indefinitely on a slow mount.

## Latency versus fault

- **`action: latency`** delays I/O operations. Tests whether the workload has an
  I/O timeout at all, and whether slow disk propagates to request latency.
- **`action: fault`** returns errors. Tests error handling on the write path.

Run `latency` first. Most workloads have no I/O timeout, and discovering that is
usually the finding.

## Reading the result

| What you see | What it means |
|---|---|
| Request latency rises proportionally | I/O is on the request path and is not buffered. Expected for a database. |
| Nothing changes | Either the cache absorbed it, or the path selector missed. Check `mechanismProven` before concluding "resilient". |
| Readiness probe fails | The probe touches disk. That is a finding on its own — probes should not depend on the thing they are checking. |
| Workload hangs and does not recover after the window | No I/O timeout. This is usually `critical`. |

## Why coverage is `partial`

There is no universal in-cluster signal that proves injected I/O latency
reached the application. Proof depends on the workload exporting its own I/O
metrics, or on storage-layer latency being visible. When neither exists, the
study proceeds but adds limitation **L3 — mechanism unproven**, and findings are
capped at `confidence: low`.

## Blast radius

Never set `path` to `/` or `**/*` without a `volumePath` that names a real
mount. A study that slows the container root filesystem will disrupt logging,
the runtime, and the probe path all at once, and nothing about the result will
be attributable.
