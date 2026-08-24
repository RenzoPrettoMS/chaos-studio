# Targeted Chaos Skills & Tools — Executive Decision Summary

> **Date:** 2026-08-21 | **Audience:** Engineering leadership, architects, cross-team stakeholders | **Status:** Draft for implementation review (independent review corrections applied: Technical 86/100, Readability 91/100; re-review pending) | **Research SHA:** **`55c74c59a5eb123edecd91374be4d385407be8f0`**

## What We're Building

We are **evolving and hardening the shipped `startchaos` v0.3.0 plugin**, not replacing it with the never-merged Chaos Loop prototype. `[MAIN]` already has five skills (`start-chaos`, `create-workspace`, `setup-scenario`, `run-scenario`, `chaos-impact`) and 15 MCP tools. All 15 `@mcp.tool()` decorators are in `mcp/chaos_mcp/server.py`; `monitor.py` supplies helpers used by the three monitor wrappers.

`[NEW]` first hardens baseline contracts, runtime preflight, state/evidence durability, setup validation/exclusions, run identity, and impact telemetry. Additive targeted entry skills may then cover scope setup, inventory, availability, analysis, recommendation, execution, diagnosis, and evidence export by composing current assets. The prototype catalog and monolithic state are **not ported**; they do not exist on main.

The deterministic/model boundary remains: code evaluates; the model proposes and explains. Field decisions remain unchanged—two-sided per-leg proof, `NOT EXERCISED`, mechanism liveness, failure-mechanism classes, and evidence that survives a conversation.

Source labels used here: `[MAIN]` = research SHA above; `[PR32 PROTOTYPE]` = useful never-merged prior art; `[NEW]` = proposed work.

## What We Reuse from Main

| `[MAIN]` asset | Reuse decision |
|---|---|
| Five shipped skills and `agents/start-chaos.md` | Retain names/triggers; extend and compose, no initial replacement |
| Shared auth/ARM/LRO/RBAC/validation/state/render/report scripts | Extend existing seams; keep `STARTCHAOS_STATE_PATH` compatible |
| `chaos-impact` schema/templates/scripts/tests/offline replay | Primary telemetry/report foundation; preserve impact schema v1 and its AlertsManagement `timeRange=custom` + `customTimeRange` contract with `2023-05-01-preview` → `2018-05-05` fallback |
| `server.py`, `azure.py`, `monitor.py` | Preserve 15 names/signatures/envelopes, including canonical `chaos_refresh_recommendations` and `chaos_list_recommended_scenarios`; extend `monitor.py` for pack/App Insights/alerts and `server.py` for wrappers/identity |
| `plugin.json`, marketplace, package/docs/config | Keep registration/version surfaces synchronized; registration does not guarantee runtime tool exposure |
| `test.yml`, `release.yml`, Dependabot | Retain Pester OS matrix, pytest 3.10–3.13, ruff, build/publish/release automation |

## Architecture at a Glance

```
┌──────────────────────────────────────────────────────────────────────┐
│  Copilot CLI — eight peer skills, all user-facing, all standalone    │
│                                                                      │
│  scope-setup → inventory → availability → analyze → recommend        │
│                                       run → diagnose → evidence      │
│  (every arrow is guidance, never a handoff)                          │
└──────────────────────────────────────────────────────────────────────┘
        │ versioned artifacts keyed by scopeId / runId
        ▼
┌──────────────────────────────────────────────────────────────────────┐
│  [NEW] durable mirror outside repo/session temp                      │
│  imports and preserves [MAIN] startchaos-state.json                  │
└──────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Deterministic layer                                                 │
│  MCP tools (Python): scope, workspace, capability map, eligibility,  │
│    execution, fault-landed proof, build attestation                  │
│  Monitor tools: fault-window pack, App Insights, alert instances     │
│  Pure policy libraries: scoring, correlation, blast-radius, verdict  │
│  PowerShell: impact report, RBAC remediation, offline replay harness │
└──────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────────┐
│  Azure: Chaos Studio v2 workspaces · v1 capability catalog ·         │
│  Resource Graph · Monitor / App Insights / Log Analytics ·           │
│  Activity Log · AlertsManagement · deployment history                │
└──────────────────────────────────────────────────────────────────────┘
```

- **Evolution, not replacement.** Targeted entries compose the current five skills and 15 tools.
- **D14 — the model never computes an outcome.** It emits proposals; deterministic code evaluates and persists them.
- **Additive and backward compatible.** Keep five skill names/triggers, 15 tool names/signatures/envelopes, current state files, impact v1, and offline replay. Future aliases last at least one minor.
- **Writes are explicit.** Workspace/configuration/recommendation-refresh writes are disclosed; fault execution requires the strongest human-issued approval.
- **Every claim carries provenance.** Each artifact records source, confidence and freshness; missing data is `null` with a caveat, never a fabricated zero.

## Decisions Made

### Skill Architecture

| ID | Decision | Choice / rationale |
|---|---|---|
| **D1** | Workflow shape | Eight additive peer entries compose current skills; no initial replacement |
| **D2** | Scenario source | Do not port the prototype catalog; use shipped recommendation refresh/list names plus service-derived availability; assume no distinct `/evaluate` endpoint |
| **D6** | Skill/tool contract | Declare tools and check host-visible inventory; manifest registration alone is insufficient (F5) |
| **D7** | Evidence durability | Mirror compatible current state to an external per-user store; main does not already have one |
| **D15** | Analysis vs recommendation / pure logic | Keep distinct; scoring, correlation and blast radius remain pure libraries, not MCP tools |
| **D16** | Scope identity | Stable declaration ID plus resolution fingerprint |

