---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:timeChaos/2.2"
displayName: "AKS clock skew (Chaos Mesh TimeChaos)"
vertical: kubernetes
faultPath: agent
targetType: "Microsoft-AzureKubernetesServiceChaosMesh"
resourceType: "Microsoft.ContainerService/managedClusters"
capabilityName: "TimeChaos-2.2"
prerequisites:
  - "Chaos Mesh is installed in the cluster"
  - "The AKS cluster has the Microsoft-AzureKubernetesServiceChaosMesh target enabled"
  - "The workload is time sensitive: it issues or validates tokens, signs requests, or orders events by timestamp"
  - "The acceptable clock-skew tolerance of every dependency is known"
parameters:
  jsonSpec:
    mode: "one"
    selector:
      namespaces: ["<namespace>"]
      labelSelectors:
        app: "<app-label>"
    timeOffset: "-5m"
    duration: "PT3M"
steadyStateSignals:
  - "Authentication success rate at baseline"
  - "Token validation error count at baseline"
  - "Request success rate at or above the service objective"
impactSignals:
  - "Authentication or token-validation failures rise"
  - "TLS certificate validation errors appear"
  - "Event ordering anomalies appear in logs"
  - "Scheduled or cron work fires early or late"
blastRadiusControls:
  - "mode: one - skew a single pod so the rest of the fleet stays a control group"
  - "timeOffset - start small, a few minutes, well inside typical token skew tolerance"
  - "clockIds - restrict which clocks are affected where supported"
  - "duration - keep short; skewed clocks corrupt time-series data for the window"
abortConditions:
  - "Certificate validation failures affect pods that were not targeted"
  - "Data written with skewed timestamps reaches a durable store"
  - "Success rate falls below the error budget floor"
knownLimitations:
  - "Metrics emitted by the skewed pod carry skewed timestamps, so its own telemetry for the window is unreliable"
  - "Only processes started after injection reliably observe the offset in some runtimes"
  - "Skew beyond the token validity window converts this into an authentication-outage study rather than a skew-tolerance study"
dataPlaneProof:
  signal: "Authentication or token-validation error count, or an application-reported clock value"
  coverage: "partial"
---

# AKS clock skew

## The question this answers

*If one node's clock drifts, does the system detect it, or does it silently
produce wrong results?*

Clock skew is a low-frequency, high-consequence failure. It rarely causes an
outage; it causes incorrect data, which is worse, because it is discovered later.

## When this study is worth running

Run it if any of these are true. Skip it otherwise — a stateless workload with
no time-based logic will produce a null result:

- The workload issues or validates JWTs or SAS tokens
- It signs requests with a timestamp
- It orders events by timestamp across replicas
- It runs scheduled work with an interval shorter than the skew you can tolerate
- It has a lease, lock or fencing token with a time-based expiry

## Reading the result

| What you see | What it means |
|---|---|
| Auth failures rise during the window, recover after | Skew tolerance is narrower than the injected offset. Expected and useful — you now know the number. |
| Nothing changes | Tolerance exceeds the offset. Increase the offset in a follow-up study rather than concluding "immune". |
| Failures persist after the window | Something cached a token or a validation decision. Usually `high`. |
| Event ordering anomalies in logs | Distributed ordering depends on wall-clock time. This is a design finding, not a configuration one. |

## Important: the skewed pod's own telemetry is unreliable

Metrics and logs emitted by the skewed pod carry skewed timestamps for the
duration of the window. Always draw the steady-state and impact signals from an
*unskewed* source — the ingress, a sibling pod, or a control-plane metric.
`chaos-study-run` records limitation **L4** automatically when a time fault is
in the plan.

## Blast radius

`mode: one`, small offset. Skewing the whole fleet removes the control group and
makes every comparison meaningless.
