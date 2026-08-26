---
name: chaos-study-scope
description: "Frame a Chaos reliability study before anything is injected: discover live from Chaos Studio which actions are actually available for the target's region, express a falsifiable steady-state predicate, verify the delivery path is open and the parameters fit the service's own schema, then freeze and hash an auditable study plan."
---

# chaos-study-scope — decide what the study can prove

Most failed chaos experiments fail here, not during injection. They inject a
fault nothing was measuring, at a target that could not receive it, to answer a
question that could not have come back false.

This skill's job is to catch that before production is touched.

## Principles

**Ask the platform; never assume.** The list of available actions is fetched from
`Microsoft.Chaos/locations/{region}/actions` for the target's region, on every
scope. That response is authoritative: its `canonicalId`, `actionType`,
`supportedTargetTypes` and `parametersSchema` are what the plan records.

**No bundled catalogue, no fallback.** This skill ships no fault definitions. If
the actions endpoint cannot be reached — not logged in, no permission, region
unresolved — scoping stops with exit `16` and says so. It does not degrade to a
stale local list, because a stale list is how you plan a study against a fault
that does not exist.

**A steady state must be falsifiable.** `successRate >= 99.5` can be violated.
"the service is healthy" cannot. Scoping rejects the second kind.

**Check the path before promising the study.** If the resource is not onboarded
as a Chaos Studio target, or the capability for this action is not enabled, the
study cannot run. Scoping says so up front (exit `14`) instead of failing
halfway through an injection.

**Parameters are validated against the service's schema.** Not against a copy of
it. Required properties, enums and types come from the live `parametersSchema`,
so validation cannot drift from the platform.

**Freeze what was approved.** The plan is written once and hashed. The run skill
re-computes that hash; if it changed, the run refuses (exit `12`). What you
reviewed is what executes.

**Discovery is read-only.** Scoping issues only reads. Nothing here mutates
anything, which is why it is safe to scope broadly and run narrowly.

## Usage

**List what the platform offers** — start here; the action constrains the
question, and only the service knows what exists in that region today:

```powershell
./scripts/Invoke-ChaosStudyScope.ps1 -ListActions `
    -SubscriptionId $sub -ResourceGroup rg-prod -ResourceName payments-vm `
    -ResourceType 'Microsoft.Compute/virtualMachines'
```

**Scope a study:**

```powershell
./scripts/Invoke-ChaosStudyScope.ps1 `
    -SubscriptionId $sub -ResourceGroup rg-prod -ResourceName payments-vm `
    -ResourceType 'Microsoft.Compute/virtualMachines' `
    -Action 'urn:csci:microsoft:virtualMachine:shutdown/1.0.0' `
    -SteadyState 'successRate >= 99.5' `
    -SignalSource 'metrics:Availability' `
    -DurationMinutes 3 -BaselineMinutes 5 -RecoveryMinutes 5
```

`-Action` accepts the canonical URN or the action name; a partial match is
accepted only when it is unambiguous.

Useful switches:

- `-Region` — skip resource lookup and query that region's actions directly
- `-Parameters @{ ... }` — action-specific knobs, validated against the live schema
- `-SignalSource` — the evidence to collect (`metrics:` / `logs:`); no defaults
  are invented for you
- `-Hypothesis` — what you expect to happen, recorded for honesty at report time
- `-SkipDiscovery` — plan without contacting Azure. The plan then carries
  limitation `L10` and a placeholder action record marked `discovered: false`; no
  action metadata is fabricated, and the run still verifies the path.

Output is a frozen `study-plan.v1.json` plus a study id. Nothing is injected.

## What the plan records

The plan is the contract the rest of the suite reads:

| Section | Why it matters |
| --- | --- |
| `target` | exact blast radius — subscription, resource, type, region |
| `fault` | live action metadata: URN, type, target type, schema, permissions |
| `discovery` | which endpoint answered, when, and how many actions it returned |
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

Action identifiers, parameter shapes and required permissions are **not**
documented here. They are the service's to state, and restating them locally is
exactly the drift this design removes. Use `-ListActions`.

What lives locally is the method:

- `../chaos-study/references/study-method.md` — the method behind the phases
- `../chaos-study/references/report-contract.md` — what a report may claim

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Plan frozen |
| `1` | Error |
| `10` | Readiness gates failed |
| `14` | Delivery path unavailable — target or capability not enabled |
| `16` | Live action discovery unavailable — there is no fallback |

## Next

Review the plan, then run it with explicit consent:

```powershell
chaos-study-run -StudyId <studyId> -DryRun:$false -Consent '<phrase from the plan>'
```