### Evidence and Verdicts

| ID | Decision | Choice / rationale |
|---|---|---|
| **D3** | Fault-landed proof | Two-sided per dependency leg: ARM entity state plus independent data-plane disruption |
| **D3/CS-5** | Fault semantics | `observedEffect` is verdict input; `candidateMechanism` is narrative only and carries confidence/rejected mechanisms |
| **D3/D17** | Verdict vocabulary | `CONFIRMED` / `REFUTED` / `NOT EXERCISED`; control-only, starvation, no baseline, or unproven changed path cannot masquerade as resilience |
| **D4** | Build identity | Version endpoint → artifact digest → windowed behavioral fingerprint; record rung/caveats |
| **D5** | Telemetry | One normalized pre/during/post pack composed from current collectors; Python alert querying initially matches the shipped paired time-range parameters and API fallback |
| **D8** | Failure tracking | Record failure-mechanism classes with occurrences, not merely attempted fixes |
| **D9** | Mechanism liveness | Probe/observability claims require a second predicate proving the mechanism executed |
| **D10** | Advisor | De-emphasize: optional context and possible reverse destination, never a gate |
| **D11** | Consumer coupling | Score and ship probe-accuracy work jointly with its consumer |

### Security and Execution Safety

| ID | Decision | Choice / rationale |
|---|---|---|
| **D12** | Validation | Preserve main's strict validate/fix/revalidate gate; do not weaken it |
| **D12/D18** | Configuration drift | Frozen configuration compared at execute |
| **D13** | Permission remediation | Targeted grants first; broad current tool retained behind explicit consent |
| **D18** | Approval | Human-issued, bound, expiring, single-use, server-verified token |
| **FR-16** | Availability tiers | Tier A discloses the shipped recommendation-refresh POST; Tier B configuration probe requires consent |
| **NFR-8** | Repository/secret hygiene | Local read-only source and redacted evidence; key material unreachable |

### Delivery and Compatibility

| Trace | Decision | Choice / rationale |
|---|---|---|
| **NFR-10** | Migration | Incremental v0.x hardening; no current deprecation initially; aliases at least one minor |
| **NFR-9** | API versions | Pins are currently in `azure.py`, `monitor.py`, `server.py`, and PowerShell `Constants.ps1`; consolidate only behind baseline tests |
| **NFR-1** | Testing | Preserve current Pester/pytest/ruff/replay matrices and add F1–F15 fixtures |
| **G11/CS-1–CS-10** | Product defects | Keep service issues separate from plugin implementation; runtime/service availability stays open until verified |

## Blocking Items

| Item | Status | Owner |
|------|--------|-------|
| Fault-semantics coverage bar — every fault type reachable by a top-20 scenario needs a documented data-plane probe before the suite is usable | 🔴 Blocked (needs acceptance-bar decision and a curation owner) | Chaos Studio engineering |
| Minimum telemetry/SLO contract required before execution is permitted | 🔴 Blocked (proposal drafted, needs sign-off) | Chaos Studio engineering + Azure Monitor partners |
| Read-only permission-preflight at workspace or scenario scope (would eliminate the opt-in write tier entirely) | 🔴 Blocked on service capability | Chaos Studio service team |
| Per-leg data-plane disruption attestation | 🟡 Planned: plugin workaround is `[NEW]`; service capability remains separate | Plugin + Chaos Studio service teams |
| Non-null action identity and concurrency-safe run-ID recovery | 🟡 Main has partial fallbacks; hardening is planned | Plugin + Chaos Studio service teams |
| Preview operations, cancel/retention semantics, runtime MCP exposure, current PyPI publication | 🔴 Open until target-runtime verification | Plugin/service owners |
| Source-repository selection and authorisation policy | 🟡 In Progress (local paths agreed; remote-read policy undecided) | Copilot plugin owners |
| Foundations — schemas, durable evidence store, API-version consolidation, tool reconciliation | 🟢 Ready | Copilot plugin owners |

## Follow-up Design Items

| Item | Priority | Description |
|------|----------|-------------|
| Empirical fault-semantics verification | High | Upgrade heuristic data-plane probes to verified via live probe runs; requires a dedicated test subscription and ongoing funded engineering time |
| Dependency-topology edge quality bar | High | Decide whether an observed telemetry edge is required before a dependency-fault recommendation may rank in the top three |
| Recovering the unexplained telemetry query failure | Medium | One of three recorded query failures could not be verified; the plan currently encodes only the two confirmed causes |
| API-version/runtime operation verification | Medium | Source proves the pin, not deployed operation availability; exercise target environments before moving |
| Evidence store location and retention defaults | Medium | Per-OS default directory, retention window, and purge behaviour need finalising |
| Multi-resource metric fan-out tool | Low | Deferred; revisit when a scope with many metric-bearing resources demonstrates the cost, behind the existing pack interface |
| Reverse Advisor flow | Low | Emitting chaos-proven findings as Advisor recommendation candidates — a partner-team conversation, no work scheduled |
| Retiring the broad permission auto-fix tool | Low | Retain one release behind explicit consent, then re-evaluate on usage telemetry |
| Merging analysis and recommendation | Low | Revisit after the first usability round if the extra artifact hop proves burdensome |

## Design Documentation

| Document | Key Content |
|----------|-------------|
| [Plan Document](targeted-chaos-skills.plan.md) | Full solution design, field evidence, skill contracts, API shapes, scoring rules, testing strategy, and phased implementation plan |
