---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:podChaos/2.2"
displayName: "AKS pod failure (Chaos Mesh PodChaos)"
vertical: kubernetes
faultPath: agent
targetType: "Microsoft-AzureKubernetesServiceChaosMesh"
resourceType: "Microsoft.ContainerService/managedClusters"
capabilityName: "PodChaos-2.2"
prerequisites:
  - "Chaos Mesh is installed in the cluster (namespace chaos-testing by default)"
  - "The AKS cluster has the Microsoft-AzureKubernetesServiceChaosMesh target enabled"
  - "The experiment identity holds Azure Kubernetes Service Cluster User Role on the cluster"
  - "The workload under test has more than one replica, otherwise the result is trivially a full outage"
parameters:
  jsonSpec:
    action: "pod-failure"
    mode: "one"
    value: ""
    duration: "PT2M"
    selector:
      namespaces: ["<namespace>"]
      labelSelectors:
        app: "<app-label>"
steadyStateSignals:
  - "Ready replica count equals desired replica count"
  - "Request success rate at or above the service objective"
  - "p95 latency within the service objective"
impactSignals:
  - "Ready replica count drops below desired"
  - "Pod restart count increases"
  - "Request error rate rises"
  - "p95 latency rises"
blastRadiusControls:
  - "mode: one - affect exactly one pod"
  - "mode: fixed-percent with a small value - bound the fraction affected"
  - "labelSelectors - restrict to the workload under test"
  - "namespaces - never leave the target namespace"
  - "duration - keep the first study at or under PT5M"
abortConditions:
  - "Ready replicas reach zero"
  - "Error rate exceeds twice the steady-state baseline"
  - "An unrelated production alert fires in the window"
knownLimitations:
  - "Killing a pod tests the scheduler and the client's retry path together; a clean result does not isolate which one saved you"
  - "A workload with a single replica will always fail this; that is not a finding, it is a configuration fact"
  - "Recovery time is bounded by image pull time, which varies with node cache state"
dataPlaneProof:
  signal: "Ready replica count from the Kubernetes API, or kube_pod_status_ready from managed Prometheus"
  coverage: "strong"
---

# AKS pod failure

## The question this answers

*If a pod of this workload disappears, does the service stay up, and how long
does it take to get back to full capacity?*

This is the first study to run against any Kubernetes workload. It is the
cheapest fault with the sharpest signal.

## What actually happens

Chaos Mesh, running in the cluster, selects pods matching the selector and makes
them fail for the duration. `pod-failure` keeps the pod object but makes the
container unavailable; `pod-kill` deletes the pod outright.

Prefer `pod-failure` for a first study. `pod-kill` conflates two effects —
unavailability *and* rescheduling — and makes recovery time harder to attribute.

## Reading the result

| What you see | What it means |
|---|---|
| Ready replicas dip, error rate flat | Healthy. Load balancing removed the pod before clients noticed. |
| Ready replicas dip, error rate spikes briefly | Readiness probe or endpoint propagation is slower than your retry budget. |
| Error rate stays elevated after recovery | Clients are not recovering. Look at connection pooling and DNS caching. |
| Nothing changes at all | Check `mechanismProven`. A flat result with no data-plane proof usually means the selector matched nothing. |

That last row matters. A study that "passed" because the fault never landed is
the most dangerous possible outcome, which is why `mechanismProven` is a
first-class field and not a footnote.

## Blast radius

Start with `mode: one` and a label selector that names exactly one workload.
Widen only after a narrow study has produced a clean, explainable result.

Never run this with an empty `labelSelectors` map. An empty selector matches the
whole namespace.
