---
name: chaos-study
description: "Run a complete Chaos reliability study against an AKS cluster: frame a falsifiable steady-state question, freeze a plan, inject a fault with explicit consent, collect before/during/after evidence, and produce a self-contained HTML report. Start here for 'is my service actually resilient to X?' questions."
---

# chaos-study — reliability studies, end to end

Chaos engineering is an experiment, not a stunt. This skill runs the experiment:
it asks a question that can be proven **wrong**, injects a fault, and reports
what the evidence actually showed.

## The question this suite answers

> Does **`<steady state>`** hold when I inject **`<fault>`** into **`<target>`**?

If you cannot phrase the goal that way, stop and reframe it. "Test resilience"
is not a study — there is no way for it to fail, so it cannot teach you anything.

## Principles

**A study is a falsifiable claim.** Every study needs a steady-state predicate
that is measurable before injection and could plausibly break during it.

**Evidence beats vibes.** A verdict is only as good as the signals behind it. If
a signal was not collected, the report says *not measured* — never `0`, never a
plausible-looking guess. Absent evidence is reported as absent.

**Nothing is injected without consent.** `-DryRun` defaults to `$true`. Arming a
study takes both `-DryRun:$false` and typing back the exact phrase the plan
prints. There is no flag that skips this.

**Blast radius is bounded before it is armed.** Namespace, selector, and duration
are frozen into the plan and hashed. If the plan changed after you approved it,
the run refuses rather than injecting something you did not review.

**A clean result is not automatically good news.** If the fault never actually
reached the target, "steady state held" means nothing. The report says
*Inconclusive* rather than claiming a pass it cannot support.

## The five skills

This is a suite, not a monolith. Use the front door unless you need one phase.

| Skill | Owns |
| --- | --- |
| **chaos-study** | chains the phases below; the default entry point |
| **chaos-study-scope** | frames the question, checks readiness, freezes the plan |
| **chaos-study-run** | consent, injection, evidence collection |
| **chaos-study-report** | interpretation, findings, the HTML report |
| **chaos-study-history** | list, compare, and re-run past studies |

Each phase persists its own output, so a chain that fails partway can be resumed
from that phase — you never have to restart from scratch.

## Usage

**1. See what can be studied.** Fault choice determines what the study can prove,
so start here rather than guessing a fault name:

```powershell
./scripts/Invoke-ChaosStudy.ps1 -ListFaults
```

Each fault reports its **proof strength**. `strong` means a clean run is
meaningful; `weak` means treat a clean run as inconclusive.

**2. Plan and preview.** This injects nothing:

```powershell
./scripts/Invoke-ChaosStudy.ps1 `
    -SubscriptionId $sub -ResourceGroup rg-prod -ClusterName aks-prod `
    -Namespace payments -Selector app=api `
    -Fault aks-chaosmesh-pod -SteadyState 'successRate >= 99.5'
```

Read the preview. It shows the exact blast radius, the windows, and the request
that would be sent.

**3. Arm it.** Only after the preview matches your intent:

```powershell
./scripts/Invoke-ChaosStudy.ps1 ... -DryRun:$false -Consent '<phrase from the preview>'
```

The run collects baseline, injects, collects during, waits out recovery, then
reports and seals the study.

## Reading the verdict

| Verdict | Means |
| --- | --- |
| **Steady state held** | The fault landed and the objective survived it |
| **Degraded but recovered** | Breached during injection, recovered afterwards |
| **Steady state breached** | Breached and still breached after recovery |
| **Inconclusive** | The fault could not be proven to have landed |

Severity follows recovery, not drama: a breach that never recovers is `critical`;
the same breach that self-heals is `medium`.

## Before you run against production

Scoping checks the target is healthy first. A study on an already-broken target
teaches nothing, so readiness failure (exit `10`) is a real answer, not a gate to
bypass. Likewise exit `14` means the fault path is not open — the agent or
capability is missing, and injecting anyway would produce a false pass.

## Progressive discovery

Do not memorise fault identifiers or JSON specs. They live next to the evidence
requirements that make them interpretable:

- **`references/faults/_index.md`** — which fault answers which question
- **`references/faults/<name>.md`** — prerequisites, blast radius, proof strength
- **`references/scenarios/_index.md`** — ready-made Kubernetes studies
- **`references/study-method.md`** — the five-phase method and why it is split
- **`references/report-contract.md`** — what the report may and may not claim

Kubernetes is the first vertical. The method is deliberately fault-agnostic so
further verticals slot in as new guides rather than new scripts.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Error |
| `10` | Readiness gates failed — target is already unhealthy |
| `11` | Consent declined or phrase mismatch |
| `12` | Plan changed after it was frozen |
| `13` | Study already sealed |
| `14` | Fault path unavailable |
| `15` | Studies not comparable |

## Notes

- Core is `az` / Azure Resource Manager. There is no SRE Agent dependency and no
  required MCP dependency.
- Studies persist under a dated store, so later chats can list, compare, and
  re-run them. Sealed studies are immutable — re-testing scopes a **new** study
  rather than overwriting the record.
- Parameterised faults (`-Parameters`) are planned via `chaos-study-scope`
  directly; hashtables cannot cross the chained entry point.
