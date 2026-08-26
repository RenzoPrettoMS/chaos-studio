# Scenario index

A **fault guide** describes one injection. A **scenario** is a question worth
answering, expressed as a small ordered set of studies.

Scenarios exist because "run pod chaos" is not a reliability question.
"Does this service survive losing a replica, and how fast does it recover?" is.

## Kubernetes scenarios

| Scenario | The question | Faults used |
|---|---|---|
| [kubernetes-pod-resilience.md](kubernetes-pod-resilience.md) | Does the workload survive losing replicas? | pod, stress |
| [kubernetes-node-loss.md](kubernetes-node-loss.md) | Does the cluster absorb losing a node? | VMSS shutdown, pod |
| [kubernetes-dependency-latency.md](kubernetes-dependency-latency.md) | Does a slow dependency degrade or destroy the service? | network, HTTP, DNS |

## How to run a scenario

Scenarios are ordered. Each study builds on the previous one's result, and a
failure at step *n* usually makes step *n+1* uninterpretable.

Run one study at a time. Seal it. Read the report. Then decide whether the next
study still asks a useful question — often the first result changes what you
want to ask next, and that is the point.

`chaos-study` runs one study end to end. To run a scenario, run `chaos-study`
once per step, then use `chaos-study-history` to compare the sealed results.

## Recommended starting point

If you have never run a study against this cluster, start with step 1 of
[kubernetes-pod-resilience.md](kubernetes-pod-resilience.md).

It is the cheapest fault, has the strongest data-plane proof, and its result
tells you whether your observability is good enough to interpret anything
harder. A pod study that comes back `Inconclusive` means the *next* thing to fix
is your signal coverage, not your resilience.
