# Scenario: Kubernetes pod resilience

**The question:** *Does this workload survive losing replicas, and how quickly
does it return to full capacity?*

This is the first scenario to run against any Kubernetes workload. It is cheap,
it has strong data-plane proof, and its result tells you whether your
observability is good enough to interpret anything harder.

## Preconditions

Do not start until all of these are true. A study run without them produces a
result that looks meaningful and is not:

- The workload has **more than one replica**. With one replica, every result is
  "total outage", which is a configuration fact, not a finding.
- A **steady-state predicate** exists — a success rate or latency objective you
  can state as a number before you inject anything.
- At least one **data-plane signal** covers the workload. Ready replica count
  from the Kubernetes API is sufficient.

## Step 1 — Single pod failure

**Fault:** [aks-chaosmesh-pod.md](../faults/aks-chaosmesh-pod.md)
**Blast radius:** `mode: one`, one label selector, `PT2M`

**Hypothesis:** *Losing one pod does not breach the success-rate objective, and
ready replicas return to desired within 60 seconds of the fault ending.*

What you are really measuring is endpoint propagation. The pod becomes
unhealthy; how long before the load balancer stops sending it traffic? That gap
is where errors come from.

**If this fails**, stop the scenario. A workload that cannot survive one pod
failure will not produce interpretable results from anything harder. Fix the
readiness probe or the retry configuration first.

## Step 2 — Concurrent pod failure

**Fault:** [aks-chaosmesh-pod.md](../faults/aks-chaosmesh-pod.md)
**Blast radius:** `mode: fixed-percent`, `value: "50"`, `PT2M`

**Hypothesis:** *Losing half the replicas degrades latency but does not breach
the success-rate objective.*

Run this only after step 1 is clean. It tests whether the remaining replicas
have the capacity headroom to absorb the load — a different question from step 1,
and one that usually has a worse answer than teams expect.

**Compare against step 1** using `chaos-study-history`. The interesting number
is the ratio: if losing 50% of replicas causes more than 2x the latency impact
of losing one, you have a non-linear capacity curve.

## Step 3 — Resource pressure

**Fault:** [aks-chaosmesh-stress.md](../faults/aks-chaosmesh-stress.md)
**Blast radius:** `mode: one`, `cpu.load: 80`, `PT5M`

**Hypothesis:** *CPU pressure on one pod raises its latency proportionally, the
autoscaler reacts within its configured window, and no requests are lost.*

This step exists because steps 1 and 2 test *sudden* loss. Real degradation is
usually gradual. A workload can be perfect at surviving pod death and still fall
over under sustained pressure, because those exercise different mechanisms —
rescheduling versus throttling and autoscaling.

The autoscaler reaction time measured here is often the most actionable number
in the whole scenario.

## Reading the scenario as a whole

| Steps 1, 2, 3 | Interpretation |
|---|---|
| pass, pass, pass | Genuinely resilient at this replica count. Move to node-loss. |
| pass, fail, — | Insufficient capacity headroom. Raise replica count or requests. |
| pass, pass, fail | Rescheduling works; sustained-pressure handling does not. Look at HPA thresholds. |
| fail, —, — | Endpoint propagation or retry configuration. Fix before continuing. |

## What this scenario cannot tell you

- Nothing about dependencies. See
  [kubernetes-dependency-latency.md](kubernetes-dependency-latency.md).
- Nothing about node or zone loss. See
  [kubernetes-node-loss.md](kubernetes-node-loss.md).
- Nothing about behaviour under real production load, unless it was run under
  real production load. If it was not, limitation **L5** applies to every
  finding.
