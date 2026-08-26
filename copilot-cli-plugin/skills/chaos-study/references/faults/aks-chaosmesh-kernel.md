---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:kernelChaos/2.2"
displayName: "AKS kernel fault injection (Chaos Mesh KernelChaos)"
vertical: kubernetes
faultPath: agent
targetType: "Microsoft-AzureKubernetesServiceChaosMesh"
resourceType: "Microsoft.ContainerService/managedClusters"
capabilityName: "KernelChaos-2.2"
prerequisites:
  - "Chaos Mesh is installed in the cluster with the kernel chaos component enabled"
  - "The AKS cluster has the Microsoft-AzureKubernetesServiceChaosMesh target enabled"
  - "The node pool runs a Linux kernel with BPF error injection available"
  - "The cluster is NOT production; this fault operates below the container boundary"
parameters:
  jsonSpec:
    mode: "one"
    selector:
      namespaces: ["<namespace>"]
      labelSelectors:
        app: "<app-label>"
    failKernRequest:
      callchain:
        - funcname: "__x64_sys_mount"
      failtype: 0
      probability: 10
      times: 10
    duration: "PT2M"
steadyStateSignals:
  - "Pod ready and passing probes"
  - "Node condition Ready"
  - "Request success rate at or above the service objective"
impactSignals:
  - "Syscall failures surfaced in application logs"
  - "Pod restart or crash-loop"
  - "Node condition degradation"
blastRadiusControls:
  - "probability - start at 10 or lower, never 100"
  - "times - bound the total number of injected failures"
  - "callchain - name one specific syscall, never a broad chain"
  - "mode: one - a single pod"
  - "duration - the shortest window that produces a signal, typically PT2M"
abortConditions:
  - "Any node leaves the Ready condition"
  - "Pods outside the selector restart"
  - "kubelet or container runtime errors appear in node logs"
knownLimitations:
  - "This fault operates below the container isolation boundary, so blast radius cannot be fully guaranteed by the selector"
  - "Kernel version differences across node pools change which callchains are injectable, so results are not portable between clusters"
  - "A failed injection is often indistinguishable from an unsupported kernel, making null results ambiguous"
dataPlaneProof:
  signal: "Application or node log entries showing the injected syscall failure"
  coverage: "weak"
---

# AKS kernel fault injection

## The question this answers

*When a syscall fails — not the application, the syscall — does the workload
surface a comprehensible error, or does it corrupt state?*

This is the most invasive fault in the Kubernetes slice and the one with the
narrowest legitimate use.

## Read this before using it

**Do not run this against production.** Kernel-level injection operates below
the container isolation boundary. The pod selector limits *which pod's* syscalls
are targeted, but the failure is injected in a kernel shared with every other
pod on that node. The blast radius is the node, not the pod.

Run it when you are validating a specific, known syscall failure path — for
example, reproducing a mount failure or an allocation failure seen in an
incident. Do not run it as a general "does the workload survive chaos" study.
The other seven faults in this vertical answer that question with far better
attribution.

## Reading the result

| What you see | What it means |
|---|---|
| The targeted syscall fails and the application logs a clean error | The error path works. That is the finding. |
| The application crashes without a log line | Unhandled syscall failure. Usually `high` or `critical`. |
| Nothing happens | Ambiguous. Either the callchain is not injectable on this kernel, or the syscall was never called. Do not read this as a pass. |
| Unrelated pods restart | Abort immediately. The blast radius escaped the selector. |

## Why coverage is `weak`

There is no reliable signal that distinguishes "injection succeeded and the
syscall was never called" from "injection was not supported by this kernel".
Because of that, `chaos-study-report` will not set `mechanismProven: true` for
this fault unless an explicit application-level log or metric confirms the
failure, and it always adds limitation **L3 — mechanism unproven** on a null
result.

## Blast radius

Low `probability`, bounded `times`, one named `funcname`, short duration,
non-production cluster. Every one of those is required, not advisory.
