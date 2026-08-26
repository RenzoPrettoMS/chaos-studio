---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:stressChaos/2.2"
displayName: "AKS CPU or memory stress (Chaos Mesh StressChaos)"
vertical: kubernetes
faultPath: agent
targetType: "Microsoft-AzureKubernetesServiceChaosMesh"
resourceType: "Microsoft.ContainerService/managedClusters"
capabilityName: "StressChaos-2.2"
prerequisites:
  - "Chaos Mesh is installed in the cluster"
  - "The AKS cluster has the Microsoft-AzureKubernetesServiceChaosMesh target enabled"
  - "The workload has resource requests and limits set, otherwise the result is not interpretable"
  - "Horizontal pod autoscaler behaviour is known, since it will react during the study"
parameters:
  jsonSpec:
    mode: "one"
    selector:
      namespaces: ["<namespace>"]
      labelSelectors:
        app: "<app-label>"
    stressors:
      cpu:
        workers: 1
        load: 80
    duration: "PT5M"
steadyStateSignals:
  - "Container CPU utilisation below the request"
  - "Container memory working set below the limit"
  - "p95 latency within the service objective"
  - "No OOMKilled events"
impactSignals:
  - "CPU throttling seconds rise"
  - "p95 latency rises"
  - "Pod restart count rises (memory stress reaching the limit)"
  - "Horizontal pod autoscaler scales out"
blastRadiusControls:
  - "mode: one - stress exactly one pod"
  - "load - percentage of a single core, keep below 100 for a first study"
  - "workers - number of stressor threads, start at 1"
  - "memory size - keep well below the container limit unless OOM is the question"
  - "duration - long enough for the autoscaler to react, typically PT5M"
abortConditions:
  - "OOMKilled on a pod that was not the stress target"
  - "Node-level pressure conditions appear (MemoryPressure, DiskPressure)"
  - "Success rate falls below the error budget floor"
knownLimitations:
  - "Stress applied inside a container competes with the container's own limits; a low limit makes the fault mostly self-limiting"
  - "Memory stress that reaches the limit results in OOMKill, which converts this into a pod-failure study with extra steps"
  - "Node-level effects can spill to co-tenant pods on the same node even when mode is one"
dataPlaneProof:
  signal: "container_cpu_usage_seconds_total or container_memory_working_set_bytes delta between the pre and during windows"
  coverage: "strong"
---

# AKS CPU or memory stress

## The question this answers

*When this workload is starved of CPU or memory, does it degrade proportionally
and recover, or does it fall off a cliff?*

Resource pressure is the most common real-world failure mode and the one most
often untested, because it is uncomfortable to simulate in production.

## CPU versus memory

They fail differently and should be separate studies:

- **CPU stress** produces *throttling*. The workload gets slower. Recovery is
  immediate when the stress stops. The interesting question is whether latency
  rises linearly or exponentially.
- **Memory stress** produces *OOMKill*. The workload dies. Recovery requires a
  restart. The interesting question is whether the restart is clean.

Do not combine them in a first study. A combined result cannot be attributed.

## Reading the result

| What you see | What it means |
|---|---|
| Latency rises, throttling rises, success rate flat | Healthy degradation. Requests are slower, not lost. |
| Latency rises non-linearly | You are past a queueing threshold. Capacity headroom is thinner than it looks. |
| HPA scales out and latency recovers | Autoscaling works. Note how long it took — that is the real number. |
| OOMKilled during CPU stress | Memory limit is too close to steady-state usage. Separate finding. |
| No throttling observed | Check `mechanismProven`. Either the selector missed, or there is no CPU limit set at all. |

The autoscaler reaction time is often the most actionable output of this study.
It is rarely what teams assume it is.

## Blast radius

`mode: one`. Stress on a single pod is enough to characterise the workload's
response curve. Widening to `all` before understanding the single-pod result
tests the cluster, not the workload.
