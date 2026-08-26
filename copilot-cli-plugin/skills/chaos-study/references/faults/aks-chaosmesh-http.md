---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:httpChaos/2.2"
displayName: "AKS HTTP fault (Chaos Mesh HTTPChaos)"
vertical: kubernetes
faultPath: agent
targetType: "Microsoft-AzureKubernetesServiceChaosMesh"
resourceType: "Microsoft.ContainerService/managedClusters"
capabilityName: "HTTPChaos-2.2"
prerequisites:
  - "Chaos Mesh is installed in the cluster"
  - "The AKS cluster has the Microsoft-AzureKubernetesServiceChaosMesh target enabled"
  - "The traffic under test is plaintext HTTP on a known port; TLS traffic cannot be intercepted"
  - "The target port and path are known"
parameters:
  jsonSpec:
    mode: "all"
    selector:
      namespaces: ["<namespace>"]
      labelSelectors:
        app: "<app-label>"
    target: "Request"
    port: 8080
    path: "/api/*"
    abort: true
    duration: "PT2M"
steadyStateSignals:
  - "Request success rate at or above the service objective"
  - "p95 latency within the service objective"
  - "Retry count at baseline"
impactSignals:
  - "5xx or connection-abort count rises"
  - "Retry count rises"
  - "Circuit breaker state changes"
  - "p95 latency rises (when using delay rather than abort)"
blastRadiusControls:
  - "path - restrict to a single API prefix, never /*"
  - "port - name the specific service port"
  - "target: Request or Response - choose one direction"
  - "labelSelectors - restrict to the workload under test"
  - "duration - keep short, PT2M is usually sufficient"
abortConditions:
  - "Success rate falls below the error budget floor"
  - "Health or readiness endpoints begin failing (the path was too broad)"
  - "Retry storms cause upstream saturation"
knownLimitations:
  - "HTTPS traffic cannot be intercepted; only plaintext HTTP on the declared port is affected"
  - "HTTP/2 multiplexed connections may behave differently from HTTP/1.1 under abort"
  - "The fault applies at the pod network level, so it affects all clients of that pod, not a chosen subset"
dataPlaneProof:
  signal: "HTTP status-code distribution or connection-abort count from application or ingress metrics"
  coverage: "strong"
---

# AKS HTTP fault

## The question this answers

*When a dependency returns errors or hangs at the HTTP layer, does the caller's
retry, timeout and circuit-breaker configuration behave the way the design
document says it does?*

This is the fault that tests resilience *configuration* rather than
infrastructure. Most services have retry and circuit-breaker settings that have
never been exercised.

## `abort` versus `delay` versus `replace`

- **`abort: true`** — the connection is cut. Tests the fast-failure path.
- **`delay`** — the response is held. Tests timeouts. Closest to a real
  degraded dependency.
- **`replace`** — status code or body is rewritten. Tests handling of a specific
  error contract, for example a 429 or a 503.

For a first study use `abort`. It produces the clearest signal and the least
ambiguous recovery.

## Reading the result

| What you see | What it means |
|---|---|
| Errors rise, retries rise, success rate holds | Retries are working. Note the retry count — if it is very high, you are close to a retry storm. |
| Errors rise, success rate drops one-for-one | No retry, or retries are disabled for this path. |
| Retry count rises far above the error count | Retry amplification. A dependency blip will become a dependency outage. Usually `high`. |
| Circuit breaker never opens | Either it is not configured, or its threshold is above the injected error rate. Both are findings. |

Retry amplification is the finding to look for. A 3x retry on a 3-hop call path
is a 27x load multiplier against a struggling dependency.

## Blast radius

Set `path` to a specific API prefix. Setting it to `/*` will also intercept
`/healthz` and `/readyz`, which causes the pod to be removed from the endpoint
list mid-study and destroys the attribution of every other signal.
