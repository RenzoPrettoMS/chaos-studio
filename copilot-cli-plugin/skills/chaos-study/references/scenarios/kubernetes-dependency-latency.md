# Scenario: Kubernetes dependency latency

**The question:** *When a dependency gets slow or starts failing, does this
service degrade gracefully, or does the dependency take it down?*

Slow dependencies cause more outages than dead ones. A dead dependency fails
fast and trips a circuit breaker. A slow one exhausts connection pools, fills
queues, and takes the caller with it.

## Preconditions

- The workload **calls at least one dependency over the network**. A
  self-contained workload will produce a null result.
- The **client timeout** is known. Every delay value in this scenario is chosen
  relative to it, not to a round number.
- The **retry and circuit-breaker configuration** is known, or the study is
  partly about discovering it.
- Current **p95 latency** is known, so amplification is measurable.

## Step 1 — Latency below the timeout

**Fault:** [aks-chaosmesh-network.md](../faults/aks-chaosmesh-network.md)
**Blast radius:** `delay.latency` at roughly one third of the client timeout,
`direction: to`, explicit dependency target, `PT3M`

**Hypothesis:** *Added latency below the client timeout raises our own p95 by
approximately the injected amount and does not affect the success rate.*

The number to watch is **amplification**: observed p95 delta divided by injected
delay. A ratio near 1.0 is healthy pass-through. A ratio of 5 or 10 means
something is multiplying the delay — usually serialised calls or retries — and
that is the finding.

## Step 2 — Latency at the timeout

**Fault:** [aks-chaosmesh-network.md](../faults/aks-chaosmesh-network.md)
**Blast radius:** `delay.latency` at roughly the client timeout, `PT3M`

**Hypothesis:** *Latency at the timeout boundary produces timeouts that are
retried successfully, the circuit breaker opens if the error rate crosses its
threshold, and the success rate stays within the error budget.*

This is where timeout, retry and circuit-breaker configuration actually get
exercised. Most services have never run this and most discover that at least one
of the three is misconfigured.

Watch for **retry storms**: if retry count rises far faster than error count,
you are amplifying load against an already-struggling dependency.

## Step 3 — Explicit HTTP failure

**Fault:** [aks-chaosmesh-http.md](../faults/aks-chaosmesh-http.md)
**Blast radius:** `abort: true`, one API path prefix, one port, `PT2M`

**Hypothesis:** *Connection aborts from the dependency are retried, the circuit
breaker opens, and the service sheds load cleanly rather than queueing.*

Step 2 tests slow. This tests broken. They exercise different code paths —
timeout handling versus error handling — and a service can be good at one and
bad at the other.

Use this step instead of step 2 if the dependency is reached over TLS;
`httpChaos` cannot intercept encrypted traffic, so in that case substitute
[aks-nsg-rule.md](../faults/aks-nsg-rule.md) to cut the path entirely.

## Step 4 — Resolution failure

**Fault:** [aks-chaosmesh-dns.md](../faults/aks-chaosmesh-dns.md)
**Blast radius:** explicit `patterns` naming the dependency hostname, `PT2M`

**Hypothesis:** *DNS failure for the dependency produces errors during the
window and full recovery immediately after it.*

The second half is what matters. A brief DNS failure that produces a prolonged
outage — because something cached the failure or a connection pool will not
re-resolve — is a real and common pattern, and it is invisible until injected.

## Reading the scenario as a whole

| Result pattern | Interpretation |
|---|---|
| Amplification ~1.0 across steps 1-2 | Healthy pass-through. Latency budget is honest. |
| Amplification high in step 1 | Serialised or retried calls. Look at the call graph. |
| Retry count >> error count in step 2 | Retry storm risk. Cap retries and add jitter. |
| Circuit breaker never opens | Threshold is above the injected error rate, or it is not configured. |
| Step 4 errors persist after the window | Negative DNS caching or stale connection pool. Usually `critical`. |

## What this scenario cannot tell you

- Nothing about the **dependency's own** resilience. This tests the caller.
- Injected delay is applied **per packet**, so effective request latency can
  exceed the configured value on multi-round-trip protocols. Treat the injected
  value as a floor.
- If the workload caches dependency responses, a clean result may reflect the
  cache rather than resilience. Limitation **L2** applies unless cache hit rate
  was measured in the same window.
