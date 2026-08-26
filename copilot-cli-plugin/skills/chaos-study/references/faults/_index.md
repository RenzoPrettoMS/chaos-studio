# Fault guide index

This is the routing table. `chaos-study-scope` reads it to choose a fault, then
loads **one** guide. Nothing else in the suite hard-codes a fault URN — that is
what keeps every `SKILL.md` short and keeps fault knowledge in one place.

## How to use this table

1. Start from the **question** you want answered, not from the fault name.
2. Load the single guide in the last column.
3. The guide's front matter is the contract: URN, capability, prerequisites,
   parameters, signals, blast-radius controls, abort conditions, and — crucially
   — whether a data-plane proof signal exists for it.

If a guide's `dataPlaneProof.coverage` is `none`, the study cannot prove the
fault reached the workload, and the resulting findings are capped at
`confidence: low`. Prefer a fault with real proof coverage when one answers the
same question.

## Kubernetes (AKS) — the first vertical slice

| Question you are asking | Fault | Guide |
|---|---|---|
| Does the workload survive losing pods? | Pod kill / failure | [aks-chaosmesh-pod.md](aks-chaosmesh-pod.md) |
| Does it tolerate latency or loss between pods? | Network delay / loss / partition | [aks-chaosmesh-network.md](aks-chaosmesh-network.md) |
| Does it degrade gracefully under CPU or memory pressure? | Stress | [aks-chaosmesh-stress.md](aks-chaosmesh-stress.md) |
| Does it handle slow or failing disk I/O? | I/O fault | [aks-chaosmesh-io.md](aks-chaosmesh-io.md) |
| Does it survive DNS resolution failure? | DNS chaos | [aks-chaosmesh-dns.md](aks-chaosmesh-dns.md) |
| Does it handle HTTP faults from a dependency? | HTTP chaos | [aks-chaosmesh-http.md](aks-chaosmesh-http.md) |
| Is it sensitive to clock skew? | Time chaos | [aks-chaosmesh-time.md](aks-chaosmesh-time.md) |
| Does it survive kernel-level failure injection? | Kernel chaos | [aks-chaosmesh-kernel.md](aks-chaosmesh-kernel.md) |
| Does it survive losing a whole node pool? | VMSS shutdown | [aks-nodepool-vmss-shutdown.md](aks-nodepool-vmss-shutdown.md) |
| Does it survive the network path being cut? | NSG rule | [aks-nsg-rule.md](aks-nsg-rule.md) |

## Choosing between agent-based and service-direct faults

The Chaos Mesh faults run **inside** the cluster. They require the Chaos Mesh
prerequisite to be installed and the AKS Chaos Mesh target enabled. They give
the sharpest data-plane proof, because the effect is observable in-cluster.

`aks-nodepool-vmss-shutdown` and `aks-nsg-rule` are **service-direct**: Azure
acts on the resource, no in-cluster agent is needed. They are coarser and their
blast radius is larger, but they answer infrastructure-level questions the
in-cluster faults cannot.

Pick the narrowest fault that answers the question. A node-pool shutdown used to
test pod resilience is not a sharper test; it is a less interpretable one.

## Guide front matter fields

| Field | Meaning |
|---|---|
| `guideSchemaVersion` | schema version of the guide itself |
| `faultUrn` | the Chaos Studio fault URN, versioned |
| `displayName` | human name used in the report |
| `vertical` | the slice this belongs to (`kubernetes`) |
| `faultPath` | `agent` or `service-direct` |
| `targetType` | Chaos Studio target type to enable |
| `resourceType` | ARM resource type the target attaches to |
| `capabilityName` | Chaos Studio capability name, versioned |
| `prerequisites` | what must exist before this can run |
| `parameters.jsonSpec` | the parameter contract for the fault |
| `steadyStateSignals` | what "healthy" looks like before injection |
| `impactSignals` | what would change if the fault lands |
| `blastRadiusControls` | the knobs that bound the damage |
| `abortConditions` | when to stop early |
| `knownLimitations` | what this fault cannot tell you |
| `dataPlaneProof` | the signal proving the fault reached the workload |

## Scenarios

Guides describe a single fault. **Scenarios** compose them into a question worth
asking. See [scenarios/_index.md](../scenarios/_index.md).
