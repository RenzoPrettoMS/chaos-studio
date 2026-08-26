---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:networkSecurityGroup:securityRule/1.0"
displayName: "Network security group rule (network path cut)"
vertical: kubernetes
faultPath: service-direct
targetType: "Microsoft-NetworkSecurityGroup"
resourceType: "Microsoft.Network/networkSecurityGroups"
capabilityName: "SecurityRule-1.0"
prerequisites:
  - "The NSG protecting the cluster subnet has the Microsoft-NetworkSecurityGroup target enabled"
  - "The experiment identity holds Network Contributor on the NSG"
  - "The destination address range of the dependency to be blocked is known"
  - "The NSG has priority space free in the range the rule will occupy"
parameters:
  jsonSpec:
    action: "Deny"
    destinationAddresses: ["<dependency-cidr>"]
    destinationPortRanges: ["443"]
    direction: "Outbound"
    priority: 100
    protocol: "Tcp"
    ruleName: "chaos-study-block-dependency"
    sourceAddresses: ["*"]
    duration: "PT5M"
steadyStateSignals:
  - "Dependency call success rate at baseline"
  - "Request success rate at or above the service objective"
  - "Connection error count at baseline"
impactSignals:
  - "Dependency connection timeouts rise"
  - "Circuit breaker opens"
  - "Request error rate rises"
  - "Retry count rises"
blastRadiusControls:
  - "destinationAddresses - name the dependency CIDR, never use *"
  - "destinationPortRanges - name the specific port"
  - "direction: Outbound - do not block inbound in a first study"
  - "priority - choose a value that does not shadow an existing allow rule you depend on"
  - "duration - the rule is removed at the end of the window; keep it short"
abortConditions:
  - "Kubernetes API or image registry connectivity is lost"
  - "Node Ready condition degrades"
  - "Success rate falls below the error budget floor"
knownLimitations:
  - "NSG rules apply to the whole subnet, so every workload on that subnet is affected, not only the one under test"
  - "Existing established connections may survive the rule, so the fault can take effect gradually rather than instantly"
  - "Private Endpoint and Service Endpoint traffic may bypass the rule depending on the network configuration"
dataPlaneProof:
  signal: "Dependency connection error or timeout count from application metrics, or NSG flow logs for the blocked rule"
  coverage: "partial"
---

# Network security group rule

## The question this answers

*When the network path to a dependency is cut entirely — not slow, gone — does
the workload fail fast and recover cleanly when the path returns?*

This is the bluntest dependency fault available and the only one that works
without any in-cluster agent.

## When to use this instead of a Chaos Mesh fault

Use it when:

- Chaos Mesh is not installed and cannot be installed
- The dependency is reached over TLS, which `httpChaos` cannot intercept
- You want to test the path at the infrastructure layer, including anything that
  bypasses the application's own client library

Use `aks-chaosmesh-network` instead when Chaos Mesh is available. It gives a far
tighter blast radius: pod-scoped rather than subnet-scoped.

## The subnet blast radius is the real constraint

An NSG rule applies to every network interface in the subnet. If the cluster
shares a subnet with other workloads, they are all affected. `chaos-study-scope`
will warn when the target NSG is attached to a subnet containing resources
outside the study scope, and adds limitation **L6 — concurrency** because those
other workloads can confound the result.

## Reading the result

| What you see | What it means |
|---|---|
| Errors rise sharply, circuit breaker opens, recovery is immediate after the window | Healthy. Fast failure and clean recovery. |
| Errors rise slowly over a minute | Established connections survived the rule. The effective fault start is later than the window start; check the timing in the run record. |
| Recovery is slow after the rule is removed | Connection pool is not re-establishing, or negative caching. Usually `high`. |
| Nothing changes | The traffic is not taking the path you blocked. Private Endpoint or Service Endpoint routing is the usual cause. Check `mechanismProven`. |

## Blast radius

Specific `destinationAddresses`, specific `destinationPortRanges`, `Outbound`
only. A `Deny * *` rule will cut the Kubernetes API, the image registry and the
metrics pipeline at once, and the study will produce no interpretable signal
because the observability path is part of what you broke.
