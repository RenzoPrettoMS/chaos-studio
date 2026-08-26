---
name: chaos-study-scope
description: "Frame a Chaos reliability study before anything is injected: pick a fault that can actually prove something, express a falsifiable steady-state predicate, verify the fault path is open and the target is healthy, then freeze and hash an auditable study plan."
---

# chaos-study-scope — decide what the study can prove

Most failed chaos experiments fail here, not during injection. They inject a
fault nothing was measuring, at a target that was already unhealthy, to answer a
question that could not have come back false.

This skill's job is to catch that before production is touched.

## Principles

**A steady state must be falsifiable.** `successRate >= 99.5` can be violated.
"the service is healthy" cannot. Scoping rejects the second kind.

**Choose the fault for its proof strength, not its name.** Each fault guide
declares whether a clean result is meaningful. A `weak` fault that silently never
lands produces a "pass" that means nothing — so the strength is recorded in the
plan and resurfaces in the report as a limitation.

**Check the path before promising the study.** If the Chaos Mesh agent is absent
or the capability is not enabled, the study cannot run. Scoping says so up front
(exit `14`) instead of failing halfway through an injection.

**A sick target cannot be studied.** Readiness gates confirm pods are ready and
not crash-looping *before* injection. Failing them (exit `10`) is a finding about
your cluster, not an obstacle to route around.

**Freeze what was approved.** The plan is written once and hashed. The run skill
re-computes that hash; if it changed, the run refuses (exit `12`). What you
reviewed is what executes.

**Discovery is read-only.** Scoping issues only reads. Nothing here mutates
anything, which is why it is safe to scope broadly and run narrowly.

## Usage

**List what can be studied** — start here; fault choice constrains the question:

```powershell
./scripts/Invoke-ChaosStudyScope.ps1 -ListFaults
```

**Scope a study:**

```powershell
./scripts/Invoke-ChaosStudyScope.ps1 `
    -SubscriptionId $sub -ResourceGroup rg-prod -ClusterName aks-prod `
    -Namespace payments -Selector app=api `
    -Fault aks-chaosmesh-pod `
    -SteadyState 'successRate >= 99.5' `
    -DurationMinutes 3 -BaselineMinutes 5 -RecoveryMinutes 5
```

Useful switches:

- `-Parameters @{ ... }` — fault-specific knobs; the guide lists valid keys
- `-SignalSource` — extra evidence sources beyond the defaults
- `-Hypothesis` — what you expect to happen, recorded for honesty at report time
- `-SkipDiscovery` — plan offline without probing the cluster (plan only; the run
  will still verify the path before injecting)

Output is a frozen `study-plan.v1.json` plus a study id. Nothing is injected.

## What the plan records

The plan is the contract the rest of the suite reads:

| Section | Why it matters |
| --- | --- |
| `target` | exact blast radius — subscription, cluster, namespace, selector |
| `fault` | which guide, its URN, and its proof strength |
| `question` | the steady-state predicate, parsed and normalised |
| `windows` | baseline / inject / recovery minutes |
| `signals` | what evidence must be collected for the verdict to mean anything |
| `readiness` | gate results and any limitation codes they imply |
| `planHash` | integrity seal checked before injection |

## Choosing windows

Baseline exists to establish what "normal" looked like *today*, not last week.
Recovery exists to distinguish a transient dip from real damage — without it, a
system that never recovers looks identical to one that recovers instantly.

Injection windows of three minutes or less are recorded as limitation `L7`: too
short to distinguish resilience from luck.

## Progressive discovery

Fault identifiers and their JSON specs deliberately live in the guides, not in
this file, so the prerequisites and blast radius stay attached to them:

- `../chaos-study/references/faults/_index.md` — routing table
- `../chaos-study/references/faults/<name>.md` — one guide per fault
- `../chaos-study/references/scenarios/_index.md` — ready-made studies
- `../chaos-study/references/study-method.md` — the method behind the phases

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Plan frozen |
| `1` | Error |
| `10` | Readiness gates failed |
| `14` | Fault path unavailable — agent or capability missing |

## Next

Review the plan, then run it with explicit consent:

```powershell
chaos-study-run -StudyId <studyId> -DryRun:$false -Consent '<phrase from the plan>'
```
