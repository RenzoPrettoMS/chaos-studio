---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:dnsChaos/2.2"
displayName: "AKS DNS failure (Chaos Mesh DNSChaos)"
vertical: kubernetes
faultPath: agent
targetType: "Microsoft-AzureKubernetesServiceChaosMesh"
resourceType: "Microsoft.ContainerService/managedClusters"
capabilityName: "DNSChaos-2.2"
prerequisites:
  - "Chaos Mesh is installed in the cluster, including the DNS chaos server component"
  - "The AKS cluster has the Microsoft-AzureKubernetesServiceChaosMesh target enabled"
  - "The workload resolves at least one hostname at runtime; a workload using only IPs will show nothing"
  - "The specific hostname patterns under test are known"
parameters:
  jsonSpec:
    action: "error"
    mode: "all"
    patterns: ["<dependency-hostname>"]
    selector:
      namespaces: ["<namespace>"]
      labelSelectors:
        app: "<app-label>"
    duration: "PT2M"
steadyStateSignals:
  - "Request success rate at or above the service objective"
  - "Dependency call error count at baseline"
  - "DNS resolution error count at baseline"
impactSignals:
  - "Dependency call error count rises"
  - "Connection establishment failures rise"
  - "p95 latency rises (resolution retry before failure)"
  - "Circuit breaker opens"
blastRadiusControls:
  - "patterns - name the specific dependency hostnames, never use a bare wildcard"
  - "labelSelectors - restrict to the calling workload"
  - "mode - all is acceptable here because patterns bound the damage"
  - "duration - keep short, PT2M is usually sufficient"
abortConditions:
  - "Kubernetes API resolution failures appear (the pattern was too broad)"
  - "Success rate falls below the error budget floor"
  - "Pods begin failing readiness because the probe resolves a hostname"
knownLimitations:
  - "Application-level and libc-level DNS caching can hide the fault entirely for the duration of the TTL"
  - "A workload that resolves hostnames once at startup will not observe the fault at all"
  - "The pattern syntax matches hostnames, not IPs, so any hard-coded IP path bypasses the fault"
dataPlaneProof:
  signal: "Dependency connection error count, or DNS resolution failure count from application metrics"
  coverage: "partial"
---

# AKS DNS failure

## The question this answers

*When name resolution for a dependency fails, does the workload fail fast and
recover, or does it stay broken after DNS comes back?*

The second half is the interesting half. DNS failures are usually brief. The
outages they cause are usually not, because something cached the failure.

## `error` versus `random`

- **`action: error`** — resolution returns an error. Tests the failure path.
- **`action: random`** — resolution returns a random IP. Tests what happens when
  the workload connects successfully to the wrong place. Considerably more
  disruptive; do not use it in a first study.

## Reading the result

| What you see | What it means |
|---|---|
| Errors rise during the window, return to baseline immediately after | Healthy. Resolution is retried and not cached negatively. |
| Errors persist after the window ends | Negative caching, or a connection pool that will not re-resolve. Usually `critical`. |
| Nothing changes | Either the hostname is cached with a long TTL, or the workload resolved at startup only. Check `mechanismProven`. |
| Kubernetes API errors appear | The pattern was too broad. Abort and narrow it. |

The persistent-error case is the whole reason to run this fault. A 30-second DNS
blip that produces a 40-minute outage is a real and common pattern, and it is
invisible until you inject it.

## Why coverage is `partial`

Chaos Mesh does not export a per-pod counter of intercepted resolutions.
Proof relies on the workload's own dependency-error metrics. When the workload
does not export them, limitation **L3 — mechanism unproven** is added and
findings are capped at `confidence: low`.

## Blast radius

`patterns` must name real dependency hostnames. A bare `*` will break resolution
of `kubernetes.default.svc`, the metrics endpoint, and the image registry
simultaneously, and the study will tell you nothing except that DNS is load
bearing.
