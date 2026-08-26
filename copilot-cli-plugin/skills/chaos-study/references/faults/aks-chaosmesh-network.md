---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:networkChaos/2.2"
displayName: "AKS network delay or loss (Chaos Mesh NetworkChaos)"
vertical: kubernetes
faultPath: agent
targetType: "Microsoft-AzureKubernetesServiceChaosMesh"
resourceType: "Microsoft.ContainerService/managedClusters"
capabilityName: "NetworkChaos-2.2"
prerequisites:
  - "Chaos Mesh is installed in the cluster"
  - "The AKS cluster has the Microsoft-AzureKubernetesServiceChaosMesh target enabled"
  - "The workload calls a dependency over the network, otherwise there is nothing to delay"
  - "You know the current p95 latency, so the injected delay can be chosen relative to it"
parameters:
  jsonSpec:
    action: "delay"
    mode: "all"
    selector:
      namespaces: ["<namespace>"]
      labelSelectors:
        app: "<app-label>"
    delay:
      latency: "200ms"
      correlation: "0"
      jitter: "0ms"
    direction: "to"
    duration: "PT3M"
steadyStateSignals:
  - "p95 latency within the service objective"
  - "Request success rate at or above the service objective"
  - "Dependency call timeout count at baseline"
impactSignals:
  - "p95 and p99 latency rise by approximately the injected delay"
  - "Timeout count rises"
  - "Retry count rises"
  - "Queue depth or in-flight request count rises"
blastRadiusControls:
  - "direction: to - delay only outbound traffic"
  - "externalTargets or target selector - delay only the dependency under test"
  - "labelSelectors - restrict to the calling workload"
  - "latency - start at roughly one third of the client timeout"
  - "duration - keep the first study at or under PT5M"
abortConditions:
  - "Success rate falls below the error budget floor"
  - "Latency exceeds the client timeout for more than one minute"
  - "Upstream queue depth grows without bound"
knownLimitations:
  - "Injected delay is applied per packet, so effective request latency can exceed the configured value on multi-round-trip protocols"
  - "TCP retransmission can mask small loss values, making low loss percentages look like no effect"
  - "Without a target selector, all outbound traffic is affected, including traffic to the Kubernetes API"
dataPlaneProof:
  signal: "Observed p95 latency delta between the pre and during windows"
  coverage: "strong"
---

# AKS network delay or loss

## The question this answers

*When a dependency gets slow — not down, slow — does this workload degrade
gracefully, or does it collapse?*

Slow dependencies cause more outages than dead ones. A dead dependency fails
fast and trips a circuit breaker. A slow one exhausts connection pools, fills
queues, and takes the caller down with it.

## Choosing the delay

Pick the delay relative to the client's timeout, not to a round number:

| Delay | What it tests |
|---|---|
| ~1/3 of the client timeout | Does latency propagate to your own p95? |
| ~1x the client timeout | Do timeouts, retries and circuit breakers behave? |
| ~3x the client timeout | Does the caller shed load, or queue until it dies? |

Start at the first row. The third row is a load-shedding study and should be run
only after the first two are understood.

## Reading the result

| What you see | What it means |
|---|---|
| p95 rises by roughly the injected delay, success rate flat | Healthy pass-through. The delay is absorbed. |
| p95 rises far more than the injected delay | Amplification — usually retries or serialised calls. Worth a finding. |
| Success rate drops before the timeout is reached | Connection pool exhaustion, not timeout. Different fix. |
| Latency unchanged | Check `mechanismProven`. The selector or direction is probably wrong. |

Latency amplification is the most valuable finding this fault produces. A 200ms
injection producing a 2s p95 tells you retries are multiplying, and it tells you
before a real dependency does.

## Blast radius

`direction: to` with an explicit dependency target. Without a target selector
you are also delaying traffic to the Kubernetes API server, which will produce
readiness-probe noise that confounds the result.
