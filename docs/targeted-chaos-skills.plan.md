# Azure Chaos Reliability Study — Solution Design and Implementation Plan

| | |
|---|---|
| **Repository** | `microsoft/chaos-studio` |
| **Component** | `copilot-cli-plugin/` (plugin `startchaos`); `copilot-cli-plugin/mcp/chaos_mcp` (optional MCP adapter `chaos-studio`) |
| **Status** | **Approved for implementation — Revision 6, final review pass.** Independently reviewed twice; every blocker from both passes is fixed and recorded in Appendix A, and the final pass re-verified each correction against the working tree rather than against the previous draft. All ID namespaces closed: F1–F15, P1–P9, G1–G12, N1–N9, FR-1–FR-22 + FR-7a, NFR-1–NFR-12, D1–D20, ALT-1–ALT-9, CS-1–CS-12, L1–L9, Q1–Q14, EPIC-001–EPIC-016. |
| **Audience** | Chaos Studio engineering, Copilot plugin owners, AKS + Azure Monitor partners |
| **Research baseline** | **`55c74c59a5eb123edecd91374be4d385407be8f0`** (`origin/main`) plus the local branch `renzopretto-microsoft-ground-targeted-chaos-plan` at `4befd5e` and the EPIC-003 working tree that was uncommitted at the time of planning and is now landed at `283cb61` |
| **Date** | 2026-08-24 |
| **Supersedes** | Revision 5 of this document (the "eight targeted peer skills" design) and PR #32 / `renzopretto-microsoft-add-chaos-loop-plugin` (the chaos-loop controller) |

---

## How to Read This Document

**Source labels.** Claims about **existing code** are always labelled; unlabelled prose in §Proposed Design, §Detailed Design and §Implementation Plan describes proposed work and is `[NEW]` by default.

- **`[MAIN]`** — proved from `55c74c59a5eb123edecd91374be4d385407be8f0`.
- **`[E1]` / `[E2]` / `[E3]`** — implemented on the local branch: EPIC-001 (`5257c2a`), EPIC-002 (`4befd5e`), EPIC-003 (`283cb61`; described below as an uncommitted working tree at planning time, landed in Phase 0). These are *real code that exists on this machine*, not proposals.
- **`[PR32]`** — the never-merged chaos-loop prototype. **Replaced, not extended** (see §Migration and Disposition).
- **`[NEW]`** — proposed work, stated explicitly where it sits next to existing code.

**Disposition vocabulary.** Every existing asset is classified exactly once as **RETAINED** (kept as-is), **RESHAPED** (kept, contract or role changes), **DEFERRED** (kept on disk, not on the near-term path, not deleted), or **REMOVED** (deleted or replaced). §Migration and Disposition is the single authoritative table.

**ID namespaces.**

| Prefix | Meaning | Defined in |
|---|---|---|
| **F1–F15** | Field evidence from a live engagement | §Background → Field evidence |
| **P1–P9** | Problems addressed | §Problem Statement |
| **G1–G12** / **N1–N9** | Goals / Non-Goals | §Goals and Non-Goals |
| **FR-1–FR-22** (plus **FR-7a**) / **NFR-1–NFR-12** | Functional / Non-functional requirements | §Requirements |
| **D1–D20** | Design decisions | §Proposed Design → Design Decisions |
| **ALT-1–ALT-9** | Alternatives evaluated | §Alternatives Considered |
| **CS-1–CS-12** | Chaos Studio **product/service** issues — filed, not fixed here | §Chaos Studio Product Issues |
| **L1–L9** | Report limitation classes | §Detailed Design → Findings derivation |
| **Q1–Q14** | Open questions with a stated lean | §Open Questions |
| **EPIC-001–EPIC-016** / **E\<n\>-T\<n\>** | Epics and their tasks | §Implementation Plan |

**Contents**

1. [Executive Summary](#executive-summary)
2. [Background](#background)
3. [Problem Statement](#problem-statement)
4. [Goals and Non-Goals](#goals-and-non-goals)
5. [Requirements](#requirements)
6. [Proposed Design](#proposed-design)
7. [Detailed Design](#detailed-design)
8. [Chaos Studio Product Issues](#chaos-studio-product-issues)
9. [Alternatives Considered](#alternatives-considered)
10. [Dependencies](#dependencies)
11. [Impact Analysis](#impact-analysis)
12. [Security Considerations](#security-considerations)
13. [Risks and Mitigations](#risks-and-mitigations)
14. [Open Questions](#open-questions)
15. [Migration and Disposition](#migration-and-disposition)
16. [Implementation Phases](#implementation-phases)
17. [Files Affected](#files-affected)
18. [Implementation Plan](#implementation-plan)
19. [References](#references)
20. [Appendix A: Revision History](#appendix-a-revision-history)

---

## Executive Summary

We are building an **opinionated Azure Chaos reliability study experience** on top of the shipped `startchaos` Copilot CLI plugin. A *study* is a single, named, dated, reproducible unit of work: pick a scope, form a hypothesis, run a small number of real Chaos Studio faults inside a bounded window, measure against a captured steady-state baseline, and produce a **self-contained HTML report** with the tests run, dated evidence, prioritized findings, stated limitations and concrete remediation guidance. Study results are written **once, immutably, outside the repository and outside session-temporary state**, so a later conversation — with no memory of the first — can list previous studies, compare two of them, and rerun one.

The product is built **directly over `az chaos`**. It is not an SRE-Agent-specific wrapper, it does not require an MCP server, and it is not the `[PR32]` chaos-loop controller. It is also **not one monolithic skill**: it is a small suite of five composable skills with one obvious entry point (`chaos-study`) and four focused supporting skills covering discovery/analysis, execution/monitoring, reporting, and comparison/rerun. Every user-facing `SKILL.md` — the five new ones and the five shipped ones — stays principle-led and is capped at **under 200 lines** by a CI test, reaching scenario- and fault-specific detail through progressive discovery into `references/chaos/**`. Every deterministic or safety-critical behaviour — validation gates, consent, blast-radius resolution, window arithmetic, redaction, atomic writes, report rendering — lives in reusable PowerShell scripts, not in prompt text.

**Kubernetes reliability study is the first vertical slice.** The fault and scenario guidance structure is designed to be extensible so additional verticals and newly shipped Kubernetes faults are additive reference files, not code changes.

Substantially all of the delivered `[E1]`/`[E2]`/`[E3]` work is retained: lifecycle scripts and `az chaos` wrapper, the strict validate/fix/revalidate gate, consent gates, blast-radius rendering, the durable evidence store with redaction and atomic revisioned writes, the nine v1 artifact schemas, and the Pester/pytest/ruff test matrices. What changes is **shape, not substance**: eight speculative peer skills collapse into five real ones, MCP moves from required to optional, the durable evidence store gains an immutable dated study layer, and the deliverable becomes a single self-contained HTML file carrying an executive summary, dated evidence, prioritized findings, mandatory limitations and per-finding remediation (FR-16 – FR-19).

---

## Background

### Current state

#### `[MAIN]` — shipped plugin at `55c74c5`

`startchaos` is version **0.3.0** in `copilot-cli-plugin/plugin.json`, `copilot-cli-plugin/mcp/pyproject.toml` and `.github/plugin/marketplace.json`. It ships five skills — `start-chaos`, `create-workspace`, `setup-scenario`, `run-scenario`, `chaos-impact` — plus shared PowerShell libraries, an impact schema/report with an offline replay harness, and 15 MCP tools.

**The plugin already drives the Chaos Studio v2 workspace/scenario CLI surface.** Verified call sites:

| Command | Call site |
|---|---|
| `az chaos workspace create` | `skills/create-workspace/scripts/Invoke-CreateWorkspace.ps1:69` |
| `az chaos workspace show` | `scripts/Invoke-AzChaos.ps1:31` |
| `az chaos workspace show-evaluation` | `skills/setup-scenario/scripts/Invoke-SetupScenario.ps1:55,65` |
| `az chaos workspace refresh-recommendation` | `Invoke-SetupScenario.ps1:64` |
| `az chaos scenario list` | `Invoke-SetupScenario.ps1:82` |
| `az chaos scenario config create` | `Invoke-SetupScenario.ps1:271` |
| `az chaos scenario config validate` / `show-validation` | `scripts/Validate-AndFix.ps1:243,245` |
| `az chaos scenario config fix-permissions` / `show-permission-fix` | `Validate-AndFix.ps1:334,357` |
| `az chaos scenario run start --skip-validation --no-wait` | `skills/run-scenario/scripts/Invoke-RunScenario.ps1:103–109` |
| `az chaos scenario run show` / `run list` | `Invoke-RunScenario.ps1:158,132` |

All chaos calls route through `scripts/Invoke-AzChaos.ps1` (`copilot-cli-plugin/scripts/Invoke-AzChaos.ps1:99` builds `@('chaos') + $ChaosArgs`). `agents/start-chaos.md` forbids ad-hoc `az chaos` / `az rest` from skill prompt text. **This is exactly the "built directly over `az chaos`" posture the product now requires — it already exists and is the single most valuable asset to keep.**

#### `[E1]` — EPIC-001, commit `5257c2a`, "Baseline contracts, tests, and runtime preflight"

- `mcp/chaos_mcp/apiversions.py` (51 lines) — all Python ARM api-version pins consolidated; a lint test asserts no pin is dead and no literal escapes the module.
- `mcp/tests/test_lifecycle_contract.py` (844 lines) and `mcp/tests/test_tool_manifest.py` (318 lines) — the previously untested ten lifecycle tools now have recorded coverage; `FROZEN_SKILLS` pins real normalised description strings for all five skills.
- `scripts/Preflight.ps1` (152 lines) — `Get-PreflightFailurePrefix`, `Get-SkillRequiredTools`, `Test-RequiredTools`, `Assert-RequiredTools`. Reads the **host-visible** tool inventory; never introspects the server.
- `requiredTools:` front-matter added to all five `SKILL.md` files; `skills/start-chaos/tests/Preflight.Tests.ps1` (194 lines) pins the contract in Pester.
- `mcp/pyproject.toml` — `jsonschema` promoted to a hard test dependency.
- Gate on this machine: pytest 104 passed, ruff clean, Pester 112 passed / 0 failed.

#### `[E2]` — EPIC-002, commit `4befd5e`, "Compatible state and durable evidence"

- `mcp/chaos_mcp/evidence.py` (870 lines) — a durable store at `$CHAOS_EVIDENCE_ROOT/<scopeHash>/<runId>/{artifacts,raw,rendered}` with three load-bearing properties: **path canonicalization** (absolute/UNC/`..`/symlink-escape all rejected), a **key denylist** (`$CHAOS_KEY_DIR` unreachable), and **redaction on write and on read** by key name and by value shape (bearer, JWT, hex ≥32, base64 ≥40). Atomic temp-file + `os.replace` under an exclusive lock, with a monotonic revision counter and lost-update detection. Env: `CHAOS_EVIDENCE_ROOT`, `CHAOS_KEY_DIR`, `CHAOS_EVIDENCE_RETENTION_DAYS` (default 90), `CHAOS_EVIDENCE_DISABLED`.
- `scripts/State.ps1` (+419/−26) — `Get-EvidenceRoot`, `Get-EvidenceScopeHash`, `Save-StateToEvidence`, `Mirror-State`, `Import-State`; the PowerShell redaction lists mirror the Python ones. `$env:STARTCHAOS_STATE_PATH` remains the source of truth and is unchanged.
- Nine v1 artifact schemas in `copilot-cli-plugin/schemas/`: `availability`, `diagnosis`, `evidence-bundle`, `hypotheses`, `inventory`, `mechanism-ledger`, `recommendations`, `run-record`, `scope-setup`. All share the envelope `artifactSchemaVersion, artifactType, scopeId, runId, generatedAt, provenance, warnings` plus one payload key.
- Three MCP tools added (`chaos_evidence_put` / `_get` / `_list`) taking the registry from 15 to 18.
- `references/chaos/evidence-contract.md` (180 lines), `references/chaos/verdict-matrix.md` (64 lines).
- `mcp/tests/test_evidence.py` (830 lines), `skills/start-chaos/tests/State.Tests.ps1` (337 lines).
- Gate: pytest 193 passed / 1 skipped, ruff clean.

#### `[E3]` — EPIC-003, commit `283cb61`, "Validation blockers, blast radius, consent" (uncommitted at planning time; landed in Phase 0)

- `scripts/Render.ps1` (**+224 lines on the pre-existing 214-line `[MAIN]` file; 438 lines on the working tree**) — adds `Resolve-BlastRadius` and `Write-BlastRadiusCard` beside the existing `Write-Card`, `Write-Table`, `Write-Error-Card`. No ANSI; Markdown for CLI rendering.
- `scripts/Validate-AndFix.ps1` (+250/−9) — `Test-StructuredValidationError`, `ConvertTo-ValidationBlocker`, `Build-RoleAssignmentRemediation`, full validate → fix → revalidate loop, and the **broad-fix consent gate** (`$env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX`, setup exit code 4).
- `scripts/Rbac.ps1` (+74) — `Build-TargetedGrantProposal`, a pure function producing minimum-scope `az role assignment create` commands from normalised blockers, mirrored by `build_targeted_grant_proposal()` in `server.py`.
- `references/chaos/blast-radius.md` (198 lines; untracked at planning time, tracked in `283cb61`) — include/exclude precedence (empty include = all in scope; exclude always wins), the Candidate/Include/Exclude/Affected/Leg/Starved vocabulary, and the load-bearing honesty note: **`resourceTargeting` is advisory and is never transmitted to the service — `az chaos scenario config create` accepts no include/exclude.**
- New Pester suites: `skills/setup-scenario/tests/{BlastRadius,PermissionBlockers,SetupExitContract}.Tests.ps1`, `skills/run-scenario/tests/PreExecuteGate.Tests.ps1`.
- `server.py` (+188) and `mcp/tests/test_lifecycle_contract.py` (+259) — normalised blockers and the targeted-grant proposal surfaced on `chaos_validate_scenario_configuration`, with recorded coverage.
- `skills/setup-scenario/SKILL.md` (+70) and `skills/run-scenario/SKILL.md` (+38) — the growth that motivates **P2** and **D3**.
- `skills/setup-scenario/scripts/Invoke-SetupScenario.ps1` (+88/−…) — wires the validate → fix → revalidate loop and the broad-fix consent gate into the skill; this is where exit codes `2`, `3` and `4` are emitted (lines 139, 175, 313).
- `skills/run-scenario/scripts/Invoke-RunScenario.ps1` (+13/−…) — the pre-execute gate that refuses to run against an unvalidated or drifted configuration.
- Working-tree total at planning time: **9 modified files, +1180 / −24**, plus 5 untracked files (`references/chaos/blast-radius.md` at 198 lines and four Pester suites totalling 1,242 lines — 1,440 lines in all). This work was Phase 0's only job and is **now committed at `283cb61`, with all five formerly untracked files tracked**.

#### Current `SKILL.md` sizes (measured on the working tree)

| Skill | Lines |
|---|---|
| `setup-scenario` | **181** |
| `run-scenario` | 133 |
| `start-chaos` | 119 |
| `chaos-impact` | 111 |
| `create-workspace` | 106 |

`setup-scenario` at 181 lines is the warning sign: EPIC-003 added 69 lines of blast-radius and consent narrative to a file that is a *front door*. The under-200-line cap plus progressive discovery is a direct response to this trajectory.

### `az chaos` and Kubernetes — what is actually available

Verified against Microsoft Learn (see §References for every URL):

1. **The `chaos` CLI extension has been rewritten around Chaos Studio v2** and requires Azure CLI ≥ 2.75.0. The current surface is `az chaos setup`, `az chaos workspace *`, `az chaos scenario *`, `az chaos scenario config *`, `az chaos scenario run *`, `az chaos discovered-resource *`. `az chaos setup` is GA; `show-discovery`, `show-evaluation`, `workspace wait` are GA; the rest of workspace/scenario is preview.
2. **The classic CLI commands are gone.** `az chaos experiment`, `az chaos target`, `az chaos capability`, `az chaos target-type` no longer appear in the extension reference and their Learn pages 404. The classic model is still reachable **only via REST / `az rest`** at `api-version=2024-01-01` or `2025-01-01`.
3. **The v2 workspace/scenario ARM surface is a preview-only surface, and the repository is not on the newest pin.** `mcp/chaos_mcp/apiversions.py:21` and `skills/chaos-impact/scripts/Constants.ps1:36` both pin **`2026-05-01-preview`**, with an in-code comment deferring a bump until a target environment has exercised the required operations. External spec research also confirms a later **`2026-08-01-preview`**. **This plan keeps the shipped `2026-05-01-preview` pin for v0.4.0**; bumping it is an explicit, evidence-gated task (E15-T7), not an assumption. Source proves a version exists; it does not prove an operation is deployed.
4. **All eight AKS Kubernetes faults are Chaos Mesh service-direct faults at capability version 2.2**, under target type `Microsoft-AzureKubernetesServiceChaosMesh` on `Microsoft.ContainerService/managedClusters`: `podChaos`, `networkChaos`, `stressChaos`, `IOChaos`, `timeChaos`, `kernelChaos`, `httpChaos`, `dnsChaos`. Every one takes a single `jsonSpec` parameter carrying a minified Chaos Mesh CRD spec (no `metadata`, no `kind`). Prerequisites: Chaos Mesh installed in the `chaos-testing` namespace, Linux node pools only, target + capability enablement, and — for DNS chaos — the separate Chaos Mesh DNS service.
5. **No native (Chaos-Mesh-free) Kubernetes faults are documented or announced.** No node restart, node drain, node-pool scale, or agentless AKS fault appears in the fault library, the v2 Scenarios catalog, or `Azure/chaos-studio-samples`. The only Kubernetes-adjacent faults without Chaos Mesh are `Microsoft-NetworkSecurityGroup` security-rule faults and VMSS shutdown (AKS node pools are VMSSs; the v2 "Compute Zone Down" scenario uses this).
6. **The v2 Scenarios catalog contains no AKS scenario templates.** Listed scenarios target VMs, VMSSs, databases, caches, messaging and App Service.

**The consequence is the central near-term design tension, and it is stated plainly rather than assumed away:** the plugin drives the v2 workspace/scenario surface, but the Kubernetes faults that make a Kubernetes reliability study interesting live in the *classic* model, which no longer has a CLI. The design therefore carries an explicit `faultPath` (`scenario` | `experiment`) resolved by a runtime capability probe, not a guess. See **Q1**, **D5** and **EPIC-005**.

The task brief refers to "upcoming Kubernetes faults". Public sources at this date do not describe any. This plan **does not encode unannounced faults**; it makes the guidance structure additive so that when they ship, a Kubernetes fault is a new reference file plus a routing-table row, and nothing else. That gap is **Q2**, owned by Chaos Studio product.

### Field evidence (condensed)

Fifteen observations from a live engagement continue to motivate specific requirements. The full narrative is preserved in the Revision 5 history; the load-bearing subset is:

| ID | Observation | What it still forces |
|---|---|---|
| **F1** | No build-identity attestation; the running build was identified behaviourally | Report must record *what was running*, with a rung and caveats — **DEFERRED to a report field, not a gate** |
| **F2** | The same pre/during/post telemetry bundle was hand-assembled four times | One deterministic window-pack collector (FR-11) |
| **F3** | "Did an alert fire inside the window" needed raw `az rest` with a hand-built `timeRange` | Alert-instance collection is first-class in the collector |
| **F4** | App Insights resource-scoped queries need `--subscription` injected and the **classic** lowercase schema | Two verified normalisations only; the third ("`first` is reserved") was **falsified** and is not implemented |
| **F5** | A skill named three MCP tools that were absent from the session | Tools are **optional** and probed, never assumed (D6) |
| **F6** | Event Hubs reported `Disabled` while `EventHubProducerClient.Send` was 60/60 successful | Control-plane state is not disruption proof; findings say so (D8) |
| **F7** | `scenarioRunSummary[].actionName` null on all actions; `run start --no-wait` returns an empty 2xx with no run id | Deterministic run-ID recovery and honest action labelling (FR-13) |
| **F8** | Per-fault semantics undocumented; exclusion-based leg starvation undiscoverable | The fault guidance pack (EPIC-005) |
| **F9** | Azure Advisor was an anti-correlation: 16 recommendations, zero matches | Advisor is not a grounding source (N7) |
| **F10** | A formally valid predicate failed to detect that a probe was a no-op | Findings carry a "was the mechanism live?" caveat |
| **F11** | Three advisories failed for one underlying reason recorded as three fixes | Findings are classed, not enumerated |
| **F12** | `tmp/` was wiped twice, destroying two runs of evidence | The immutable dated study store (FR-14, EPIC-004) |
| **F13** | A fix scored in isolation ranked last, then became the correctness blocker for a higher-ranked fix | Findings are prioritized with coupling noted |
| **F14** | The verify-mode rule was correct and load-bearing; manual mode lost it | Limitations section of the report is mandatory |
| **F15** | Prove landing from ARM entity state, not the Activity Log; re-poll empty first reads | Collector re-polls; Activity Log is context, never proof |

Two recorded *explanations* were falsified by later verification and are retained as rejected mechanisms so they are not re-derived: the `AmqpSender`/`MaxMessageSize` caching theory for F6 (`AmqpProducer.CreateLinkAndEnsureProducerStateAsync` refreshes it on every link open), and "`first` is a KQL reserved token" for F4 (`--first` is an Azure CLI/ARG paging parameter mapping to REST `$top`). The **observations** stand; the mechanisms do not.

### PR #32 disposition

`[PR32]` / `renzopretto-microsoft-add-chaos-loop-plugin` introduced a single `chaos-loop` skill with internal `advisory`/`coding` phases, a monolithic `chaos_loop_state.py` state machine, repo-local `tmp/chaos-loop/` state, a hard-coded `scenario-catalog.v1.json`, and an all-or-nothing external gate.

**Decision: the PR is rescoped and replaced, not extended.** None of its paths exist on main, so nothing is deleted. Its state machine is not ported and is not the basis of any epic here. Four *patterns* are re-expressed in the new design and credited: atomic revisioned writes (already delivered in `[E2]`), the proposal/evaluate split (D9), the frozen-configuration drift gate (RETAINED from `[E3]`/`[MAIN]`), and the three-verdict vocabulary (RESHAPED into finding confidence, D8). The hard-coded catalog, the phase controller and the repo-local state are **REMOVED from the plan of record**.

---

## Problem Statement

**P1 — The plan outgrew the product.** Revision 5 specified eight new peer skills on top of five shipped ones — thirteen user-facing front doors for a workflow a user experiences as one question ("is my cluster resilient?"). Skill selection becomes ambiguous, and no single skill is the obvious place to start. **The honest arithmetic of the fix:** this design takes the count from thirteen to **ten**, not to five. The five shipped skills are the low-level verbs and stay unchanged in v0.4.x for backward compatibility (NFR-10, Q12); the five new ones are the workflow and are the only ones documented and marketed as the way in. Ten front doors is not the end state — Q12 owns the v0.5 decision — but ten with one obvious entry point is a different problem from thirteen with none.

**P2 — The prompt surface is growing instead of shrinking.** `setup-scenario/SKILL.md` reached 181 lines because EPIC-003 pushed blast-radius and consent narrative into a front door. Front doors that carry scenario-specific detail cannot stay principle-led, and every new fault type makes them worse.

**P3 — There is no deliverable.** The suite produces JSON artifacts and a Markdown run report. Nobody schedules a reliability review around a JSON artifact. The unit a team actually consumes is a dated report with findings, evidence and remediation.

**P4 — Results are not addressable over time.** `[E2]` made evidence *durable*, keyed by `runId`. It did not make results *immutable*, *dated*, or *enumerable as studies*. A new conversation cannot answer "what did we test last month, and did it get better?"

**P5 — MCP is on the critical path when it should not be.** `[E1]` made every skill declare `requiredTools` and fail fast when the host does not expose them. That was the correct fix for F5 in a plan where MCP owned the deterministic layer. In a product built over `az chaos`, it converts an optional accelerator into a hard dependency and a hard failure.

**P6 — Kubernetes is unreachable from the shipped path.** The plugin drives v2 workspaces/scenarios; the v2 Scenarios catalog has no AKS templates; the eight AKS faults are classic-model and the classic CLI has been removed. A Kubernetes study today requires REST calls that the plugin explicitly forbids from skill prompt text.

**P7 — Fault knowledge has no home.** Per-fault semantics, safe parameter ranges, steady-state and impact signals, and abort conditions live in engineers' memory (F8, F15) or, worse, inside a `SKILL.md`. There is no versioned, discoverable, extensible structure.

**P8 — Control-plane assertions can masquerade as proof.** F6. The service reports what it intended to mutate. A report that presents intent as effect is worse than no report.

**P9 — The chaos-loop PR is a fork in the road that has not been closed.** Leaving it open invites someone to extend its state machine, which re-imports every problem above.

---

## Goals and Non-Goals

### Goals

- **G1** — One obvious entry point. A user who says "run a chaos study on my AKS cluster" reaches `chaos-study` and needs to know nothing else.
- **G2** — A small, coherent, composable suite: exactly five **study** skills, each independently useful, each invocable directly. The five shipped skills are unaffected and remain the low-level verbs (Q12), so v0.4.x ships ten user-facing skills in total — five marketed as the workflow, five retained for compatibility.
- **G3** — Principle-led front doors. Every user-facing `SKILL.md` is under 200 lines, enforced mechanically rather than by review. Scenario- and fault-specific detail is reached by progressive discovery into `references/chaos/**`.
- **G4** — Deterministic and safety-critical behaviour lives in reusable scripts under `copilot-cli-plugin/scripts/` and `skills/*/scripts/`, is unit-tested offline, and is never re-implemented in prompt text.
- **G5** — Built directly over `az chaos` through the existing `Invoke-AzChaos.ps1` seam. No MCP server, no agent framework and no external service is required for the core workflow.
- **G6** — A polished, self-contained HTML study report: tests run, dated evidence, prioritized findings, explicit limitations, and remediation guidance.
- **G7** — Immutable, dated, enumerable study results outside repo-local and session-temporary state; a later chat can `list`, `compare` and `rerun`.
- **G8** — Kubernetes reliability study is the first complete vertical slice, end to end, on real `az chaos` capabilities.
- **G9** — An extensible fault/scenario guidance structure: a new fault is a new reference file plus a routing-table row.
- **G10** — Every claim in a report carries provenance and freshness; missing data is `null` with a caveat, never a fabricated zero.
- **G11** — Every mutation is disclosed; fault execution requires explicit human consent; broad permission grants require a separate, stronger consent.
- **G12** — All delivered `[E1]`/`[E2]`/`[E3]` value is carried forward, with each asset explicitly classified RETAINED / RESHAPED / DEFERRED / REMOVED.

### Non-Goals

- **N1** — Not an SRE Agent feature. Nothing in the core workflow may depend on SRE Agent, its runtime, or its prompt conventions. The suite is a Copilot CLI plugin.
- **N2** — Not an MCP product. The MCP server remains an **optional** adapter for hosts that prefer tool calls. It is never required.
- **N3** — Not a controller or state machine. No `chaos-loop`, no phase engine, no monolithic run-state document.
- **N4** — Not a code-remediation agent. Reports recommend; they do not open PRs or edit source.
- **N5** — Not an SLO management product. SLOs are consumed as optional inputs.
- **N6** — Not a general Azure inventory tool. Discovery is scoped to what targeting, blast radius and impact measurement need.
- **N7** — Advisor is not a grounding gate (F9). Optional context at most.
- **N8** — No unattended fault injection on the study path. Ever. No flag, variable or file grants execution consent to the five study skills. **Known exception, in shipped code:** `run-scenario` honours `$env:STARTCHAOS_NONINTERACTIVE=1`; closing it is E15-T8 (see §Detailed Design → Consent).
- **N9** — Not a replacement for the Chaos Studio portal scenario report. The service's own run report is *linked and referenced* by our study report, not reimplemented.

---

## Requirements

### Functional

| ID | Requirement | Trace |
|---|---|---|
| **FR-1** | `chaos-study` accepts a scope (subscription, resource group, or explicit resource IDs) and a plain-language reliability question, and drives the whole study: readiness → plan → consent → execute → measure → report. | G1 |
| **FR-2** | Every user-facing skill is directly invocable with its own inputs and produces a useful result without any other skill having run first, degrading explicitly when a prerequisite artifact is absent. | G2 |
| **FR-3** | Every user-facing `SKILL.md` — all ten in v0.4.x — is **under 200 lines**. A single CI test enforces the cap across the whole set, so a shipped skill cannot drift past it either. | G3, P2 |
| **FR-4** | Scenario- and fault-specific guidance is reached by progressive discovery: the skill names a routing table (`references/chaos/faults/_index.md`), which names one guide per fault. Skills never inline fault parameters. | G3, G9 |
| **FR-5** | All Chaos Studio control-plane interaction goes through `scripts/Invoke-AzChaos.ps1` (v2 `az chaos`) or, where the v2 CLI has no equivalent, `scripts/Invoke-AzChaosClassic.ps1` — a **new, thin, pinned REST wrapper**. No skill emits ad-hoc `az chaos` or `az rest`. | G5, P6 |
| **FR-6** | A runtime **capability probe** determines, per subscription and per target type, which `faultPath` is available (`scenario` via v2 workspaces, `experiment` via classic REST), records the answer in the study manifest, and refuses to guess. | P6, Q1 |
| **FR-7** | Kubernetes readiness preflight verifies, and reports individually: AKS cluster reachable; **Linux** node pool present; Chaos Mesh installed in the `chaos-testing` namespace (no other namespace is supported); target `Microsoft-AzureKubernetesServiceChaosMesh` enabled; capability version **2.2** enabled for the chosen fault; the workspace/experiment system-assigned managed identity holds `Azure Kubernetes Service Cluster Admin Role` on the cluster; a measurement source (Container Insights or managed Prometheus) present. Each of the seven checks returns pass / fail / unknown **with the exact remediation command**. | G8 |
| **FR-7a** | **The single observability rule.** The absence of any one observability provider is `unknown`, never `fail`, and never blocks on its own. A plan is marked `blocked` if and only if **no available source can evaluate the plan's chosen steady-state predicate**. This rule is stated once here and referenced everywhere else. | G8, G10 |
| **FR-8** | The study plan states, before any consent prompt: the hypothesis, the steady-state predicate, the fault and its parameters, the resolved blast radius, the duration, the abort conditions, and the signals that will be measured. | G6, G11 |
| **FR-9** | Fault execution requires explicit human consent bound to the frozen configuration. Any drift between validation and execution aborts with a diff. Broad permission remediation requires a **separate** consent (retained from `[E3]`). | G11 |
| **FR-10** | The strict validate → fix → revalidate gate is preserved exactly as delivered in `[E3]`; `--skip-validation` is only ever passed **after** that gate has succeeded. | G12 |
| **FR-11** | A single deterministic collector returns the pre / during / post window pack for a study: AKS platform metrics, Container Insights tables, Prometheus (when present), Activity Log, and alert instances — with half-open `[start, end)` windows and per-source `null` + caveat on failure. | F2, F3, F4 |
| **FR-12** | Findings are derived deterministically from numeric evidence against the captured baseline, carry a severity (`critical` / `high` / `medium` / `low`), a confidence, the evidence that produced them, and — where the mechanism was not proven — an explicit caveat. Control-plane state alone never produces a `confirmed` finding. | F6, F10, P8 |
| **FR-13** | Run identity is recovered deterministically after an empty 2xx start (filter runs by `startTime ≥ requestSentAt`, matched on configuration name, bounded retry), and fails loudly rather than returning null. Null `actionName` is preserved and labelled by URN, never silently relabelled. | F7 |
| **FR-14** | Study results are written to an **immutable dated store** outside the repository and outside session-temporary state: `$CHAOS_STUDY_ROOT/<scopeHash>/<studyId>/`, with `studyId = <UTC yyyyMMdd'T'HHmmss'Z'>-<8-hex>`. After sealing, writes are refused. | G7, F12, P4 |
| **FR-15** | `chaos-study-history` can, with no prior conversational context: **list** studies for a scope, **show** one, **compare** two (same scope, same scenario family) reporting per-signal deltas and finding appearance/disappearance, and **rerun** a study — producing a *new* `studyId` carrying `derivedFrom`. | G7 |
| **FR-16** | Every study produces `report.html`: a single file, no external network assets, no CDN, no JS framework, inline CSS and inline SVG. It contains an executive summary, tests run, dated evidence, prioritized findings, limitations, remediation guidance, and an appendix with the redacted command trail and api-versions used. | G6, P3 |
| **FR-17** | Report rendering is deterministic: identical inputs produce byte-identical output except for a single `generatedAt` field, so two reports can be diffed. | G6 |
| **FR-18** | The report's **Limitations** section is mandatory and non-empty. It states what was *not* proven, which checks returned `unknown`, which signals were absent, and — for Kubernetes — whether the fault was proven to have reached the data plane. | F14, P8 |
| **FR-19** | Remediation guidance is per finding and actionable: the change to make, where, the expected observable effect, and how to re-verify (usually "rerun study `<studyId>`"). | G6 |
| **FR-20** | MCP tools are **optional**. Skills declare `optionalTools`; the preflight probes the host inventory and, when a tool is absent, selects the script path and records the substitution in the manifest. Absence is never a hard failure for the core workflow. | N2, P5 |
| **FR-21** | The fault guidance pack has a fixed, schema-validated front-matter contract so guides are machine-checkable and a new fault cannot be added half-specified. | G9, P7 |
| **FR-22** | The study manifest records every `az` invocation made (command, exit code, duration, api-version) with arguments redacted, so a study is auditable and reproducible. | G10 |

### Non-Functional

| ID | Requirement |
|---|---|
| **NFR-1** | Every deterministic component is unit-testable offline. No test requires Azure. Existing harnesses are reused: Pester (`Run.Path='./copilot-cli-plugin/skills'` unchanged), pytest with `_TEST_TRANSPORT`, ruff, and the `chaos-impact` offline replay. |
| **NFR-2** | All timestamps ISO-8601 UTC with a `Z` suffix; all windows half-open `[start, end)`. |
| **NFR-3** | Missing data is `null` with a caveat string. A reported `0` must be a measured zero. Null-vs-zero conflation is a contract violation with a dedicated test. |
| **NFR-4** | Least privilege. Readiness and discovery need `Reader`. Execution needs `Chaos Studio Experiment Contributor` scoped to the workspace (or experiment), plus — for AKS Chaos Mesh faults — **`Azure Kubernetes Service Cluster Admin Role`** on the cluster, assigned to the workspace/experiment system-assigned managed identity (documented prerequisite). Azure Chaos Studio has exactly four built-in roles — Experiment Contributor, Operator, Reader, Target Contributor. "Chaos Studio Owner"/"Contributor" do not exist. |
| **NFR-5** | No secret, connection string, token or key material reaches any artifact, the report, the command trail, or a log line. The `[E2]` redaction denylist and the `$CHAOS_KEY_DIR` denylist are enforced on the study store unchanged. |
| **NFR-6** | The study store is atomic and crash-safe: temp file + rename under an exclusive lock, then a seal step that writes `manifest.json` containing a SHA-256 over **every file in the study directory except `manifest.json` itself and the `SEALED` marker** (both are excluded because they are written after the hash is computed). `index.json` lives outside the study directory and is not covered. A partially written study is detectable and is never listed as complete. |
| **NFR-7** | Report generation is offline and dependency-free — PowerShell 7 plus the repository template. No Node, no Python, no browser engine, no network. |
| **NFR-8** | `report.html` renders correctly with JavaScript disabled and opens from `file://`. Total size target ≤ 2 MB for a typical study; raw evidence stays in sidecar JSON. |
| **NFR-9** | API-version pins stay centralised **one file per language**. Python is already consolidated in `chaos_mcp/apiversions.py` (delivered by E1-T7). PowerShell is **not**: the only pin file today is `skills/chaos-impact/scripts/Constants.ps1`, scoped to one skill. E7-T1 promotes it to `copilot-cli-plugin/scripts/Constants.ps1` with a dot-source shim left at the old path for one minor version; the classic-REST pin is added there and the existing dead-pin lint test is extended to the PowerShell file. |
| **NFR-10** | Backward compatibility through v0.4.x: `$env:STARTCHAOS_STATE_PATH` files still resume; `impactReportSchemaVersion: 1` is unchanged; the 15 original MCP tool names/signatures/envelopes are unchanged; the `[E2]` evidence store is readable. Skill-surface changes follow the two-release deprecation in §Migration. |
| **NFR-11** | Studies are portable: a sealed study directory can be zipped, moved to another machine and read by `chaos-study-history` without the originating scope, subscription or credentials. |
| **NFR-12** | Retention is explicit and configurable (`CHAOS_STUDY_RETENTION_DAYS`, default 365 — longer than evidence's 90 because a study is the durable record). Purge never deletes a sealed study without an explicit, confirmed command. |

---

## Proposed Design

### Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────────────┐
│  Copilot CLI — the five study skills (one entry + four supporting)            │
│                                                                               │
│                          ┌──────────────────┐                                 │
│                          │   chaos-study    │  ← the obvious entry point      │
│                          │   (< 200 lines)  │     opinionated, end-to-end     │
│                          └────────┬─────────┘                                 │
│         ┌─────────────────┬───────┴────────┬──────────────────┐               │
│         ▼                 ▼                ▼                  ▼               │
│  chaos-study-scope  chaos-study-run  chaos-study-report  chaos-study-history  │
│  discovery,         consent,         self-contained      list / show /        │
│  readiness,         execution,       HTML report         compare / rerun      │
│  hypothesis, plan   window capture                                            │
│                                                                               │
│  Each is directly invocable. Arrows are composition, never a hidden handoff.  │
└───────────────────────────────────────────────────────────────────────────────┘
        │ progressive discovery (read on demand, never inlined)
        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│  references/chaos/**  — principle docs + fault/scenario guidance pack         │
│  study-method.md · evidence-contract.md · blast-radius.md · verdict-matrix.md │
│  report-contract.md · faults/_index.md → faults/aks-chaosmesh-*.md · …        │
│  scenarios/_index.md → scenarios/kubernetes-*.md                              │
└───────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│  Deterministic PowerShell layer — the product's real engine                   │
│                                                                               │
│  [MAIN] Invoke-AzChaos.ps1 · Ensure-AzLogin.ps1 · Invoke-AzRest.ps1           │
│         Wait-AzureLro.ps1 · Constants.ps1                                     │
│  [E1]   Preflight.ps1  (reshaped: optional-tool probe, non-blocking)          │
│  [E2]   State.ps1  (evidence root, redaction, atomic writes, import)          │
│  [E3]   Validate-AndFix.ps1 · Rbac.ps1 · Render.ps1 (blast radius, consent)   │
│  [NEW]  Study.ps1 · Invoke-AzChaosClassic.ps1 · Resolve-FaultPath.ps1         │
│         Get-K8sReadiness.ps1 · Get-StudySignals.ps1 · Build-StudyFindings.ps1 │
│         New-StudyReport.ps1 · Compare-Study.ps1 · Constants.ps1 (promoted)    │
└───────────────────────────────────────────────────────────────────────────────┘
        │                                              │
        ▼                                              ▼
┌────────────────────────────────┐   ┌────────────────────────────────────────┐
│ [NEW] Immutable dated study    │   │  Azure                                 │
│ store — outside repo & tmp     │   │  az chaos (v2 workspace/scenario)      │
│ $CHAOS_STUDY_ROOT/<scopeHash>/ │   │  classic experiments (REST, pinned)    │
│   <studyId>/  … sealed         │   │  AKS + Container Insights + Prometheus │
│   index.json  … append-only    │   │  Activity Log · AlertsManagement       │
│ built on the [E2] evidence     │   └────────────────────────────────────────┘
│ store's redaction/atomicity    │
└────────────────────────────────┘
        ▲
        │  optional, never required
┌───────┴───────────────────────────────────────────────────────────────────────┐
│  [OPTIONAL] MCP adapter chaos_mcp — 18 tools. If the host exposes them the    │
│  skills may use them; if not, the script path runs and records a substitution.│
└───────────────────────────────────────────────────────────────────────────────┘
```

Four rules govern the architecture:

1. **The scripts are the product; the skills are the interface.** If a behaviour must be correct every time, it is a script with a Pester test.
2. **The front door stays a front door.** Fault detail is discovered, not inlined.
3. **`az chaos` first.** REST is a fallback for capabilities the v2 CLI does not expose, and it is a wrapper, not prompt text.
4. **A study is immutable once sealed.** Reruns create new studies.

### Key Components

#### 1. The five skills

| Skill | Role | Line budget | Directly useful for |
|---|---|---|---|
| **`chaos-study`** | **Entry.** Opinionated end-to-end reliability study. | < 200 | "Run a chaos study on this AKS cluster." |
| **`chaos-study-scope`** | Discovery, readiness, hypothesis, study plan. | < 200 | "Is my cluster even ready for chaos, and what should I test?" |
| **`chaos-study-run`** | Consent, execution, window capture. | < 200 | "Execute this plan and capture what happened." |
| **`chaos-study-report`** | Findings + self-contained HTML report. | < 200 | "Give me the report for study `<id>`." |
| **`chaos-study-history`** | List, show, compare, rerun. | < 200 | "What have we tested before, and did it improve?" |

The budget is a hard cap on all five, and the same test applies it to the five shipped skills (FR-3, D3).

---

**1.1 `chaos-study`** — the entry skill

| | |
|---|---|
| **Triggers** | "run a chaos study", "chaos test my AKS cluster", "is this resource group resilient", "reliability study for &lt;scope&gt;" |
| **Inputs** | `-Scope` (subscription / RG / resource IDs), optional `-Question` (plain language), optional `-Vertical` (default `kubernetes`), optional `-DryRun` (default **true**) |
| **Owned by scripts** | `skills/chaos-study/scripts/Invoke-ChaosStudy.ps1` — orchestrates readiness → plan → consent → execute → measure → seal → report by invoking the supporting skills' scripts in-process |
| **Owned by the model** | Interpreting the user's question into a hypothesis; explaining the plan and the trade-offs; narrating the findings |
| **Output** | A sealed study directory and `report.html`, plus a terminal summary card |
| **Structure (the entire file, ~180 lines)** | frontmatter (~15) · what a study is and the four principles (~25) · the six steps with one paragraph each (~50) · safety and consent (~25) · progressive-discovery routing table (~20) · exit codes (~20) · worked example (~20) |
| **Progressive discovery** | The routing table is the only place fault detail is referenced: *"Before proposing a fault, read `references/chaos/faults/_index.md` and then the single guide for the chosen fault. Do not restate fault parameters here."* |
| **Safety** | `-DryRun` is the default. Producing a plan is free; executing requires consent. |

**1.2 `chaos-study-scope`** — discovery, readiness, hypothesis, plan

| | |
|---|---|
| **Triggers** | "what can I chaos test here", "is my cluster ready for chaos", "plan a chaos study", "why can't I run &lt;fault&gt;" |
| **Inputs** | `-Scope` or `-StudyId`, optional `-Vertical`, optional `-Question` |
| **Deterministic work** | `Get-K8sReadiness.ps1` (FR-7, every check individually pass/fail/unknown + remediation command) · `Resolve-FaultPath.ps1` capability probe (FR-6) · `az chaos workspace show-discovery` / `show-evaluation` / `az chaos discovered-resource list` · `az chaos scenario list` · blast-radius resolution via `[E3] Resolve-BlastRadius` · signal-availability check (Container Insights / Prometheus / alert rules) |
| **Model work** | Turning the user's question into a falsifiable hypothesis and a steady-state predicate, using `references/chaos/study-method.md` |
| **Output** | `study-plan.v1.json` (new schema; reuses the `[E2]` artifact envelope) written into an **unsealed** study directory |
| **Rule** | Scenario and fault names come only from a service response or from the fault guidance pack's `faultUrn`. Nothing is invented. |
| **Reuses** | `[MAIN] Invoke-AzChaos.ps1`, `[E2] State.ps1`, `[E3] Render.ps1` blast-radius card |

**1.3 `chaos-study-run`** — consent, execution, window capture

| | |
|---|---|
| **Triggers** | "execute the study plan", "run the experiment", "cancel my chaos run" |
| **Inputs** | `-StudyId` (or an explicit plan), `-Confirm`, optional `-Cancel` |
| **Deterministic work** | Freeze the configuration and hash it · `[E3]` validate → fix → revalidate gate · render blast radius and abort conditions · read typed consent · create/execute via `faultPath` · deterministic run-ID recovery (FR-13) · capture pre-window baseline before start and post-window after end · `Get-StudySignals.ps1` window pack (FR-11) · write `run-record.v1.json` and raw evidence |
| **Model work** | Presenting the consent prompt and narrating recovery |
| **Output** | `run-record.v1.json` + `evidence/{pre,during,post}/*.json` in the study directory |
| **Abort** | Abort conditions are evaluated during the run; breach triggers `az chaos scenario run cancel` (or classic cancel) and records `abortedBy` |
| **Reuses** | `[E3] Validate-AndFix.ps1`, `Rbac.ps1`, `Render.ps1`; the `[MAIN] Invoke-RunScenario.ps1` execution logic, **dot-sourced in place** — the shipped skill's entry point is not moved or renamed (NFR-10) |

**1.4 `chaos-study-report`** — findings and the HTML report

| | |
|---|---|
| **Triggers** | "generate the chaos report", "what did study &lt;id&gt; find", "give me the HTML report" |
| **Inputs** | `-StudyId`, optional `-Open`, optional `-Format` (`html` default, `md` secondary) |
| **Deterministic work** | `Build-StudyFindings.ps1` — deltas versus the captured baseline, threshold evaluation, severity assignment, confidence, and the mandatory limitations set · `New-StudyReport.ps1` — renders `skills/chaos-study-report/templates/study-report.html.tmpl` with inline CSS and inline SVG sparklines, following the token-substitution pattern already proved by `[MAIN] scripts/New-RunReport.ps1` and `skills/chaos-impact/templates/report.md.tmpl` · seals the study |
| **Model work** | The executive summary paragraph and the human-readable remediation prose, both inserted into fixed slots and both marked as narrative in the report |
| **Output** | `findings.v1.json` + `report.html`, then `SEALED` |
| **Rule** | The model cannot alter a severity, a number, or the limitations list. Those slots are script-rendered. |

**1.5 `chaos-study-history`** — list, show, compare, rerun

| | |
|---|---|
| **Triggers** | "what chaos studies have we run", "compare my last two studies", "rerun study &lt;id&gt;", "did reliability improve" |
| **Inputs** | `-Scope` or `-StudyId` (+ `-Against <studyId>` for compare), `-Rerun` |
| **Deterministic work** | `Study.ps1` index read · `Compare-Study.ps1` — matches studies by scope + scenario family, computes per-signal deltas and finding appearance/disappearance/severity change · rerun materialises the recorded plan into a **new** unsealed study with `derivedFrom` |
| **Output** | `comparison.v1.json` + a comparison HTML report; or a new `studyId` ready for `chaos-study-run` |
| **Cold-start** | Requires only `$CHAOS_STUDY_ROOT` and a `studyId`. No conversational memory, no Azure call for `list`/`show`/`compare`. |

#### 2. The reference layer (progressive discovery)

```
copilot-cli-plugin/references/chaos/
  study-method.md         [NEW]  hypothesis, steady state, blast radius, abort, evidence
  report-contract.md      [NEW]  report sections, severity scale, limitation taxonomy
  evidence-contract.md    [E2]   RETAINED, extended with the study-store section
  blast-radius.md         [E3]   RETAINED verbatim
  verdict-matrix.md       [E2]   RESHAPED into finding severity/confidence
  faults/
    _index.md             [NEW]  routing table: faultUrn → guide, vertical, faultPath
    aks-chaosmesh-pod.md          [NEW]  podChaos/2.2
    aks-chaosmesh-network.md      [NEW]  networkChaos/2.2
    aks-chaosmesh-stress.md       [NEW]  stressChaos/2.2
    aks-chaosmesh-io.md           [NEW]  IOChaos/2.2
    aks-chaosmesh-dns.md          [NEW]  dnsChaos/2.2
    aks-chaosmesh-http.md         [NEW]  httpChaos/2.2
    aks-chaosmesh-time.md         [NEW]  timeChaos/2.2
    aks-chaosmesh-kernel.md       [NEW]  kernelChaos/2.2
    aks-nodepool-vmss-shutdown.md [NEW]  VMSS shutdown against an AKS node pool
    aks-nsg-rule.md               [NEW]  NSG security-rule fault around a cluster
  scenarios/
    _index.md                      [NEW]
    kubernetes-pod-resilience.md   [NEW]
    kubernetes-node-loss.md        [NEW]
    kubernetes-dependency-latency.md [NEW]
```

Every fault guide carries the same YAML front matter, validated by `schemas/fault-guide.v1.schema.json` (FR-21):

```yaml
---
guideSchemaVersion: 1
faultUrn: "urn:csci:microsoft:azureKubernetesServiceChaosMesh:podChaos/2.2"
displayName: "AKS Chaos Mesh Pod Chaos"
vertical: kubernetes
faultPath: experiment          # scenario | experiment — see D5 / Q1
targetType: Microsoft-AzureKubernetesServiceChaosMesh
resourceType: Microsoft.ContainerService/managedClusters
capabilityName: PodChaos-2.2
prerequisites:
  - id: chaos-mesh-installed
    check: "kubectl get deploy -n chaos-testing chaos-controller-manager"
    remediation: "helm install chaos-mesh chaos-mesh/chaos-mesh --namespace=chaos-testing …"
  - id: linux-nodepool
  - id: target-enabled
parameters:
  jsonSpec:
    shape: "Chaos Mesh PodChaos spec, minified, without metadata/kind"
    actions: [pod-failure, pod-kill, container-kill]
    example: '{"action":"pod-failure","mode":"one","selector":{"namespaces":["default"]}}'
steadyStateSignals:
  - { source: metrics,  name: kube_pod_status_ready }
  - { source: prometheus, name: kube_deployment_status_replicas_available }
impactSignals:
  - { source: logs, table: KubePodInventory, kql: "…" }
  - { source: logs, table: KubeEvents, filter: "Reason in ('BackOff','Evicted','NodeNotReady')" }
  - { source: metrics, name: kube_pod_status_phase }
blastRadiusControls:
  - "selector.namespaces narrows to a namespace"
  - "mode: one | fixed | fixed-percent | random-max-percent"
abortConditions:
  - "availableReplicas == 0 for any targeted Deployment for > 60s"
knownLimitations:
  - "Chaos Mesh is in-cluster; a cluster-wide outage stops the fault itself"
dataPlaneProof:
  signal: "KubePodInventory pod restart/phase transitions inside the window"
  coverage: documented        # documented | heuristic | none
---
```

`coverage` is surfaced in the plan **and** in the report's Limitations section. A `heuristic` probe is visibly weaker evidence than a `documented` one; a `none` guide cannot ship (schema-enforced).

#### 3. The immutable dated study store

```
$CHAOS_STUDY_ROOT/                       default: per-user app data (see NFR-12/Q7)
  <scopeHash>/
    index.json                           append-only; one line-equivalent record per study
    20260824T184213Z-9f2c1ab4/
      manifest.json                      sealed; SHA-256 over every file below, excluding itself and SEALED
      study-plan.v1.json
      run-record.v1.json
      findings.v1.json
      report.html
      commands.jsonl                     redacted command trail (FR-22)
      evidence/pre/*.json
      evidence/during/*.json
      evidence/post/*.json
      SEALED                             presence = immutable
```

| Property | Design |
|---|---|
| **Identity** | `studyId = <UTC yyyyMMdd'T'HHmmss'Z'>-<8 hex of scopeHash‖plan digest‖nonce>`. Sortable, human-dated, collision-resistant. |
| **Immutability** | Once `SEALED` exists, `Save-StudyArtifact` refuses every write with `StudyAlreadySealed`. There is no force flag. |
| **Location** | Resolution order: `$env:CHAOS_STUDY_ROOT` → `.chaos-plugins.yaml` `studyRoot` → per-user app data. **Never** the repository, never `$env:TEMP`, never next to `startchaos-state.json`. A test asserts the resolved root is not under the repository root and not under the system temp directory. |
| **Relationship to `[E2]`** | Built on the `[E2]` primitives — the same atomic temp-file + rename under lock, the same canonicalization, the same redaction denylist, the same `$CHAOS_KEY_DIR` denial. The study store adds *sealing*, *dating* and *enumeration*; it does not fork the safety code. |
| **Portability** | `manifest.json` is self-describing: schema versions, api-versions, tool/script versions, scope descriptor, `faultPath`, `derivedFrom`. A zipped study opens on another machine (NFR-11). |
| **Retention** | `CHAOS_STUDY_RETENTION_DAYS`, default 365. Purge requires an explicit confirmed command and never runs implicitly. |
| **Abandonment** | `CHAOS_STUDY_ABANDON_HOURS`, default 72. A `PLANNED` study older than this with no run record is reported as `ABANDONED` by `list` and may be sealed with `outcome: abandoned`. It is never deleted implicitly. |
| **Environment** | `CHAOS_STUDY_ROOT`, `CHAOS_STUDY_RETENTION_DAYS`, `CHAOS_STUDY_ABANDON_HOURS`. The `[E2]` variables (`CHAOS_EVIDENCE_ROOT`, `CHAOS_KEY_DIR`, `CHAOS_EVIDENCE_RETENTION_DAYS`, `CHAOS_EVIDENCE_DISABLED`) keep their existing meaning and are not overloaded. |

#### 4. MCP as an optional adapter

`[E1]` introduced `requiredTools` + `Assert-RequiredTools` (fail fast on a missing tool). That remains the right answer to F5 **for a skill that genuinely cannot work without the tool**. In this product no skill is in that position.

The reshape is small and surgical:

| Aspect | `[E1]` today | `[NEW]` |
|---|---|---|
| Front matter | `requiredTools:` | `optionalTools:` (`requiredTools:` still parsed and honoured if present) |
| Behaviour on absence | `Assert-RequiredTools` throws with a named prefix | `Resolve-ToolPath` returns `Script` and records `toolSubstitutions[]` in the manifest |
| F5 protection | Fail fast | **Preserved**: a skill may still not *silently* substitute. The substitution is written into the manifest and shown in the report appendix. |
| Tests | `Preflight.Tests.ps1`, `test_tool_manifest.py` | Extended, not replaced; the fail-fast tests move to a `requiredTools` fixture so the capability is still covered |

The 18 MCP tools are RETAINED unchanged. `chaos_evidence_*` gains three study siblings only if a host actually needs cross-process study access — otherwise DEFERRED (Q6).

### Data Flow

**Flow A — a Kubernetes study, happy path**

1. `chaos-study -Scope <rg> -Question "does the checkout service survive losing a pod?"`
2. → `chaos-study-scope`: `Ensure-AzLogin` → `Resolve-FaultPath` (capability probe, FR-6) → `Get-K8sReadiness` (FR-7) → `az chaos workspace show-discovery` / `discovered-resource list` → read `faults/_index.md` → read `faults/aks-chaosmesh-pod.md` → model forms the hypothesis → `Resolve-BlastRadius` → `study-plan.v1.json` written to a **new unsealed** `studyId`.
3. Plan card rendered: hypothesis, steady state, fault + `jsonSpec`, resolved blast radius, duration, abort conditions, signals. **Stop if `-DryRun`.**
4. → `chaos-study-run`: freeze + hash → validate/fix/revalidate `[E3]` → typed consent → capture `evidence/pre` baseline → execute via `faultPath` → recover run id (FR-13) → poll and evaluate abort conditions → capture `evidence/during` → wait post-buffer → capture `evidence/post` → `run-record.v1.json`.
5. → `chaos-study-report`: `Build-StudyFindings` → `findings.v1.json` → `New-StudyReport` → `report.html` → `manifest.json` + `SEALED` → `index.json` appended.
6. Terminal card: verdict banner, top findings, path to `report.html`.

**Flow B — cold entry, weeks later, new conversation**

1. `chaos-study-history -Scope <rg>` → reads `index.json` → table of studies with date, scenario, top severity. **No Azure call.**
2. `chaos-study-history -StudyId A -Against B` → `Compare-Study` → per-signal deltas, findings appeared/resolved/changed → `comparison.v1.json` + comparison HTML.
3. `chaos-study-history -StudyId A -Rerun` → new unsealed `studyId` with `derivedFrom: A` and the identical plan → hand off to `chaos-study-run`.

**Flow C — not ready**

`chaos-study-scope` finds Chaos Mesh absent. It emits a readiness card where every check is pass/fail/unknown with its exact remediation command, writes an unsealed plan marked `blocked`, and stops. **It does not install anything.**

### API Contracts

#### New artifact schemas (same envelope as the nine `[E2]` schemas)

| Schema | Payload key | Purpose |
|---|---|---|
| `study-plan.v1.schema.json` | `plan` | `{studyId, vertical, question, hypothesis, steadyState, fault:{urn,faultPath,parameters}, targeting, duration, abortConditions[], signals[], readiness{}, blocked}` |
| `findings.v1.schema.json` | `findings` | `[{id, title, severity, confidence, evidence[], signalDeltas[], mechanismProven, remediation{change,where,expectedEffect,reverify}}]` plus a required `limitations[]` |
| `study-manifest.v1.schema.json` | `manifest` | `{studyId, createdAt, sealedAt, scope, scopeHash, derivedFrom?, faultPath, apiVersions{}, toolSubstitutions[], files:[{path,sha256,bytes}], schemaVersions{}}` |
| `comparison.v1.schema.json` | `comparison` | `{baseStudyId, againstStudyId, signalDeltas[], findingsAppeared[], findingsResolved[], findingsChanged[], comparable, incomparableReason?}` |
| `fault-guide.v1.schema.json` | *(front matter)* | Validates every `references/chaos/faults/*.md` header (FR-21) |

#### New PowerShell contracts

| Script | Key functions | Notes |
|---|---|---|
| `scripts/Study.ps1` | `New-Study`, `Get-StudyRoot`, `Resolve-StudyPath`, `Save-StudyArtifact`, `Complete-Study`, `Get-Study`, `Get-StudyIndex`, `Add-StudyIndexEntry`, `Add-CommandTrailEntry` | Sealing is one-way. `Save-StudyArtifact` on a sealed study throws `StudyAlreadySealed`. `Complete-Study` is the seal operation; it uses the approved `Complete` verb so the module passes `Get-Verb` linting, with `Seal-Study` registered as an alias for readability. |
| `scripts/Invoke-AzChaosClassic.ps1` | `Invoke-AzChaosClassic -Method -Path -Body` | Thin wrapper over `Invoke-AzRest.ps1`, api-version pinned in the promoted `scripts/Constants.ps1` (NFR-9). Exists only because the classic CLI was removed. Enable target, enable capability, create/start/cancel experiment, get execution details. |
| `scripts/Resolve-FaultPath.ps1` | `Resolve-FaultPath -SubscriptionId -TargetType` | Probes the v2 scenario catalog and the classic target-type catalog; returns `scenario` \| `experiment` \| `none` with the evidence for the answer. Never guesses. |
| `scripts/Get-K8sReadiness.ps1` | `Get-K8sReadiness -ClusterResourceId` | Seven checks, each `pass`/`fail`/`unknown` + remediation. `kubectl` is optional; its absence yields `unknown`, never `fail`. |
| `scripts/Get-StudySignals.ps1` | `Get-StudySignals -Window -Sources` | The FR-11 window pack. Composes the `[MAIN] chaos-impact` collectors; adds AKS metrics, Container Insights KQL and Prometheus. |
| `scripts/Build-StudyFindings.ps1` | `Build-StudyFindings -Plan -RunRecord -Signals` | **Pure.** No I/O, no `az`. Fully unit-testable. Produces findings **and** the mandatory limitations list. |
| `scripts/New-StudyReport.ps1` | `New-StudyReport -StudyPath` | Deterministic renderer over `skills/chaos-study-report/templates/study-report.html.tmpl`. HTML-escapes every injected value. |
| `scripts/Compare-Study.ps1` | `Compare-Study -Base -Against` | **Pure.** Refuses to compare across scopes or scenario families, with a stated `incomparableReason`. |
| `scripts/Preflight.ps1` `[E1]` | `+ Resolve-ToolPath` | Reshaped to optional-tool resolution; existing functions retained. |

#### Retained MCP contracts

All 18 tools keep their names, signatures and `{"ok": …}` / `{"ok": false, "errorType": …}` envelopes. No tool is removed or renamed in v0.4.x.

### Design Decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | **A study, not a loop, is the product unit.** | P3/P4. A dated, sealed, reportable artifact is what a team schedules a review around. A controller is not. |
| **D2** | **Five study skills: one entry + four supporting.** | G1/G2. One skill hides four genuinely independent jobs — "am I ready", "run it", "report it", "compare it" — that people ask for separately. Thirteen skills makes selection ambiguous. Five is the smallest set where each front door answers a question a user actually asks. The five shipped skills are not folded in or renamed in v0.4.x (NFR-10); collapsing the total from ten to five is a v0.5 question owned by Q12, decided with usage data rather than now. |
| **D3** | **Hard 200-line cap on every user-facing `SKILL.md`, enforced in CI.** | P2. `setup-scenario` reached 181 lines by accretion. Without a mechanical limit the fault pack would be re-inlined within two epics. |
| **D4** | **`az chaos` is the primary control plane; REST is a wrapped fallback.** | G5. `Invoke-AzChaos.ps1` already exists and already carries the retry/error contract. A second wrapper, not prompt-level `az rest`, preserves the "no ad-hoc calls" invariant. |
| **D5** | **`faultPath` is discovered at runtime, not assumed.** | The v2 CLI has no AKS scenarios and the classic CLI is gone. Hard-coding either path guarantees breakage when the catalog changes. The probe result is recorded in the manifest so a study is reproducible even after the catalog moves. |
| **D6** | **MCP is optional; absence selects the script path and is recorded.** | N2/P5. F5's real lesson is "never silently substitute", not "always hard-fail". Recording the substitution in the manifest and the report satisfies F5 without making an accelerator a dependency. |
| **D7** | **Immutable sealed studies; rerun creates a new study.** | F12/P4. Mutable results cannot be compared and cannot be trusted. Seal-then-append is also the cheapest correct concurrency model. |
| **D8** | **Findings carry severity + confidence + `mechanismProven`, replacing the three-verdict vocabulary as a user-facing concept.** | F6/F10. `CONFIRMED`/`REFUTED`/`NOT EXERCISED` is precise but unreadable in a report. The information is preserved: `mechanismProven: false` is exactly `NOT EXERCISED`, and it forces a Limitations entry. `verdict-matrix.md` is retained as the internal derivation table. |
| **D9** | **The model proposes; scripts compute.** | The one pattern worth keeping from `[PR32]`. The model writes the hypothesis and the prose; it cannot set a severity, a number, or a limitation. |
| **D10** | **Fault knowledge lives in a schema-validated guidance pack, one file per fault.** | P7/G9. Front matter makes guides machine-checkable; one file per fault makes a new fault a new file. |
| **D11** | **The HTML report is a single file with no external assets and no JavaScript requirement.** | NFR-7/NFR-8. Reports get emailed, attached to tickets and opened from `file://` on locked-down machines. A CDN dependency breaks all three. |
| **D12** | **Report rendering is deterministic except `generatedAt`.** | FR-17. Two reports must be diffable; a non-deterministic renderer makes comparison worthless. |
| **D13** | **Limitations are mandatory and script-generated.** | F14/P8. The most valuable sentence in a chaos report is "here is what we did *not* prove". Left optional, it is the first thing dropped. |
| **D14** | **Kubernetes is the first and only vertical in v0.4.0.** | G8. One complete vertical beats five shallow ones, and it is the only way to discover whether the `faultPath` split actually holds. |
| **D15** | **The `[E3]` validate/fix/revalidate gate and the two consent levels are preserved unchanged.** | G12/FR-9/FR-10. They are correct, tested, and the highest-risk code in the repository. Rewriting them for cosmetic consistency would be reckless. |
| **D16** | **The study store is built on the `[E2]` evidence primitives, not beside them.** | NFR-5/NFR-6. Redaction, canonicalization and the key denylist are the hardest-won code in `[E2]`. Forking them would double the audit surface. |
| **D17** | **PR #32 is closed and replaced, not extended.** | P9. Its state machine is the thing being removed; extending it would reintroduce P1–P4. |
| **D18** | **The eight `[E1]`-frozen contracts stay frozen through v0.4.x.** | NFR-10. Skill *surface* is changing; tool signatures, state files and impact schema v1 are not. The freeze tests remain the merge gate. |
| **D19** | **Speculative deterministic modules are deferred, not built.** | Revision 5 planned `scoring.py`, `analysis.py`, `verdict.py`, `proof.py`, `scope.py`, `availability.py`, a 30-case nDCG golden set and a mechanism-class ledger. None has a consumer in a study-shaped product. They are DEFERRED with a named revisit trigger, not silently dropped. |
| **D20** | **`chaos-study-history` needs no Azure call for `list`/`show`/`compare`.** | FR-15/NFR-11. Historical analysis must work offline, on a plane, after the subscription has been deleted. |

---
## Detailed Design

### 1. Study lifecycle and state

A study has exactly four states. There is no controller, no phase engine and no run-state document — the state **is** the presence of files on disk, which is why a cold conversation can resume without memory (N3, D1).

| State | Determined by | Permitted transitions |
|---|---|---|
| `PLANNED` | `study-plan.v1.json` exists, `SEALED` absent | → `EXECUTED`, → `SEALED` (blocked or abandoned plan) |
| `EXECUTED` | `run-record.v1.json` exists, `SEALED` absent | → `SEALED` |
| `SEALED` | `SEALED` marker + `manifest.json` exist | terminal |
| `ABANDONED` | `PLANNED` older than `CHAOS_STUDY_ABANDON_HOURS` (default 72) with no run record | → `SEALED` with `outcome: abandoned` |

`Get-Study` derives the state from the directory; it never reads a status field, because a status field can disagree with reality. A study that crashed mid-execution is `PLANNED` with a partial `evidence/` tree, and `chaos-study-run -StudyId <id> -Resume` re-enters at the first missing artifact.

Sealing is a three-step commit, in this order, so a crash at any point leaves a detectably incomplete study rather than a lying one:

1. Render `report.html` into a temp file, `fsync`, rename into place.
2. Compute SHA-256 over every file in the directory **except `manifest.json` and `SEALED`** (neither exists yet), write `manifest.json` atomically.
3. Create the `SEALED` marker, then append one record to `<scopeHash>/index.json`.

`index.json` is a **rebuildable cache, not a source of truth**. `Get-StudyIndex -Rebuild` reconstructs it by scanning sealed directories, so a lost or corrupt index costs a scan, never a study (NFR-6).

### 2. Consent, safety and abort

Three gates, each with a distinct trigger and a distinct exit code. The **broad permission consent** is `[E3]` code retained verbatim (D15); the other two are new in EPIC-010 and reuse the `[E3]` prompt mechanics.

| Gate | Trigger | Mechanism | Exit code | Owner |
|---|---|---|---|---|
| **Execution consent** | Any fault execution | Typed confirmation bound to `frozenConfigHash`; the plan card must have been rendered in the same invocation | `11` — declined | **New**, EPIC-010 |
| **Broad permission consent** | `Validate-AndFix` proposes a grant wider than the targeted proposal from `Build-TargetedGrantProposal` | `$env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX`, retained verbatim from `[E3]` | `4` — unconsented | `[E3]`, retained |
| **Drift abort** | `frozenConfigHash` at execute ≠ at validate | Abort with a rendered diff; no re-prompt, no auto-refreeze | `12` — drift | **New**, EPIC-010 |

**Abort conditions** are declared in the plan (FR-8) and evaluated by the poller, not the model. Each is a predicate over one collected signal with a threshold and a dwell time, e.g. `availableReplicas == 0 for any targeted Deployment for > 60s`. On breach, `chaos-study-run` issues `az chaos scenario run cancel` (v2) or the classic cancel (experiment path), records `abortedBy`, `abortedAtUtc` and the breaching predicate, and **still completes the post-window capture** — an aborted study is a valid study with a finding, not a discarded one.

`-DryRun` defaults to **true** on `chaos-study` (N8, Q4). A dry run performs **no Azure mutation** — it does write a local unsealed `study-plan.v1.json`, which is a local file, not a change to the user's cloud estate. To execute, the user must pass `-DryRun:$false` **and** type the consent string.

**N8 has one known exception, and it is in shipped code, not in this design.** `skills/run-scenario/SKILL.md:68` documents `$env:STARTCHAOS_NONINTERACTIVE=1`, and `Invoke-RunScenario.ps1:48` honours it to skip the confirmation prompt. The five new study skills **ignore that variable entirely** — there is no environment variable, flag or file that grants execution consent on the study path, and a test asserts it (E10-T6). Closing the legacy path is E15-T8; until it lands, N8 is a guarantee of the study suite, not of the whole plugin, and the release notes must say so.

### 3. The signal window pack (FR-11)

`Get-StudySignals` is the single answer to F2/F3/F4. It composes the shipped `[MAIN]` collectors rather than replacing them: `skills/chaos-impact/scripts/Get-MonitorSignals.ps1` and `Get-DiagnosticSettings.ps1` already implement metric, resource-log, Activity Log and alert-instance collection with the AlertsManagement `timeRange=custom` + `customTimeRange` contract and the `2023-05-01-preview` → `2018-05-05` fallback. That contract is **RETAINED unchanged**; the Kubernetes sources are added beside it.

| Window | Definition | Why |
|---|---|---|
| `pre` | `[runStart − baselineMinutes, runStart)` | Captured **before** execution starts, never reconstructed afterwards (F15) |
| `during` | `[runStart, runEnd)` | Half-open; the fault's own window |
| `post` | `[runEnd, runEnd + recoveryMinutes)` | Recovery evidence, and the only place "did it come back" can be answered |

`baselineMinutes` defaults to the run duration, floor 15, cap 120. `recoveryMinutes` defaults to `max(10, duration/2)`.

| Source | Path | Failure behaviour |
|---|---|---|
| AKS platform metrics | `Microsoft.Insights/metrics` on the cluster resource | `null` + caveat |
| Container Insights | Log Analytics query API — `KubePodInventory`, `KubeEvents`, `KubeNodeInventory`, `ContainerLog` (bounded) | `null` + caveat naming the missing table |
| Managed Prometheus | Azure Monitor workspace query, when the cluster has a Prometheus data-collection rule | Absent is `unknown`, never `fail` |
| Activity Log | Existing `[MAIN]` collector | Context only — **never** fault-landed proof (F15) |
| Alert instances | Existing `[MAIN]` AlertsManagement collector | `null` + caveat |
| Chaos run detail | `az chaos scenario run show` / classic execution details | Re-polled once on an empty first read (F15) |

Every source returns `{ source, window, requestedAt, values | null, caveat | null, queryDigest }`. A `null` with a caveat is a first-class result; a fabricated `0` is a contract violation with a dedicated test (NFR-3).

### 4. Findings derivation and the limitations taxonomy

`Build-StudyFindings` is a **pure function**: `(plan, runRecord, signals) → (findings[], limitations[])`. No `az`, no filesystem, no clock. That is what makes the most opinionated part of the product exhaustively testable offline (NFR-1, D9).

**Severity** is assigned from the measured delta against the plan's steady-state predicate — never by the model (D9):

| Severity | Rule |
|---|---|
| `critical` | Steady state breached and **not** recovered inside the `post` window |
| `high` | Steady state breached, recovered inside `post`, recovery longer than the declared objective |
| `medium` | Steady state breached and recovered within the declared objective |
| `low` | Steady state held, but a secondary signal degraded beyond its threshold |

**Confidence** is orthogonal to severity and is derived from `mechanismProven` plus source coverage. This is where the `[E2]` `verdict-matrix.md` survives as the internal derivation table (D8):

| `verdict-matrix.md` verdict | Study representation |
|---|---|
| `CONFIRMED` | `mechanismProven: true`, `confidence: high` |
| `REFUTED` | `mechanismProven: true`, finding with `severity: low` or none, `confidence: high` |
| `NOT EXERCISED` | `mechanismProven: false`, `confidence: low`, **and a mandatory limitation entry** |

`mechanismProven` is true only when a data-plane signal moved inside the `during` window in the direction the fault guide's `dataPlaneProof` predicts. Control-plane state — a run reporting `Succeeded`, a resource reporting `Disabled` — can never set it (F6, P8, FR-12).

**Limitations taxonomy** (FR-18, D13). `Build-StudyFindings` emits one entry per applicable class; the list is never empty because `L1` always applies:

| Class | Emitted when |
|---|---|
| `L1 scope` | Always — states exactly which resources were in the affected set and which were not |
| `L2 unknown-check` | Any readiness check returned `unknown` |
| `L3 absent-signal` | Any planned signal returned `null` |
| `L4 unproven-mechanism` | Any finding has `mechanismProven: false` |
| `L5 heuristic-proof` | The fault guide's `dataPlaneProof.coverage` is `heuristic` |
| `L6 advisory-targeting` | `resourceTargeting` was advisory only and was not transmitted to the service (`blast-radius.md`) |
| `L7 substituted-tool` | The manifest records a `toolSubstitutions[]` entry (FR-20) |
| `L8 aborted` | The run was cancelled by an abort condition |
| `L9 build-identity` | Build identity was established below rung 1 (F1) — recorded, never a gate |

### 5. Report contract (FR-16 – FR-19)

`report.html` is one file. Fixed section order, each mapped to a template region:

1. **Header** — study id, scope, date, `faultPath`, verdict banner.
2. **Executive summary** — the only model-authored prose block, visually marked `narrative`.
3. **What we tested** — hypothesis, steady-state predicate, fault URN and parameters, resolved blast radius, duration, abort conditions.
4. **What happened** — per-signal pre/during/post table with inline SVG sparklines, and a link to the Chaos Studio portal scenario report (N9 — linked, not reimplemented).
5. **Findings** — ordered by severity then confidence; each carries evidence references, `mechanismProven`, and coupling notes (F13).
6. **Limitations** — script-generated, mandatory, non-empty (D13).
7. **Remediation** — per finding: the change, where, expected observable effect, how to re-verify (FR-19).
8. **Appendix** — redacted command trail, api-versions, schema versions, tool substitutions, environment.

Determinism (D12, FR-17): the renderer sorts every collection by an explicit key, formats every number with an invariant culture and a fixed precision, emits no timestamps other than the single `generatedAt` slot, and derives nothing from a hash-set iteration order. The determinism test renders the same study twice, masks `generatedAt`, and asserts byte equality — plus a third render on a different OS in the Pester matrix.

Injection safety: `New-StudyReport` HTML-escapes every value drawn from Azure or from the model. The template contains no `<script>` and no `style` attribute sink; a Pester test asserts no rendered output contains `<script` or `javascript:` (NFR-8).

### 6. Comparison and rerun semantics (FR-15)

`Compare-Study` is pure and refuses to produce a misleading comparison. Two studies are **comparable** only when all of the following hold; otherwise `comparable: false` with a stated `incomparableReason` and no deltas:

- identical `scopeHash`;
- identical fault URN **and** capability version;
- identical `faultPath`;
- steady-state predicate identical after normalisation;
- window lengths within ±20%.

When comparable, the output carries per-signal deltas (`base`, `against`, `delta`, `direction`), `findingsAppeared[]`, `findingsResolved[]`, `findingsChanged[]` (severity or confidence moved), and an overall `improved | regressed | mixed | unchanged`. Findings are matched on a stable `findingKey` = hash of (fault URN, signal, predicate) — **not** on the title, which is model-influenced.

`-Rerun` copies the plan verbatim into a new `PLANNED` study with `derivedFrom: <baseStudyId>`, refreshes nothing except the resolved blast radius (resources may have changed) and surfaces any drift in the plan card before consent.

### 7. Progressive discovery mechanics

The mechanism is deliberately dumb, because clever routing is what makes prompts grow (P2, D3). **Steps 1–3 are prompt instruction; step 4 is the test-enforced guarantee.** We cannot test that a model read exactly one guide; we can and do test that the pack is well-formed, complete and additive, which is what makes the instruction followable.

1. Every `SKILL.md` contains one routing instruction and no fault parameters. *(prompt)*
2. `references/chaos/faults/_index.md` is a single table: `faultUrn | vertical | faultPath | guide | dataPlaneProof.coverage`. *(artifact)*
3. The model reads `_index.md`, picks one row, and reads exactly one guide. *(prompt)*
4. `Test-FaultGuideIndex` (Pester) asserts the index and the guide files are in bijection, that every guide validates against `fault-guide.v1.schema.json`, and that no `SKILL.md` contains a `faultUrn` or a `jsonSpec` literal. A guide with `dataPlaneProof.coverage: none` fails the schema and cannot ship. *(enforced)*

A new fault is therefore: one new guide file, one new index row, one schema-validated front matter block. No script change, no skill change, no test change (G9).

### 8. Error and exit-code contract

Exit codes are **additive, never reassigned**. The shipped skills already use `0`–`4`, verified in `skills/setup-scenario/scripts/Invoke-SetupScenario.ps1` (lines 34, 39, 139, 175, 313) and pinned by `SetupExitContract.Tests.ps1`. The study suite therefore starts a **new block at 10** rather than colliding with them.

| Code | Meaning | Owner |
|---|---|---|
| `0` | Success | `[MAIN]`, all skills |
| `1` | Unexpected error, or caller targeting starves the blast radius | `[MAIN]`/`[E3]` |
| `2` | `setup-scenario`: scenario selection required | `[MAIN]` — **not reused** |
| `3` | `setup-scenario`: parameter mode required | `[MAIN]` — **not reused** |
| `4` | Broad permission fix unconsented | `[E3]`, retained verbatim; propagated unchanged by `chaos-study-run` |
| `10` | Readiness/preflight failed — remediation printed | New |
| `11` | Execution consent declined | New |
| `12` | Configuration drift between validate and execute | New |
| `13` | `StudyAlreadySealed` — write attempted on a sealed study | New |
| `14` | `FaultPathUnavailable` — the capability probe returned `none` | New |
| `15` | `StudyIncomparable` — compare refused, reason printed | New |

### 9. Testing strategy

No new harness is introduced. Every suite lands under a path the existing CI already scans: Pester at `Run.Path = './copilot-cli-plugin/skills'` (so shared-script tests live under `skills/*/tests/`, as `[E1]`/`[E2]` already do), pytest with `_TEST_TRANSPORT`, and `ruff check chaos_mcp tests`.

| Layer | What is tested | How |
|---|---|---|
| Pure functions | `Build-StudyFindings`, `Compare-Study`, `Resolve-BlastRadius`, `Build-TargetedGrantProposal` | Table-driven Pester over JSON fixtures. No mocks needed — they take data and return data. |
| Study store | Sealing, immutability, atomicity, index rebuild, path canonicalization, redaction, root-location assertions | Pester against a temp `CHAOS_STUDY_ROOT`, mirroring `[E2] State.Tests.ps1` |
| Collectors | `Get-StudySignals`, `Get-K8sReadiness`, `Resolve-FaultPath` | Recorded-response replay, extending the `[MAIN] chaos-impact` offline-replay harness pattern (`tests/e2e/Run-OfflineReplay.ps1`) |
| Renderer | Determinism, HTML escaping, no external assets, no `<script>`, size bound | Golden-file Pester with a masked `generatedAt` |
| Contracts | Skill line caps, `optionalTools` front matter, fault-guide index bijection, schema validity, api-version pin liveness | Lint-style Pester + the existing pytest manifest tests |
| Regression freeze | 15 original MCP tool names/signatures/envelopes, `FROZEN_SKILLS`, `impactReportSchemaVersion: 1`, state-file compatibility | `[E1]`/`[E2]` freeze tests, extended not replaced (D18) |

**No test requires Azure.** Live verification is a separate, manually invoked Phase-2 exercise against a disposable subscription, and its results are recorded in this document, not in CI.

Three golden studies are committed as fixtures and drive the report and comparison tests: a clean pass, a `critical` finding with proven mechanism, and a `NOT EXERCISED` study with an aborted run.

---

## Chaos Studio Product Issues

Service and product gaps, not plugin work. The suite degrades explicitly around each; each should be filed with the Chaos Studio service team. **Nothing in the Implementation Plan is blocked on these being fixed.**

| ID | Issue | Evidence | Behaviour in this plan |
|---|---|---|---|
| **CS-1** | `scenarioRunSummary[].actionName` returns `null` | F7 — null on all three actions of run `f7cf6241` | Label by `actionUrn`; record `actionNameSource`; never invent a name (FR-13) |
| **CS-2** | `run start --no-wait` returns an empty 2xx with no run id | F7 — every run required a `run list` filtered on `startTime` | Deterministic run-id recovery, failing loudly rather than returning null (FR-13) |
| **CS-3** | No per-leg data-plane disruption attestation; the service reports intended mutation only | F6 — Event Hubs `Disabled` while sends were 60/60 successful | `mechanismProven: false` unless an independent data-plane signal moved; forces limitation `L4` |
| **CS-4** | `RecommendationStatus` carries no `notRecommendedReason` | Eligibility gaps are otherwise unexplainable | Readiness synthesises a reason from capability-map misses; otherwise `unknown` |
| **CS-5** | Permission blockers are readable only through a **configuration-scoped** `validations/latest`; there is no workspace- or scenario-scoped "would this be permitted?" read | TypeSpec: `Validation` is `@parentResource(ScenarioConfiguration)` `@singleton("latest")` | `chaos-study-scope` reports `permissionBlockers: null` with a reason; authoritative blockers come from `chaos-study-run`, which creates a configuration anyway |
| **CS-6** | Per-fault data-plane semantics are undocumented | F6, F8 | The fault guidance pack (EPIC-005) with `dataPlaneProof.coverage` surfaced in the plan **and** the report |
| **CS-7** | Exclusion-based leg starvation is undiscoverable, and `resourceTargeting` include/exclude is **not accepted by `az chaos scenario config create`** | `[E3] blast-radius.md` | Targeting is labelled advisory in the plan card and forces limitation `L6` |
| **CS-8** | No published v2 service limits, run-history retention, or cancel semantics | API research | Configurable safety caps; the study store is the retention answer, not the service |
| **CS-9** | The v2 Scenarios catalog contains **no AKS scenario templates** | Catalog review | `faultPath` probe falls back to the classic experiment path (D5) |
| **CS-10** | The classic CLI surface (`az chaos experiment`/`target`/`capability`/`target-type`) was **removed** without a v2 equivalent for Kubernetes — a capability regression for AKS users | Learn pages 404; extension reference lists only the v2 verbs | `Invoke-AzChaosClassic.ps1`, a pinned REST wrapper (FR-5). This is the single highest-value product fix on this list. |
| **CS-11** | Every AKS fault requires in-cluster Chaos Mesh in the `chaos-testing` namespace — no other namespace is supported, Linux node pools only, and the fault's own control plane shares the failure domain it is testing | Fault library prerequisites | Readiness reports it as a check; the guides carry it as a `knownLimitation` |
| **CS-12** | The v2 surface is preview-only with no documented deprecation window, and two preview versions (`2026-05-01-preview`, `2026-08-01-preview`) are in play with no published difference | Repo pins vs external spec research | Stay on the shipped `2026-05-01-preview`; single pin per language (NFR-9); contract tests fail loudly on shape change; a bump is evidence-gated (E15-T7) |

**Reverse Advisor flow (proposal, not a dependency).** F9 showed Advisor is anti-correlated with behaviour-under-fault findings. The useful direction is reversed: a sealed study could optionally emit a chaos-proven finding in an Advisor-candidate shape. This is a partner-team conversation, not scheduled work (N7, Q13).

---

## Alternatives Considered

**ALT-1 — One monolithic `chaos-study` skill.**
*Pros:* one front door, zero selection ambiguity, no cross-skill contracts. *Cons:* the file cannot stay under 200 lines while covering readiness, execution, reporting and comparison, so D3 fails immediately; and it forecloses the four questions users genuinely ask separately ("am I ready", "run it", "report it", "did it improve"). **Rejected** — but this is the closest alternative, and it is the reason the entry skill is *opinionated and end-to-end* rather than a menu. Revisit is Q8.

**ALT-2 — Keep the Revision 5 eight-peer-skill design.**
*Pros:* already specified in detail; each skill is small. *Cons:* thirteen user-facing front doors (P1); no obvious entry point (G1 fails); and five of the eight had no consumer for their output. **Rejected.** The deterministic modules underneath are DEFERRED, not deleted (D19).

**ALT-3 — Extend the `[PR32]` chaos-loop controller.**
*Pros:* a working state machine exists; less new code. *Cons:* a single state document is one failure domain (F14 showed the degradation-to-manual failure directly), repo-local `tmp/` state is exactly F12, and the hard-coded catalog is exactly the fabrication risk. **Rejected** (D17, P9). Four patterns are re-expressed and credited; the controller is not.

**ALT-4 — Markdown-only report.**
*Pros:* trivially diffable; renders in every tool; the `[MAIN] chaos-impact` renderer already produces Markdown. *Cons:* no sparklines, no severity colour, no collapsible evidence; P3 is a *presentation* problem as much as a content one, and a Markdown file does not survive being forwarded to a stakeholder. **Rejected as the primary**, retained as `-Format md` (Q5).

**ALT-5 — HTML report using a JS charting library from a CDN.**
*Pros:* interactive charts for little effort. *Cons:* breaks `file://` opening, breaks air-gapped and locked-down machines, breaks email attachment, and introduces a supply-chain dependency into an artifact that is meant to be evidence. **Rejected** (D11, NFR-7/8). Inline SVG sparklines rendered by the script cover the actual need.

**ALT-6 — Store studies in the `[E2]` evidence store with no separate immutable layer.**
*Pros:* one store, no new code, redaction and atomicity already proved. *Cons:* the evidence store is keyed by `runId`, is mutable by design, and has a 90-day retention default — it answers "what did this run see", not "what did we learn in March". Overloading it would either make evidence immutable (breaking its callers) or make studies mutable (breaking D7/FR-14). **Rejected**; the study store is *built on* the `[E2]` primitives instead (D16).

**ALT-7 — Keep `requiredTools` and hard-fail when MCP tools are absent.**
*Pros:* the `[E1]` behaviour, already shipped and tested; the strongest possible answer to F5. *Cons:* it makes an optional accelerator a hard dependency of a product that is supposed to run on `az chaos` alone (P5, N2). **Rejected as the default**; the capability is retained under a `requiredTools` fixture so nothing is lost, and F5's real invariant — never substitute *silently* — is preserved through `toolSubstitutions[]` in the manifest and the report appendix (D6).

**ALT-8 — Wait for v2 AKS scenario templates instead of building a classic REST fallback.**
*Pros:* no second control-plane path, no REST wrapper, no api-version to maintain. *Cons:* the timeline is unknown and unowned (CS-9, Q2), and G8 — Kubernetes as the first vertical — is the whole point of the release. **Rejected**, but deliberately hedged: `faultPath` is probed at runtime (D5), so the day v2 gains AKS scenarios the probe selects them and the wrapper becomes dead code deleted in one commit.

**ALT-9 — Inline fault parameters into the skills instead of a guidance pack.**
*Pros:* fewer files; no routing indirection; the model does not need a second read. *Cons:* this is precisely how `setup-scenario` reached 181 lines, and it makes every new fault a prompt edit and a regression risk across all five skills. **Rejected** (D10, P7).

---

## Dependencies

**External**

| Dependency | Version / pin | Notes |
|---|---|---|
| Azure CLI | ≥ 2.75.0 | Hard floor for the `chaos` extension |
| `chaos` CLI extension | v2 surface, preview (`1.0.0b*`) | `az chaos setup` / `show-discovery` / `show-evaluation` / `workspace wait` are GA; the rest is preview |
| Chaos Studio v2 ARM | **`2026-05-01-preview`** — the shipped pin, unchanged in v0.4.0 | `2026-08-01-preview` exists but is not adopted without runtime evidence (CS-12, E15-T7) |
| Chaos Studio classic ARM | `2025-01-01` (GA) | Targets, capabilities, experiments — reached only via `Invoke-AzChaosClassic.ps1` (CS-10) |
| Azure Monitor metrics + Log Analytics query API | Existing `[MAIN]` pins | Reused unchanged |
| `Microsoft.AlertsManagement` | `2023-05-01-preview` → `2018-05-05` fallback | Shipped contract, RETAINED verbatim |
| Chaos Mesh in-cluster | ≥ the version the fault library requires, namespace `chaos-testing` | User-installed; the suite checks, it does not install (Q3) |
| Container Insights / managed Prometheus | — | **Optional providers.** Absence of either is `unknown` and never blocks; a plan blocks only under FR-7a |
| PowerShell | 7.x | Report rendering is PowerShell-only — no Node, no Python, no browser (NFR-7) |
| Pester | ≥ 5.5.0 | Existing CI pin |
| Python + `mcp`, `httpx`, `jsonschema` | `mcp>=1.2.0,<2`; `jsonschema` promoted to a hard test dep by `[E1]` | **Optional at runtime**, required for the MCP test matrix |
| `kubectl` / `helm` | — | **Optional.** Absence yields `unknown` on the Chaos Mesh checks, never `fail` |

**Internal**

- The `[MAIN]` `Invoke-AzChaos.ps1` / `Invoke-AzRest.ps1` / `Ensure-AzLogin.ps1` / `Wait-AzureLro.ps1` seam. Everything routes through it (FR-5).
- The `[E2]` evidence primitives — canonicalization, redaction denylist, `$CHAOS_KEY_DIR` denial, atomic revisioned write. The study store depends on these directly (D16).
- The `[E3]` validate/fix/revalidate gate and both consent gates (D15).
- The `[MAIN] chaos-impact` collectors and offline-replay harness.
- Synchronised versioning across `plugin.json`, `mcp/pyproject.toml`, `.github/plugin/marketplace.json`.
- CI paths in `.github/workflows/test.yml` — unchanged; new tests land under paths it already scans.

**Sequencing**

`EPIC-003` must land before anything (it was uncommitted; landed at `283cb61`). The study store (EPIC-004) must land before any skill that persists. The fault pack (EPIC-005) must land before `chaos-study-scope` can propose a fault. `Resolve-FaultPath` (EPIC-007) must land before `chaos-study-run` can execute. `Get-StudySignals` (EPIC-009) must land before findings (EPIC-011). Findings must land before the report (EPIC-012). Nothing depends on the MCP reshape (EPIC-006) except the manifest field it writes.

---

## Impact Analysis

**Codebase areas.** `copilot-cli-plugin/skills/` (five new skill directories; two shipped `SKILL.md` files shrink), `copilot-cli-plugin/scripts/` (seven new scripts, three reshaped, `Constants.ps1` promoted), `copilot-cli-plugin/references/chaos/` (two principle docs, fifteen guidance files), `copilot-cli-plugin/schemas/` (five new schemas), `mcp/chaos_mcp/` (front-matter parsing only — no tool changes), package manifests, and docs. **`.github/workflows/test.yml` is unchanged.**

**Backward compatibility.** Additive through v0.4.x (NFR-10, D18):

| Surface | Guarantee |
|---|---|
| Five shipped skill names and triggers | Unchanged in v0.4.x. Deprecation, if any, is decided in Q12 and takes two minor releases. |
| 18 MCP tool names, signatures, envelopes | Unchanged. Nothing removed or renamed. |
| `$env:STARTCHAOS_STATE_PATH` and the v1 state schema | Unchanged; existing state files still resume |
| `impactReportSchemaVersion: 1` | Unchanged |
| `[E2]` evidence store layout and env vars | Unchanged; the study store is a sibling, not a migration |
| `requiredTools:` front matter | Still parsed and honoured where present (FR-20) |

**Performance.** `Get-StudySignals` replaces N hand-assembled round trips with one composed call (F2) — the same win `chaos-impact` already banked. The heaviest new cost is Log Analytics queries over the three windows; they are bounded by row caps and by an explicit `truncated: true` flag. Report rendering is local string substitution: sub-second. `chaos-study-history list/show/compare` makes **zero** Azure calls (D20).

**Operational.** One new on-disk location (`$CHAOS_STUDY_ROOT`) needs a documented per-OS default, a size expectation, and a purge command. A typical study is a few hundred KB of JSON plus a report under 2 MB (NFR-8); at the 365-day default this is tens of MB per scope. Debuggability improves materially: the redacted command trail (FR-22) means a failed study can be reproduced from the manifest without re-running the conversation.

---

## Security Considerations

- **Auth.** Unchanged. The existing `chaos_set_auth_mode` lever (`cli` vs `managed-identity`) governs everything; no new credential path is introduced.
- **Least privilege.** Readiness and history need `Reader`. Execution needs `Chaos Studio Experiment Contributor` on the workspace or experiment, plus `Azure Kubernetes Service Cluster Admin Role` on the cluster for the experiment's managed identity. Targeted grants from `Build-TargetedGrantProposal` are always proposed before the broad fix, and the broad fix keeps its separate consent (NFR-4, D15).
- **Secret hygiene.** The study store inherits the `[E2]` redaction — by key name and by value shape (bearer, JWT, hex ≥ 32, base64 ≥ 40) — applied **on write and on read**, plus the `$CHAOS_KEY_DIR` denylist. The command trail is redacted argument-by-argument before it is written, not after. A dedicated test asserts that a token planted in every input surface (plan, signals, error text, `az` argv) appears nowhere in a sealed study (NFR-5).
- **Attack surface — new.** Two additions, both small. (1) `Invoke-AzChaosClassic.ps1` widens the ARM surface the plugin can reach; it is constrained to a fixed allowlist of classic Chaos paths and a pinned api-version, and a Pester test asserts no caller can pass an arbitrary path. (2) `report.html` embeds Azure-sourced and model-sourced strings; every injection point is HTML-escaped and the template has no script sink.
- **Attack surface — removed.** Revision 5's source-repository reading (local clone analysis) is DEFERRED and unbuilt, removing the largest single surface that design carried (Q14).
- **Study store permissions.** Created user-only (`0700` equivalent). It contains resource IDs, telemetry aggregates and findings — sensitive but not secret. Documented as such. Purge requires an explicit confirmed command and never runs implicitly (NFR-12).
- **Destructive-action gating.** `destructiveHint: true` remains on `chaos_execute_scenario` and `chaos_cancel_scenario_run` so MCP hosts prompt. The script path's equivalent is the typed consent bound to `frozenConfigHash`.
- **Portability caveat.** A sealed study is portable by design (NFR-11), which means it is also *exfiltratable*. The report footer states plainly what the file contains so a user can make an informed sharing decision.

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| The classic REST path breaks when the classic model is retired | Medium | High | `Resolve-FaultPath` probes rather than assumes (D5); the manifest records which path a study used, so a broken path is diagnosable, not mysterious. CS-10 is filed. Deleting the wrapper when v2 gains AKS scenarios is a one-commit change (ALT-8). |
| Chaos Mesh is absent, or in the wrong namespace, on most target clusters — so most first runs are blocked | **High** | Medium | Readiness is a *first-class deliverable*, not an error path: seven checks, each with the exact remediation command, written into a `blocked` plan the user can act on and re-run (Flow C). The suite never installs into a cluster (Q3). |
| Data-plane proof is heuristic for most faults at launch, so `mechanismProven` is false and findings read as weak | **High at launch** | High | This is the honest state and it is surfaced, not hidden: `dataPlaneProof.coverage` appears in the plan *before* consent and in Limitations `L5` after. The mitigation is coverage work in EPIC-005, prioritised on the three Kubernetes scenarios, not a softer verdict rule. |
| The 200-line cap is met by moving prose into `references/`, and the *reference* layer becomes the bloat | Medium | Medium | The fault-guide schema caps what a guide may contain (FR-21), and the index-bijection test prevents unreferenced files accumulating. The principle docs are capped by review, which is weaker — called out as a known soft spot. |
| Five skills still confuse users; they invoke `chaos-study-run` first and get a "no plan" error | Medium | Medium | Every supporting skill degrades explicitly (FR-2): given no plan, `chaos-study-run` runs the scope step itself rather than failing. `chaos-study` is the documented and marketed front door. Re-evaluated in Q8 after the first usability round. |
| The report is polished but says nothing useful, because the signals were absent | Medium | High | FR-7a applies at *plan* time, not report time: a plan whose steady-state predicate cannot be evaluated by any available source is marked `blocked` with the missing source named. The user learns before executing, not after. |
| Deterministic rendering breaks across OS (line endings, culture, sort order) | Medium | Low | Invariant culture and explicit sort keys are contractual (D12); the Pester OS matrix already runs on Windows, Linux and macOS, and the determinism test runs on all three. |
| ~~Uncommitted `[E3]` work is lost from the dirty worktree~~ **RETIRED — closed by `283cb61`** | — | — | Phase 0 landed EPIC-003 in full, including `blast-radius.md` and both `tests/` directories. Nothing from the dirty worktree was lost; `.gitignore` was checked not to shadow the newly tracked paths. |
| Study store grows unbounded | Low | Low | `CHAOS_STUDY_RETENTION_DAYS` (365) plus an explicit purge; raw telemetry is stored as aggregates, not row dumps |
| The model writes a severity or a number into the narrative slot that contradicts the computed one | Medium | High | The narrative slots are separate template regions marked `narrative`; findings, severities and limitations are rendered from `findings.v1.json` only. A test asserts the renderer ignores any severity-shaped token in the narrative input. |
| Scope creep back toward a controller | Medium | High | D1/D17/N3 are explicit, and there is no run-state document to accrete into one — state is the filesystem (§Detailed Design 1). |

---

## Open Questions

Each has a stated lean so implementation is not blocked. A lean is a default, not a decision.

| # | Question | Why it matters | Lean | Owner |
|---|---|---|---|---|
| **Q1** | Is the classic REST `faultPath` acceptable for GA, or must Kubernetes wait for v2 scenario coverage? | Determines whether EPIC-007 ships or the release slips | **Ship the probe + wrapper.** It is bounded (one allowlisted wrapper), reversible (delete when v2 lands) and it is the only way G8 happens this release. | Chaos Studio engineering |
| **Q2** | What are the "upcoming Kubernetes faults", and when? | The brief names them; no public source describes them | **Encode nothing.** The guidance pack is additive by construction (G9), so a new fault is a file. Needs a product answer before it can be scheduled. | Chaos Studio product |
| **Q3** | Should the suite help install Chaos Mesh, or only detect its absence? | It is the most likely first-run blocker | **Detect and instruct only.** Installing into a user's cluster from a chaos tool is a trust boundary we should not cross. Revisit if readiness-blocked runs dominate telemetry. | Copilot plugin owners |
| **Q4** | Should `chaos-study` default to `-DryRun:$true`? | Trades safety against a two-step first experience | **Yes, default true.** N8 is non-negotiable; the plan card is genuinely useful on its own. | Copilot plugin owners |
| **Q5** | Do we ship the Markdown report format, or HTML only? | One more renderer to keep deterministic | **Ship HTML in v0.4.0; Markdown behind `-Format md` only if asked for.** The `chaos-impact` Markdown renderer already covers the diff-in-a-PR use case. | Copilot plugin owners |
| **Q6** | Do we need `chaos_study_*` MCP tools? | Determines whether the MCP registry grows from 18 to 21 | **Defer.** No host has asked for cross-process study access. Add only on a real request. | Copilot plugin owners |
| **Q7** | What is the per-OS default for `$CHAOS_STUDY_ROOT`, and is 365 days the right retention? | Affects portability, backup and support | **`%LOCALAPPDATA%\chaos-studio\studies` / `$XDG_DATA_HOME/chaos-studio/studies` / `~/Library/Application Support/chaos-studio/studies`; 365 days.** Needs one review pass with support. | Copilot plugin owners |
| **Q8** | Is five skills the right number, or should report fold into run? | Directly tests D2 | **Keep five** until the first usability round. `chaos-study-report` is separately invocable against a *sealed* study, which run cannot be. | Copilot plugin owners |
| **Q9** | Are the five comparability conditions too strict? | Too strict and compare is useless; too loose and it lies | **Start strict.** A refused comparison with a stated reason is recoverable; a misleading delta is not. Relax on evidence. | Chaos Studio engineering |
| **Q10** | When a cluster has both Container Insights and managed Prometheus, which is authoritative? | Two sources can disagree, and a report cannot shrug | **Prometheus for rate/gauge series, Container Insights for events and inventory; record `signalSource` on every value; on disagreement report both and add a limitation.** Needs Azure Monitor partner review. | Azure Monitor partners |
| **Q11** | The third recorded App Insights query failure was never explained | Two of three causes are known and implemented; the third is not | **Leave unimplemented.** Building a mitigation for an unidentified cause is how the falsified `first`-is-reserved theory nearly shipped. Reopen if it recurs. | Copilot plugin owners |
| **Q12** | Do the five shipped skills stay, get aliased into the study suite, or get deprecated? | Determines the v0.5 surface and the migration cost | **Stay unchanged in v0.4.x.** They are the low-level verbs; the study suite is the workflow. Re-evaluate at v0.5 with usage data; any deprecation gets two minor releases. | Copilot plugin owners |
| **Q13** | Do we pursue the reverse-Advisor flow? | Would give chaos findings a first-party destination | **Not scheduled.** Propose it to the Advisor team; build nothing until they commit. | Chaos Studio product |
| **Q14** | Is source/IaC analysis permanently out, or deferred? | It was a large part of Revision 5 and the largest attack surface | **Deferred with a named trigger:** revisit only if findings routinely cannot be acted on without code context. Revisit is a new design doc, not an epic here. | Chaos Studio engineering |

---

## Migration and Disposition

**This is the single authoritative disposition table.** Every asset appears exactly once.

### `[MAIN]` — shipped at `55c74c5`

| Asset | Disposition | Detail |
|---|---|---|
| `skills/start-chaos`, `create-workspace`, `setup-scenario`, `run-scenario`, `chaos-impact` | **RETAINED** | Names, triggers and behaviour unchanged in v0.4.x (NFR-10, Q12). `setup-scenario/SKILL.md` and `run-scenario/SKILL.md` shrink as `[E3]` narrative moves into `references/chaos/` — behaviour identical. |
| `agents/start-chaos.md` | **RESHAPED** | The "no ad-hoc `az chaos` / `az rest`" invariant is extended to name `Invoke-AzChaosClassic.ps1` as the only permitted classic path. |
| `scripts/Invoke-AzChaos.ps1`, `Invoke-AzRest.ps1`, `Ensure-AzLogin.ps1`, `Wait-AzureLro.ps1` | **RETAINED** | The load-bearing seam. Unmodified. |
| `scripts/Render.ps1` (`Write-Card`, `Write-Table`, `Write-Error-Card`) | **RETAINED** | Extended by `[E3]`, not rewritten. |
| `scripts/New-RunReport.ps1` | **RETAINED** | Its token-substitution pattern is the model for `New-StudyReport.ps1`. |
| `skills/chaos-impact/**` — schema v1, KQL templates, `metrics/defaults.json`, collectors, offline replay | **RETAINED** | `Get-StudySignals` composes these collectors. `impactReportSchemaVersion: 1` frozen (D18). |
| `skills/chaos-impact/scripts/Constants.ps1` | **RESHAPED** | Promoted to `copilot-cli-plugin/scripts/Constants.ps1` with a dot-source shim at the old path for one minor version (NFR-9, E7-T1). |
| `mcp/chaos_mcp/{server.py,azure.py,monitor.py}` — 15 tools | **RETAINED** | Names, signatures and envelopes frozen. `server.py` gains no new tool in v0.4.0 (Q6). |
| `plugin.json`, `marketplace.json`, `mcp/pyproject.toml` | **RESHAPED** | Version → 0.4.0; five skill registrations added. Synchronised in one commit (E15-T1). |
| `.github/workflows/test.yml`, `release.yml`, Dependabot | **RETAINED** | Unchanged. New tests land under already-scanned paths. |

### `[E1]` — EPIC-001, `5257c2a`

| Asset | Disposition | Detail |
|---|---|---|
| `mcp/chaos_mcp/apiversions.py` + dead-pin lint test | **RETAINED** | Extended to cover the promoted PowerShell `Constants.ps1` (NFR-9). |
| `mcp/tests/test_lifecycle_contract.py`, `test_tool_manifest.py`, `FROZEN_SKILLS` | **RETAINED** | The merge gate. `FROZEN_SKILLS` gains the five new skills at their v0.4.0 descriptions. |
| `scripts/Preflight.ps1` — `Get-PreflightFailurePrefix`, `Get-SkillRequiredTools`, `Test-RequiredTools`, `Assert-RequiredTools` | **RESHAPED** | All four functions kept. `Resolve-ToolPath` added; `Assert-RequiredTools` is no longer called by the new skills but remains callable and tested (FR-20, D6). |
| `requiredTools:` front matter on the five shipped skills | **RETAINED** | Still parsed and honoured. New skills declare `optionalTools:`. |
| `skills/start-chaos/tests/Preflight.Tests.ps1` | **RESHAPED** | Fail-fast cases move to a `requiredTools` fixture; `optionalTools` substitution cases added. Nothing deleted. |
| `jsonschema` as a hard test dependency | **RETAINED** | Now also validates the five new schemas and the fault-guide front matter. |

### `[E2]` — EPIC-002, `4befd5e`

| Asset | Disposition | Detail |
|---|---|---|
| `mcp/chaos_mcp/evidence.py` — canonicalization, key denylist, redaction, atomic revisioned writes | **RETAINED** | Unmodified. The study store reuses the same guarantees in PowerShell rather than forking the Python (D16). |
| `scripts/State.ps1` — `Get-EvidenceRoot`, `Get-EvidenceScopeHash`, `Save-StateToEvidence`, `Mirror-State`, `Import-State` | **RESHAPED** | `Get-EvidenceScopeHash` and the redaction lists are exported for `Study.ps1`; `$env:STARTCHAOS_STATE_PATH` semantics unchanged. |
| Schemas `run-record.v1`, `evidence-bundle.v1` | **RETAINED** | `run-record.v1` is written into every study directory unchanged. |
| Schemas `availability.v1`, `diagnosis.v1`, `hypotheses.v1`, `inventory.v1`, `mechanism-ledger.v1`, `recommendations.v1`, `scope-setup.v1` | **DEFERRED** | On disk, schema-validated by CI, **no producer in v0.4.0**. They are the contract surface for the deferred Revision 5 modules (D19). Revisit trigger: a consumer exists. |
| MCP tools `chaos_evidence_put` / `_get` / `_list` | **RETAINED** | Unchanged. No study siblings in v0.4.0 (Q6). |
| `references/chaos/evidence-contract.md` | **RESHAPED** | Extended with a study-store section describing sealing and the evidence/study boundary. |
| `references/chaos/verdict-matrix.md` | **RESHAPED** | Demoted from user-facing vocabulary to the internal derivation table behind `severity` / `confidence` / `mechanismProven` (D8). Content retained. |
| `mcp/tests/test_evidence.py`, `skills/start-chaos/tests/State.Tests.ps1` | **RETAINED** | Unmodified. |

### `[E3]` — EPIC-003, commit `283cb61` (uncommitted working tree at planning time; landed in Phase 0)

**All of it is RETAINED or RESHAPED. Nothing here is discarded. Landing it was Phase 0 and is complete.**

| Asset | Disposition | Detail |
|---|---|---|
| `scripts/Validate-AndFix.ps1` (+250) — `Test-StructuredValidationError`, `ConvertTo-ValidationBlocker`, `Build-RoleAssignmentRemediation`, validate → fix → revalidate, broad-fix consent | **RETAINED verbatim** | The highest-risk code in the repository. Not rewritten for cosmetic consistency (D15, FR-9, FR-10). |
| `scripts/Rbac.ps1` (+74) — `Build-TargetedGrantProposal` | **RETAINED** | Pure function; called by `chaos-study-run` before any broad fix is offered. |
| `scripts/Render.ps1` (+224) — `Resolve-BlastRadius`, `Write-BlastRadiusCard` | **RETAINED** | `Resolve-BlastRadius` is called directly by `chaos-study-scope`. |
| `references/chaos/blast-radius.md` (198 lines, **untracked at planning time**) | **RETAINED verbatim** | Including the load-bearing honesty note that `resourceTargeting` is advisory and never transmitted (CS-7 → limitation `L6`). **`git add`-ed in Phase 0; tracked as of `283cb61`.** |
| `skills/setup-scenario/tests/{BlastRadius,PermissionBlockers,SetupExitContract}.Tests.ps1`, `skills/run-scenario/tests/PreExecuteGate.Tests.ps1` (**untracked at planning time**) | **RETAINED** | 1,242 lines of Pester. Tracked as of `283cb61`. |
| `skills/setup-scenario/scripts/Invoke-SetupScenario.ps1` (+88), `skills/run-scenario/scripts/Invoke-RunScenario.ps1` (+13) | **RETAINED** | The skill-level wiring of the gate and the pre-execute check. Exit codes `2`, `3`, `4` are emitted here and are frozen by E3-T6/E15-T5; `chaos-study-run` dot-sources `Invoke-RunScenario.ps1` in place rather than moving it (NFR-10). |
| `server.py` (+188) — normalised blockers, `build_targeted_grant_proposal()` | **RETAINED** | Additive on an existing tool; no signature change. |
| `mcp/tests/test_lifecycle_contract.py` (+259) | **RETAINED** | — |
| `skills/setup-scenario/SKILL.md` (+70), `skills/run-scenario/SKILL.md` (+38) | **RESHAPED** | The narrative added here moves to `references/chaos/blast-radius.md` (already written) and the new principle docs; the skills keep a routing pointer. This is the P2 correction, and it is the only `[E3]` change that is undone — the *content* survives, its *location* changes. |

### `[PR32]` — chaos-loop prototype, never merged

| Asset | Disposition | Detail |
|---|---|---|
| `skills/chaos-loop` + `advisory`/`coding` phase skills | **REMOVED** | Rescoped and replaced (D17, P9). Not on main; nothing to delete on disk. |
| `scripts/chaos_loop_state.py` state machine | **REMOVED** | Not ported. No epic depends on it. |
| `references/chaos-loop/scenario-catalog.v1.json` | **REMOVED** | Hard-coded catalogs are the fabrication risk (ALT-3). Scenario names come from a service response or from a guide's `faultUrn` only. |
| Repo-local `tmp/chaos-loop/` state | **REMOVED** | Exactly F12. Replaced by the study store. |
| Atomic revisioned writes | **RETAINED as a pattern** | Already delivered in `[E2]`. Credited. |
| Proposal/evaluate split | **RETAINED as a pattern** | Becomes D9 — the model proposes, scripts compute. |
| Frozen-configuration drift gate | **RETAINED as a pattern** | Already delivered in `[E3]`; surfaced as exit code 12. |
| Three-verdict vocabulary | **RESHAPED** | Becomes severity + confidence + `mechanismProven` (D8); `verdict-matrix.md` keeps the derivation. |

### Revision 5 speculative work — DEFERRED, not deleted (D19)

`scoring.py`, `analysis.py`, `verdict.py`, `proof.py`, `scope.py`, `availability.py`, the 30-case nDCG golden set, the mechanism-class ledger, source/IaC analysis, build attestation rungs, and the approval-token transport. **None was built.** Each is deferred with a named revisit trigger: a consumer in a shipped study workflow. The seven unconsumed `[E2]` schemas are their surviving contract surface, which is why those schemas are DEFERRED rather than deleted.

### Migration steps for an existing user

1. `v0.3.x → v0.4.0` is a normal upgrade. No state migration, no evidence migration, no config change.
2. `$CHAOS_STUDY_ROOT` is created on first study. Nothing reads it before then.
3. Existing `startchaos-state.json` files continue to resume against the five shipped skills.
4. Existing `[E2]` evidence directories are untouched and still readable by `chaos_evidence_get`.
5. There is nothing to roll back beyond reinstalling v0.3.x; the study store is additive and self-contained.

---

## Implementation Phases

| Phase | Goal | Epics | Exit criteria |
|---|---|---|---|
| **0 — Land what exists** — **CLOSED by `283cb61`**, one leg outstanding | Nothing is lost from the dirty worktree | EPIC-003 | `[E3]` committed **including the two untracked directories and `blast-radius.md`** — **done**; Pester, pytest and ruff green on all three OS — **done on Windows and locally only; the hosted three-OS / 3.10–3.13 matrix has not run because the branch is local-only. Closes on the first push.** |
| **1 — Foundations** | A study can be created, sealed and read; the first-vertical faults are described; provenance is automatic and MCP is off the critical path | EPIC-004, EPIC-005, EPIC-006 | A study directory can be created, sealed and re-read offline; three fault guides validate; a skill runs with zero MCP tools present and records the substitution; `commands.jsonl` is complete without per-caller effort |
| **2 — Kubernetes reachability** | The plugin can reach AKS faults without ad-hoc REST | EPIC-007 | `Resolve-FaultPath` returns `experiment` with evidence on a real subscription; `Get-K8sReadiness` returns seven checks; one classic experiment created and cancelled by hand against a disposable cluster |
| **3 — Production path** | A study can be planned, executed and measured | EPIC-008, EPIC-009, EPIC-010 | End-to-end dry run produces a valid `study-plan.v1.json`; a consented run produces `run-record.v1.json` and three evidence windows; abort path exercised |
| **4 — The deliverable** | A reader gets an executive summary, dated evidence, prioritized findings, limitations and remediation in one file | EPIC-011, EPIC-012, EPIC-013 | Three golden studies render byte-identically twice; `report.html` opens from `file://` with JS disabled; Limitations non-empty in all three; entry skill under 200 lines with CI enforcing it |
| **5 — Longitudinal and coverage** | A later conversation can answer "did it get better?", and fault coverage expands additively | EPIC-014, EPIC-016 | `list`/`show`/`compare`/`rerun`/`purge` work from a zipped study on a second machine with no Azure credentials; EPIC-016 lands with a diff touching no code |
| **6 — Release** | v0.4.0 ships | EPIC-015 | Versions synchronised; docs updated; api-version and N8-exception decisions recorded; Q4/Q7/Q12 decided |

Phases 1 and 2 can run in parallel after Phase 0. Phase 3 requires both. EPIC-016 can start any time after EPIC-012 and does not gate release.

---

## Files Affected

### New Files

| File Path | Purpose |
|---|---|
| `copilot-cli-plugin/scripts/Study.ps1` | Study store: create, resolve, save, seal, index, command trail (FR-14) |
| `copilot-cli-plugin/scripts/Constants.ps1` | Promoted shared PowerShell api-version pin file (NFR-9) |
| `copilot-cli-plugin/scripts/Invoke-AzChaosClassic.ps1` | Pinned, allowlisted REST wrapper for the classic model (FR-5, CS-10) |
| `copilot-cli-plugin/scripts/Resolve-FaultPath.ps1` | Runtime capability probe → `scenario` \| `experiment` \| `none` (FR-6) |
| `copilot-cli-plugin/scripts/Get-K8sReadiness.ps1` | Seven Kubernetes readiness checks with remediation (FR-7) |
| `copilot-cli-plugin/scripts/Get-StudySignals.ps1` | Pre/during/post window pack (FR-11) |
| `copilot-cli-plugin/scripts/Build-StudyFindings.ps1` | Pure findings + limitations engine (FR-12, FR-18) |
| `copilot-cli-plugin/scripts/New-StudyReport.ps1` | Deterministic HTML renderer (FR-16, FR-17) |
| `copilot-cli-plugin/scripts/Compare-Study.ps1` | Pure study comparison (FR-15) |
| `copilot-cli-plugin/skills/chaos-study/SKILL.md` + `scripts/Invoke-ChaosStudy.ps1` | Entry skill (G1, FR-1) |
| `copilot-cli-plugin/skills/chaos-study-scope/SKILL.md` + `scripts/Invoke-ChaosStudyScope.ps1` | Discovery, readiness, hypothesis, plan |
| `copilot-cli-plugin/skills/chaos-study-run/SKILL.md` + `scripts/Invoke-ChaosStudyRun.ps1` | Consent, execution, window capture |
| `copilot-cli-plugin/skills/chaos-study-report/SKILL.md` + `scripts/Invoke-ChaosStudyReport.ps1` | Findings and report |
| `copilot-cli-plugin/skills/chaos-study-report/templates/study-report.html.tmpl` | Single-file report template, inline CSS + SVG |
| `copilot-cli-plugin/skills/chaos-study-history/SKILL.md` + `scripts/Invoke-ChaosStudyHistory.ps1` | List, show, compare, rerun |
| `copilot-cli-plugin/schemas/study-plan.v1.schema.json` | Plan contract |
| `copilot-cli-plugin/schemas/findings.v1.schema.json` | Findings + mandatory limitations |
| `copilot-cli-plugin/schemas/study-manifest.v1.schema.json` | Seal manifest |
| `copilot-cli-plugin/schemas/comparison.v1.schema.json` | Comparison contract |
| `copilot-cli-plugin/schemas/fault-guide.v1.schema.json` | Fault-guide front matter (FR-21) |
| `copilot-cli-plugin/references/chaos/study-method.md` | Hypothesis, steady state, blast radius, abort, evidence |
| `copilot-cli-plugin/references/chaos/report-contract.md` | Sections, severity scale, limitation taxonomy |
| `copilot-cli-plugin/references/chaos/faults/_index.md` | Routing table (FR-4) |
| `copilot-cli-plugin/references/chaos/faults/aks-chaosmesh-{pod,network,stress,io,dns,http,time,kernel}.md` | Eight Chaos Mesh fault guides |
| `copilot-cli-plugin/references/chaos/faults/aks-nodepool-vmss-shutdown.md`, `aks-nsg-rule.md` | Two non-Chaos-Mesh Kubernetes-adjacent guides |
| `copilot-cli-plugin/references/chaos/scenarios/_index.md` + `kubernetes-{pod-resilience,node-loss,dependency-latency}.md` | Scenario guidance |
| `copilot-cli-plugin/skills/chaos-study*/tests/**` | Pester suites (one per epic; see Implementation Plan) |
| `copilot-cli-plugin/skills/chaos-study-report/tests/fixtures/golden-{pass,critical,not-exercised}/` | Three golden studies |

### Modified Files

| File Path | Changes |
|---|---|
| `copilot-cli-plugin/scripts/Preflight.ps1` | `+ Resolve-ToolPath`; `optionalTools` front-matter support. Existing functions untouched (FR-20) |
| `copilot-cli-plugin/scripts/Invoke-AzChaos.ps1`, `Invoke-AzRest.ps1` | Optional study-context hook so every `az`/REST call is trailed automatically (FR-22, E6-T1). No behaviour change when no study context is set |
| `copilot-cli-plugin/scripts/State.ps1` | Export `Get-EvidenceScopeHash` and the redaction lists for `Study.ps1`. No behaviour change |
| `copilot-cli-plugin/skills/chaos-impact/scripts/Constants.ps1` | Becomes a dot-source shim to the promoted `scripts/Constants.ps1` for one minor version |
| `copilot-cli-plugin/skills/setup-scenario/SKILL.md` | `[E3]` blast-radius/consent narrative replaced by a routing pointer; target < 140 lines (P2) |
| `copilot-cli-plugin/skills/run-scenario/SKILL.md` | Same treatment; target < 140 lines. Plus E15-T8: remove or gate `$env:STARTCHAOS_NONINTERACTIVE` so it cannot skip fault-execution confirmation (N8) |
| `copilot-cli-plugin/skills/run-scenario/scripts/Invoke-RunScenario.ps1` | E15-T8 only: the `STARTCHAOS_NONINTERACTIVE` bypass at line 48 |
| `copilot-cli-plugin/agents/start-chaos.md` | Extend the no-ad-hoc-REST invariant to name `Invoke-AzChaosClassic.ps1` |
| `copilot-cli-plugin/references/chaos/evidence-contract.md` | New section: evidence store vs study store, sealing, boundary |
| `copilot-cli-plugin/references/chaos/verdict-matrix.md` | Reframed as the internal derivation table behind severity/confidence (D8) |
| `copilot-cli-plugin/skills/start-chaos/tests/Preflight.Tests.ps1` | Fail-fast cases move to a `requiredTools` fixture; substitution cases added |
| `copilot-cli-plugin/mcp/tests/test_tool_manifest.py` | `FROZEN_SKILLS` gains the five new skills |
| `copilot-cli-plugin/mcp/chaos_mcp/apiversions.py` | Lint test extended to cover the promoted PowerShell pin file |
| `copilot-cli-plugin/plugin.json`, `.github/plugin/marketplace.json`, `copilot-cli-plugin/mcp/pyproject.toml` | v0.4.0; five skill registrations |
| `copilot-cli-plugin/README.md`, `docs/` | Study workflow walkthrough; `$CHAOS_STUDY_ROOT` documented |
| `docs/targeted-chaos-skills.decisions.md` | The executive companion to this plan. Regenerated from this document at every revision; it adds no decision of its own, so it can never disagree with the plan (E15-T3) |

### Deleted Files

| File Path | Reason |
|---|---|
| `docs/_p1.md` | A Revision-4 fragment fully superseded by this document. Removed in E15-T4. **This is the only file this plan deletes.** |

No file under `copilot-cli-plugin/` is deleted. `[PR32]` paths do not exist on `main`, so its removal is a plan-of-record decision, not a filesystem change (D17).

---

## Implementation Plan

Statuses reflect the branch at `283cb61` (EPIC-001 through EPIC-003 committed).

### EPIC-001 — Baseline contracts, tests, runtime preflight — **DONE** (`5257c2a`)

**Goal:** api-version consolidation, lifecycle/manifest test coverage, host-visible tool preflight.
**Prerequisites:** none.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E1-T7 | IMPL | Consolidate Python api-version pins + dead-pin lint | `mcp/chaos_mcp/apiversions.py` | DONE |
| E1-T8 | TEST | Lifecycle + tool-manifest contract tests, `FROZEN_SKILLS` | `mcp/tests/test_lifecycle_contract.py`, `test_tool_manifest.py` | DONE |
| E1-T9 | IMPL | `Preflight.ps1` + `requiredTools:` front matter | `scripts/Preflight.ps1`, five `SKILL.md` | DONE |
| E1-T10 | TEST | Preflight Pester contract | `skills/start-chaos/tests/Preflight.Tests.ps1` | DONE |

**Acceptance criteria**
- [x] pytest 104 passed, ruff clean, Pester 112 passed / 0 failed on this machine
- [x] No api-version literal escapes `apiversions.py`

### EPIC-002 — Compatible state and durable evidence — **DONE** (`4befd5e`)

**Goal:** a durable, redacted, atomic evidence store outside the repository.
**Prerequisites:** EPIC-001.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E2-T1 | IMPL | Evidence store: canonicalization, key denylist, redaction, atomic revisioned writes | `mcp/chaos_mcp/evidence.py` | DONE |
| E2-T2 | IMPL | PowerShell mirror + import | `scripts/State.ps1` | DONE |
| E2-T3 | IMPL | Nine v1 artifact schemas | `schemas/*.v1.schema.json` | DONE |
| E2-T4 | IMPL | Three evidence MCP tools (15 → 18) | `mcp/chaos_mcp/server.py` | DONE |
| E2-T5 | TEST | Evidence + state suites | `mcp/tests/test_evidence.py`, `skills/start-chaos/tests/State.Tests.ps1` | DONE |

**Acceptance criteria**
- [x] pytest 193 passed / 1 skipped, ruff clean
- [x] `$CHAOS_KEY_DIR` unreachable; redaction applied on write **and** read

### EPIC-003 — Validation blockers, blast radius, consent — **DONE** (`283cb61`)

**Goal:** land the working tree without losing anything.
**Prerequisites:** EPIC-002.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E3-T1 | IMPL | Structured validation errors, normalised blockers, validate → fix → revalidate, broad-fix consent (exit 4) | `scripts/Validate-AndFix.ps1` | DONE |
| E3-T2 | IMPL | `Build-TargetedGrantProposal` + `build_targeted_grant_proposal()` | `scripts/Rbac.ps1`, `mcp/chaos_mcp/server.py` | DONE |
| E3-T3 | IMPL | `Resolve-BlastRadius`, `Write-BlastRadiusCard` | `scripts/Render.ps1` | DONE |
| E3-T4 | IMPL | Blast-radius reference doc incl. the advisory-targeting note | `references/chaos/blast-radius.md` | DONE (tracked) |
| E3-T5 | TEST | Four Pester suites | `skills/{setup,run}-scenario/tests/**` | DONE (tracked) |
| E3-T6 | IMPL | **`git add` the untracked files, commit, run the full matrix on three OS** | — | DONE for the commit (`283cb61`); **three-OS / 3.10–3.13 matrix still pending** — the branch is local-only and the workflow fires on push/PR to `main`, so only Windows Pester and local Python were run. Closes when CI runs on first push. |

**Acceptance criteria**
- [x] `git status` clean for `copilot-cli-plugin/`; `blast-radius.md` and both `tests/` directories tracked
- [~] Pester green on Windows, Linux and macOS; pytest green on 3.10–3.13; ruff clean — **verified on Windows (PowerShell 7.6.5) and local Python only.** The hosted matrix has not run: the branch has no PR and the workflow is gated on push/PR to `main`. This leg is outstanding and closes on the first CI run (see E3-T6).
- [x] Exit codes 2, 3 and 4 asserted by `SetupExitContract.Tests.ps1` (the shipped `0`–`4` block is frozen by this epic)

### EPIC-004 — Immutable dated study store — **DONE**

**Goal:** create, seal, enumerate and re-read a study offline. **Prerequisites:** EPIC-003.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E4-T1 | IMPL | `Study.ps1`: `New-Study`, `Get-StudyRoot`, `Resolve-StudyPath`, `Save-StudyArtifact`, `Complete-Study` (alias `Seal-Study`), `Get-Study`, `Get-StudyIndex`, `Add-StudyIndexEntry` (`Add-CommandTrailEntry` lands in EPIC-006) | `scripts/Study.ps1` | DONE |
| E4-T2 | IMPL | Export scope-hash + redaction lists from `State.ps1` for reuse (no fork — D16) | `scripts/State.ps1` | DONE |
| E4-T3 | IMPL | `study-plan.v1` and `study-manifest.v1` schemas | `schemas/study-plan.v1.schema.json`, `schemas/study-manifest.v1.schema.json` | DONE |
| E4-T4 | IMPL | Extend the evidence contract doc with the study-store boundary | `references/chaos/evidence-contract.md` | DONE |
| E4-T5 | TEST | Sealing, immutability, three-step commit, index rebuild, root-location assertions, redaction of a planted token | `skills/start-chaos/tests/Study.Tests.ps1` | DONE |
| E4-T6 | TEST | Portability: zip → unzip elsewhere → `Get-Study` succeeds with no credentials | `skills/start-chaos/tests/StudyPortability.Tests.ps1` | DONE |

**Acceptance criteria**
- [x] `Save-StudyArtifact` on a sealed study throws `StudyAlreadySealed` (exit 13); **no force flag exists**
- [x] A test asserts the resolved root is neither under the repository root nor under the system temp directory (FR-14)
- [x] `manifest.json` SHA-256 covers every file except itself and `SEALED`; a mutated file is detected
- [x] `Get-StudyIndex -Rebuild` reconstructs an index deleted mid-test
- [x] A token planted in plan, signals, error text and `az` argv appears nowhere in the sealed study (NFR-5)

### EPIC-005 — Fault-guide contract and the first-vertical guides

**Goal:** fault knowledge is versioned, schema-validated, discoverable and additive, with exactly the guides the first vertical needs. **Prerequisites:** EPIC-003 (parallel with EPIC-004). Remaining coverage is EPIC-016.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E5-T1 | IMPL | `fault-guide.v1.schema.json` — front-matter contract; `dataPlaneProof.coverage: none` is invalid | `schemas/fault-guide.v1.schema.json` | TO DO |
| E5-T2 | IMPL | Three core AKS Chaos Mesh guides at capability 2.2 — `podChaos`, `networkChaos`, `stressChaos` — each with `jsonSpec` shape, prerequisites, steady-state and impact signals, blast-radius controls, abort conditions, `dataPlaneProof` | `references/chaos/faults/aks-chaosmesh-{pod,network,stress}.md` | TO DO |
| E5-T3 | IMPL | Routing table + the first scenario guide | `references/chaos/faults/_index.md`, `references/chaos/scenarios/{_index,kubernetes-pod-resilience}.md` | TO DO |
| E5-T4 | IMPL | `study-method.md` — hypothesis, steady state, blast radius, abort, evidence | `references/chaos/study-method.md` | TO DO |
| E5-T5 | TEST | Index/guide bijection, schema validity, no orphan guides, every `faultUrn` unique | `skills/start-chaos/tests/FaultGuides.Tests.ps1` | TO DO |
| E5-T6 | TEST | Additivity proof: a fixture guide is added with no script, skill or test change | `skills/start-chaos/tests/fixtures/faults/example-fault.md` | TO DO |

**Acceptance criteria**
- [ ] Three guides validate against `fault-guide.v1.schema.json`
- [ ] `_index.md` rows and guide files are in exact bijection
- [ ] Every guide states `dataPlaneProof.coverage` as `documented` or `heuristic`; `none` fails CI (FR-21)
- [ ] Adding a fault requires no script, skill or test change — demonstrated by E5-T6, not asserted in prose (G9)

### EPIC-006 — Provenance: command trail and optional MCP

**Goal:** every `az` call a study makes is recorded, and no MCP tool is required or silently substituted. **Prerequisites:** EPIC-004.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E6-T1 | IMPL | Optional study-context hook in the two `az` seams, so **every** invocation is trailed automatically rather than per-caller (FR-22) | `scripts/Invoke-AzChaos.ps1`, `scripts/Invoke-AzRest.ps1` | TO DO |
| E6-T2 | IMPL | `Add-CommandTrailEntry` writes `commands.jsonl` — command, exit code, duration, api-version, **arguments redacted before write** | `scripts/Study.ps1` | TO DO |
| E6-T3 | IMPL | `Resolve-ToolPath` + `optionalTools:` front-matter parsing; `Assert-RequiredTools` retained and still callable | `scripts/Preflight.ps1` | TO DO |
| E6-T4 | IMPL | `toolSubstitutions[]` written into the study manifest and rendered in the report appendix | `scripts/Study.ps1` | TO DO |
| E6-T5 | TEST | Reshape Preflight tests: fail-fast under a `requiredTools` fixture; substitution cases for `optionalTools`; zero-MCP run completes | `skills/start-chaos/tests/{Preflight,OptionalTools}.Tests.ps1` | TO DO |
| E6-T6 | TEST | Trail completeness: a scripted study makes N `az` calls and `commands.jsonl` has exactly N entries, none containing a planted token | `skills/start-chaos/tests/CommandTrail.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] Recording is automatic at the seam — a new caller cannot forget to trail a command (FR-22)
- [ ] Every new skill declares `optionalTools:` and none declares `requiredTools:`
- [ ] With an empty tool inventory the workflow completes and the manifest lists each substitution (D6, F5)
- [ ] The `[E1]` fail-fast capability is still exercised by at least one test

### EPIC-007 — Fault-path probe, classic REST wrapper, Kubernetes readiness

**Goal:** AKS faults are reachable without ad-hoc REST. **Prerequisites:** EPIC-005.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E7-T1 | IMPL | Promote `Constants.ps1` to `scripts/`; shim the old path; add the classic pin (NFR-9) | `scripts/Constants.ps1`, `skills/chaos-impact/scripts/Constants.ps1` | TO DO |
| E7-T2 | IMPL | `Invoke-AzChaosClassic.ps1` — allowlisted classic paths, pinned api-version | `scripts/Invoke-AzChaosClassic.ps1` | TO DO |
| E7-T3 | IMPL | `Resolve-FaultPath.ps1` — probe v2 catalog then classic target types; return the evidence | `scripts/Resolve-FaultPath.ps1` | TO DO |
| E7-T4 | IMPL | `Get-K8sReadiness.ps1` — seven checks, each pass/fail/unknown + exact remediation | `scripts/Get-K8sReadiness.ps1` | TO DO |
| E7-T5 | IMPL | Extend the agent invariant to name the classic wrapper | `agents/start-chaos.md` | TO DO |
| E7-T6 | TEST | Replay-based tests for probe and readiness; allowlist-escape test for the wrapper; `kubectl`-absent yields `unknown` | `skills/chaos-study-scope/tests/{FaultPath,K8sReadiness,ClassicWrapper}.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] `Resolve-FaultPath` returns `scenario` \| `experiment` \| `none` **with the evidence for the answer**, and never guesses (FR-6); `none` exits 14
- [ ] No caller can pass an arbitrary path to `Invoke-AzChaosClassic` (asserted)
- [ ] `Get-K8sReadiness` returns exactly seven checks; absent `kubectl` yields `unknown`, never `fail`
- [ ] Manual live verification recorded: one classic experiment created and cancelled against a disposable cluster

### EPIC-008 — `chaos-study-scope`

**Goal:** a plan a human can read and consent to. **Prerequisites:** EPIC-004, EPIC-005, EPIC-007.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E8-T1 | IMPL | `Invoke-ChaosStudyScope.ps1` — readiness, discovery, blast radius, signal availability, plan write | `skills/chaos-study-scope/scripts/Invoke-ChaosStudyScope.ps1` | TO DO |
| E8-T2 | IMPL | `SKILL.md` — principle-led, routing pointer only, `optionalTools:` | `skills/chaos-study-scope/SKILL.md` | TO DO |
| E8-T3 | IMPL | Plan card rendering via `[E3] Render.ps1` | `scripts/Render.ps1` | TO DO |
| E8-T4 | IMPL | Move `[E3]` narrative out of `setup-scenario` / `run-scenario` into references (P2) | `skills/{setup,run}-scenario/SKILL.md` | TO DO |
| E8-T5 | TEST | Plan validity, `blocked` path when a signal or prerequisite is missing, no invented scenario or fault name | `skills/chaos-study-scope/tests/Plan.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] `study-plan.v1.json` validates and contains hypothesis, steady state, fault + parameters, resolved blast radius, duration, abort conditions and signals (FR-8)
- [ ] A plan is `blocked` **only** when no available source can evaluate its steady-state predicate (FR-7a), with the missing source named
- [ ] Every fault and scenario name traces to a service response or a guide `faultUrn` — asserted, not instructed
- [ ] All three touched `SKILL.md` files under 200 lines; `setup-scenario` under 140

### EPIC-009 — Window-pack signal collector

**Goal:** one deterministic answer to F2/F3/F4. **Prerequisites:** EPIC-004.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E9-T1 | IMPL | `Get-StudySignals.ps1` composing the `[MAIN] chaos-impact` collectors; add AKS metrics, Container Insights KQL, Prometheus | `scripts/Get-StudySignals.ps1` | TO DO |
| E9-T2 | IMPL | Window arithmetic: half-open `[start, end)`, baseline and recovery defaults | `scripts/Get-StudySignals.ps1` | TO DO |
| E9-T3 | IMPL | KQL templates for `KubePodInventory`, `KubeEvents`, `KubeNodeInventory` | `skills/chaos-study-run/templates/kql/*.kql` | TO DO |
| E9-T4 | TEST | Recorded-response replay for all six sources; `null` + caveat on each failure; null-vs-zero contract test (NFR-3) | `skills/chaos-study-run/tests/Signals.Tests.ps1` | TO DO |
| E9-T5 | TEST | Window boundary tests: no double-count at `runEnd`; DST and leap-second-adjacent inputs | `skills/chaos-study-run/tests/Windows.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] The AlertsManagement `timeRange=custom` + `customTimeRange` contract and its api-version fallback are reused unchanged
- [ ] Every source returns `{source, window, requestedAt, values|null, caveat|null, queryDigest}`
- [ ] A failing source never produces `0`; the null-vs-zero test fails if it does
- [ ] Absent Prometheus yields `unknown`, never `fail`

### EPIC-010 — `chaos-study-run`

**Goal:** consented, safe, recoverable execution. **Prerequisites:** EPIC-007, EPIC-008, EPIC-009.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E10-T1 | IMPL | Freeze + hash, `[E3]` validate/fix/revalidate, typed consent bound to `frozenConfigHash` (decline → 11), drift abort (→ 12) | `skills/chaos-study-run/scripts/Invoke-ChaosStudyRun.ps1` | TO DO |
| E10-T2 | IMPL | Execute via `faultPath`; deterministic run-id recovery after an empty 2xx (FR-13) | same | TO DO |
| E10-T3 | IMPL | Abort-condition poller + cancel; post-window capture still runs after an abort | same | TO DO |
| E10-T4 | IMPL | `run-record.v1.json` + `evidence/{pre,during,post}` written through `Save-StudyArtifact`; the command trail is produced automatically by the EPIC-006 seam hook | `scripts/Study.ps1` | TO DO |
| E10-T5 | IMPL | `SKILL.md`, `optionalTools:`, degrade-to-scope when no plan exists (FR-2) | `skills/chaos-study-run/SKILL.md` | TO DO |
| E10-T6 | TEST | Consent decline (11), broad-fix decline (4), drift (12), empty-2xx recovery, abort path, resume from a partial study, **and `$env:STARTCHAOS_NONINTERACTIVE=1` does not bypass consent on the study path** | `skills/chaos-study-run/tests/Execute.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] `--skip-validation` is passed **only** after the `[E3]` gate succeeded (FR-10) — asserted
- [ ] Run-id recovery fails loudly rather than returning null; null `actionName` is labelled by URN, never relabelled (FR-13)
- [ ] An aborted run still produces a sealed-able study with `abortedBy`, `abortedAtUtc` and the breaching predicate
- [ ] No flag, environment variable or file grants execution consent on the study path; `$env:STARTCHAOS_NONINTERACTIVE=1` is explicitly ignored and asserted (N8)

### EPIC-011 — Findings engine

**Goal:** severities and limitations that are computed, not asserted. **Prerequisites:** EPIC-009, EPIC-010.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E11-T1 | IMPL | `Build-StudyFindings.ps1` — **pure**; severity rules, confidence, `mechanismProven` | `scripts/Build-StudyFindings.ps1` | TO DO |
| E11-T2 | IMPL | Limitations taxonomy L1–L9; L1 always emitted | same | TO DO |
| E11-T3 | IMPL | `findings.v1.schema.json` with `limitations[]` required and `minItems: 1` | `schemas/findings.v1.schema.json` | TO DO |
| E11-T4 | IMPL | `verdict-matrix.md` reframed as the internal derivation table (D8) | `references/chaos/verdict-matrix.md` | TO DO |
| E11-T5 | TEST | Table-driven severity and confidence matrix; control-plane-only input can never yield `mechanismProven: true` | `skills/chaos-study-report/tests/Findings.Tests.ps1` | TO DO |
| E11-T6 | TEST | Every L-class is reachable and asserted by at least one fixture | `skills/chaos-study-report/tests/Limitations.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] `Build-StudyFindings` performs no I/O, no `az` call and reads no clock — asserted by test isolation
- [ ] Control-plane state alone never produces a `confirmed` finding (F6, FR-12)
- [ ] `limitations[]` is never empty for any input, including a perfectly clean study (FR-18, D13)
- [ ] Findings carry `findingKey` = hash(fault URN, signal, predicate) for stable matching

### EPIC-012 — HTML report and `chaos-study-report`

**Goal:** a deliverable a human reads. **Prerequisites:** EPIC-011.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E12-T1 | IMPL | `study-report.html.tmpl` — eight sections, inline CSS, inline SVG sparklines, no script | `skills/chaos-study-report/templates/study-report.html.tmpl` | TO DO |
| E12-T2 | IMPL | `New-StudyReport.ps1` — deterministic renderer, HTML-escaping, invariant culture, explicit sort keys | `scripts/New-StudyReport.ps1` | TO DO |
| E12-T3 | IMPL | `report-contract.md` — sections, severity scale, limitation taxonomy | `references/chaos/report-contract.md` | TO DO |
| E12-T4 | IMPL | `SKILL.md` + `Invoke-ChaosStudyReport.ps1`; seal on success | `skills/chaos-study-report/**` | TO DO |
| E12-T5 | TEST | Three golden studies; render twice, mask `generatedAt`, assert byte equality on all three OS | `skills/chaos-study-report/tests/Determinism.Tests.ps1` | TO DO |
| E12-T6 | TEST | No `<script`, no `javascript:`, no `http(s)://` asset reference; size bound; escaping of a hostile resource name | `skills/chaos-study-report/tests/ReportSafety.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] `report.html` opens from `file://` with JavaScript disabled and renders all eight sections
- [ ] Byte-identical across two renders and across three operating systems, except `generatedAt` (FR-17, D12)
- [ ] Zero external asset references; typical study under 2 MB (NFR-8)
- [ ] The narrative slots cannot alter a severity, a number or the limitations list (D9) — asserted
- [ ] The Chaos Studio portal scenario report is **linked**, not reimplemented (N9)

### EPIC-013 — `chaos-study` entry skill and the line cap

**Goal:** one obvious front door, mechanically kept short. **Prerequisites:** EPIC-008, EPIC-010, EPIC-012.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E13-T1 | IMPL | `SKILL.md` — frontmatter, four principles, six steps, safety, routing table, exit codes, worked example | `skills/chaos-study/SKILL.md` | TO DO |
| E13-T2 | IMPL | `Invoke-ChaosStudy.ps1` — in-process orchestration of the four supporting scripts; `-DryRun` default true | `skills/chaos-study/scripts/Invoke-ChaosStudy.ps1` | TO DO |
| E13-T3 | IMPL | Terminal summary card: verdict banner, top findings, report path | `scripts/Render.ps1` | TO DO |
| E13-T4 | TEST | CI line-cap test over **every** user-facing `SKILL.md` (FR-3) | `skills/start-chaos/tests/SkillLineCap.Tests.ps1` | TO DO |
| E13-T5 | TEST | End-to-end dry run against recorded responses produces a valid plan and stops before consent | `skills/chaos-study/tests/EndToEnd.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] `chaos-study/SKILL.md` is **under 200 lines**; all ten user-facing skills are under 200; CI fails otherwise (FR-3, D3)
- [ ] The skill inlines **zero** fault parameters; it names `faults/_index.md` and stops (FR-4)
- [ ] `-DryRun` defaults to true; a plan is produced with no mutation (N8, Q4)

### EPIC-014 — `chaos-study-history`

**Goal:** a cold conversation can answer "did it get better?". **Prerequisites:** EPIC-004, EPIC-012.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E14-T1 | IMPL | `Compare-Study.ps1` — **pure**; five comparability conditions; deltas; appeared/resolved/changed | `scripts/Compare-Study.ps1` | TO DO |
| E14-T2 | IMPL | `comparison.v1.schema.json` | `schemas/comparison.v1.schema.json` | TO DO |
| E14-T3 | IMPL | `Invoke-ChaosStudyHistory.ps1` — list, show, compare, rerun with `derivedFrom` | `skills/chaos-study-history/scripts/Invoke-ChaosStudyHistory.ps1` | TO DO |
| E14-T4 | IMPL | Comparison HTML report reusing the EPIC-012 renderer | `skills/chaos-study-report/templates/study-report.html.tmpl` | TO DO |
| E14-T5 | IMPL | `SKILL.md` | `skills/chaos-study-history/SKILL.md` | TO DO |
| E14-T6 | IMPL | `Invoke-ChaosStudyHistory -Purge` — retention enforcement (NFR-12): dry-run by default, lists what would go, requires an explicit confirmed switch, refuses to touch a sealed study without it, never runs implicitly | `skills/chaos-study-history/scripts/Invoke-ChaosStudyHistory.ps1` | TO DO |
| E14-T7 | TEST | Incomparable cases (each of the five conditions) exit 15 with a stated reason; `findingKey` matching survives a retitled finding; offline/no-credential operation | `skills/chaos-study-history/tests/Compare.Tests.ps1` | TO DO |
| E14-T8 | TEST | Purge: nothing is deleted without the confirm switch; a study inside `CHAOS_STUDY_RETENTION_DAYS` is never a candidate; an `ABANDONED` study is listed but not auto-deleted | `skills/chaos-study-history/tests/Purge.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] `list`, `show` and `compare` make **zero** Azure calls (D20, FR-15)
- [ ] A comparison across scopes, fault URNs, capability versions, `faultPath` or ±20% window length is refused with `incomparableReason` (exit 15)
- [ ] `-Rerun` produces a new `studyId` with `derivedFrom` and surfaces blast-radius drift before consent
- [ ] Verified against a study zipped and moved to a second machine with no Azure credentials (NFR-11)
- [ ] `-Purge` deletes nothing without an explicit confirmed switch, and never runs implicitly (NFR-12)

### EPIC-015 — Migration, docs and release

**Goal:** v0.4.0 ships coherently. **Prerequisites:** all.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E15-T1 | IMPL | Synchronise versions and register the five skills | `plugin.json`, `.github/plugin/marketplace.json`, `mcp/pyproject.toml` | TO DO |
| E15-T2 | IMPL | `FROZEN_SKILLS` gains the five new skills; api-version lint extended to the promoted PowerShell pin file | `mcp/tests/test_tool_manifest.py`, `mcp/chaos_mcp/apiversions.py` | TO DO |
| E15-T3 | IMPL | Docs: study walkthrough, `$CHAOS_STUDY_ROOT`, retention, purge, the five-skill map; regenerate `docs/targeted-chaos-skills.decisions.md` from the shipped plan | `copilot-cli-plugin/README.md`, `docs/` | TO DO |
| E15-T4 | IMPL | Housekeeping: remove the superseded `docs/_p1.md` fragment | `docs/_p1.md` | TO DO |
| E15-T5 | TEST | Backward-compatibility suite: v0.3.x state file resumes; 18 tool signatures unchanged; `impactReportSchemaVersion: 1` unchanged; `[E2]` evidence still readable; the shipped `0`–`4` exit block unchanged | `skills/start-chaos/tests/Compatibility.Tests.ps1` | TO DO |
| E15-T6 | TEST | Full matrix on three OS and four Python versions; record the gate in Appendix A | — | TO DO |
| E15-T7 | IMPL | **Evidence-gated api-version decision.** Exercise the required v2 operations against a target environment on the shipped `2026-05-01-preview`; bump to `2026-08-01-preview` **only** with recorded fixtures proving each operation, updating both pin files and the contract tests together (CS-12) | `mcp/chaos_mcp/apiversions.py`, `scripts/Constants.ps1`, `mcp/tests/test_tool_manifest.py` | TO DO |
| E15-T8 | IMPL | **Close the N8 legacy exception.** Remove or gate `$env:STARTCHAOS_NONINTERACTIVE` in `run-scenario` so it can no longer skip fault-execution confirmation; if removal must wait for the deprecation window (Q12), emit a loud warning and document it in the release notes | `skills/run-scenario/SKILL.md`, `skills/run-scenario/scripts/Invoke-RunScenario.ps1`, `skills/run-scenario/tests/PreExecuteGate.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] All 18 MCP tool names, signatures and envelopes unchanged (NFR-10, D18)
- [ ] A v0.3.x `startchaos-state.json` resumes unmodified
- [ ] The api-version pin is either unchanged or bumped with recorded per-operation evidence — never bumped on spec existence alone
- [ ] N8 holds for the whole plugin, or the residual `run-scenario` exception is documented in the release notes with a loud runtime warning
- [ ] Q4, Q7 and Q12 have recorded decisions before release
- [ ] Pester green on three OS; pytest green on 3.10–3.13; ruff clean

### EPIC-016 — Fault guide coverage expansion

**Goal:** the remaining Kubernetes fault and scenario coverage, added purely additively. **Prerequisites:** EPIC-005, EPIC-012 (so `dataPlaneProof` claims can be checked against real reports).

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E16-T1 | IMPL | Five further AKS Chaos Mesh guides — `IOChaos`, `dnsChaos`, `httpChaos`, `timeChaos`, `kernelChaos` | `references/chaos/faults/aks-chaosmesh-{io,dns,http,time,kernel}.md` | TO DO |
| E16-T2 | IMPL | Two Kubernetes-adjacent guides: VMSS shutdown against a node pool, NSG security rule | `references/chaos/faults/aks-nodepool-vmss-shutdown.md`, `aks-nsg-rule.md` | TO DO |
| E16-T3 | IMPL | Two further scenario guides | `references/chaos/scenarios/kubernetes-{node-loss,dependency-latency}.md` | TO DO |
| E16-T4 | IMPL | Routing-table rows for all seven new guides | `references/chaos/faults/_index.md` | TO DO |
| E16-T5 | TEST | Re-run E5-T5 bijection/schema tests over the expanded set; assert **no** script, skill or schema file changed in this epic | `skills/start-chaos/tests/FaultGuides.Tests.ps1` | TO DO |

**Acceptance criteria**
- [ ] Ten fault guides and three scenario guides validate and are in bijection with the index
- [ ] `dnsChaos` records its separate Chaos Mesh DNS service prerequisite; `kernelChaos` records its privileged-container caveat
- [ ] **This epic changes no `.ps1`, no `SKILL.md` and no schema** — the additivity claim of G9 is proved by the diff, not asserted

---

## References

**Repository (read on this machine)**

- `copilot-cli-plugin/plugin.json`, `README.md`, `agents/start-chaos.md`
- `copilot-cli-plugin/skills/{start-chaos,create-workspace,setup-scenario,run-scenario,chaos-impact}/SKILL.md`
- `copilot-cli-plugin/scripts/{Invoke-AzChaos,Invoke-AzRest,Ensure-AzLogin,Wait-AzureLro,Preflight,State,Rbac,Render,Validate-AndFix,New-RunReport}.ps1`
- `copilot-cli-plugin/skills/chaos-impact/{schema/impact-report.schema.json,scripts/Constants.ps1,templates/**,tests/e2e/Run-OfflineReplay.ps1}`
- `copilot-cli-plugin/schemas/*.v1.schema.json` (nine, `[E2]`)
- `copilot-cli-plugin/references/chaos/{evidence-contract,verdict-matrix,blast-radius}.md`
- `copilot-cli-plugin/mcp/chaos_mcp/{server.py,azure.py,monitor.py,evidence.py,apiversions.py}`
- `copilot-cli-plugin/mcp/tests/{test_lifecycle_contract,test_tool_manifest,test_evidence}.py`
- `.github/workflows/test.yml` (`Run.Path = './copilot-cli-plugin/skills'`), `release.yml`
- Branch `renzopretto-microsoft-add-chaos-loop-plugin` (`[PR32]`, not merged): `skills/chaos-loop/**`, `scripts/chaos_loop_state.py`, `references/chaos-loop/scenario-catalog.v1.json`

**Azure Chaos Studio**

- Chaos Studio documentation — https://learn.microsoft.com/azure/chaos-studio/
- Manage workspaces and scenarios with the Azure CLI — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-manage-cli
- Chaos Studio scenario reports — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-scenario-reports
- Fault and action library (AKS Chaos Mesh faults, capability 2.2, `jsonSpec`) — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-fault-library
- Tutorial: AKS Chaos Mesh faults in the portal (Chaos Mesh prerequisites, `chaos-testing` namespace, AKS Cluster Admin role) — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-tutorial-aks-portal
- Permissions and security (four built-in roles) — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-permissions-security
- Limitations and known issues — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-limitations
- Chaos Studio REST API reference — https://learn.microsoft.com/rest/api/chaosstudio/
- `az chaos` CLI reference — https://learn.microsoft.com/cli/azure/chaos
- Available Azure CLI extensions (`chaos` — min core 2.75.0, preview) — https://learn.microsoft.com/cli/azure/azure-cli-extensions-list
- `Azure/chaos-studio-samples` — https://github.com/Azure/chaos-studio-samples

**Kubernetes and observability**

- Chaos Mesh documentation (PodChaos, NetworkChaos, StressChaos, IOChaos, DNSChaos, HTTPChaos, TimeChaos, KernelChaos) — https://chaos-mesh.org/docs/
- Container Insights log tables (`KubePodInventory`, `KubeEvents`, `KubeNodeInventory`) — https://learn.microsoft.com/azure/azure-monitor/containers/container-insights-log-query
- Azure Monitor managed service for Prometheus — https://learn.microsoft.com/azure/azure-monitor/essentials/prometheus-metrics-overview
- Log Analytics query API — https://learn.microsoft.com/rest/api/loganalytics/
- `Microsoft.AlertsManagement` alerts REST API — https://learn.microsoft.com/rest/api/monitor/alertsmanagement/alerts
- Azure Activity Log — https://learn.microsoft.com/azure/azure-monitor/essentials/activity-log
- AKS node pools and VMSS — https://learn.microsoft.com/azure/aks/create-node-pools

**Methodology and standards**

- Principles of Chaos Engineering — https://principlesofchaos.org/
- Azure Well-Architected Framework RE:08, design a reliability testing strategy — https://learn.microsoft.com/azure/well-architected/reliability/testing-strategy
- Model Context Protocol specification — https://modelcontextprotocol.io/
- GitHub Copilot CLI plugins and skills — https://docs.github.com/copilot
- Pester documentation — https://pester.dev/

---

## Appendix A: Revision History

Corrections are recorded rather than silently overwritten, so a rejected inference is not re-derived by the next reader of the same source.

| Rev | Change | Why it is recorded |
|---|---|---|
| 2 | **`validations/latest` re-scoped** from a workspace artifact to a configuration-scoped singleton, producing CS-5. | The mis-scoping had made an advertised read-only skill silently dependent on ARM writes. |
| 2 | **Event Hubs mechanism falsified** — `AmqpProducer.CreateLinkAndEnsureProducerStateAsync` refreshes `MaxMessageSize` on every link open, so the caching theory is wrong. The F6 *observation* is unaffected. | The theory was about to seed a normative behaviour oracle. |
| 2 | **`first` is not a KQL reserved token** — it is an Azure CLI/ARG paging parameter mapping to REST `$top`. No escaping layer built. | Prevents building a mitigation for a non-problem; the real third failure is Q11. |
| 2 | **`chaos_list_tools` cut**; reconciliation moved to manifest declarations plus the host-visible `tools/list`. | The tool could not detect the failure it existed for. |
| 3 | `scopeId` / `scopeFingerprint` split; `thresholdKind` added to predicates; approval-token issuance specified. | Design gaps, each changing what an implementer builds. |
| 4 | Reframed as `[MAIN]` v0.3.0 evolution at `55c74c5`; exhaustive inventory, 15-tool matrix, compatibility-first phases. | Prevents prototype/main conflation and makes backward compatibility measurable. |
| 5 | Restored shipped scenario-tool names, removed the unsupported `/evaluate` assumption, matched the PowerShell alert query and api-version fallback, placed preflight Pester coverage under the CI scan root. | Resolved the independent technical review blockers. Scored Technical 86 / Readability 91. |
| **6** | **Product rescope.** Eight speculative peer skills → five real ones with one obvious entry point (D2); the deliverable becomes a dated, sealed, self-contained HTML study report (D1, D11); MCP moves from required to optional (D6); an immutable dated study store is added on the `[E2]` primitives (D7, D16); Kubernetes becomes the first and only vertical (D14); `[PR32]` is closed and replaced (D17); Revision 5's speculative modules are DEFERRED with named triggers (D19). Every `[E1]`/`[E2]`/`[E3]` asset is classified exactly once in §Migration and Disposition. | Revision 5 was internally coherent but had outgrown the product: thirteen front doors, no deliverable, and MCP on the critical path. The corrections are shape, not substance — no delivered code is discarded. |
| **6** | **Factual corrections against the working tree:** `Render.ps1` is `+224` on a pre-existing 214-line file (not a 224-line new file); the only PowerShell api-version pin file is `skills/chaos-impact/scripts/Constants.ps1`, not `scripts/Constants.ps1` — promoting it is now E7-T1; the AKS prerequisite role is named exactly (`Azure Kubernetes Service Cluster Admin Role`); Chaos Mesh capability version is 2.2 and the `chaos-testing` namespace is the only supported one; `Invoke-RunScenario.ps1` is dot-sourced in place rather than moved. | Each was a claim an implementer would have acted on and found false. |
| **6** | **`[E3]` was uncommitted and partly untracked — now closed by `283cb61`.** `references/chaos/blast-radius.md` and both new `tests/` directories were untracked; 1,440 lines of delivered work were one `git clean` from gone. Phase 0 and E3-T6 existed solely to close this, and did: all three paths are tracked and the working tree is clean. The residual gap is the hosted three-OS / 3.10–3.13 matrix, which has not yet run. | The highest-probability way this plan loses real value had nothing to do with the design. |
| **6** | **Independent review corrections (Technical 76/100, Readability 86/100).** Three technical blockers were real and are fixed: (a) **exit-code collision** — `Invoke-SetupScenario.ps1` already exits `2` and `3`, so the study suite moved to a new `10`–`15` block and the shipped `0`–`4` block is now frozen by E3-T6/E15-T5; (b) **N8 was false as written** — `run-scenario` honours `$env:STARTCHAOS_NONINTERACTIVE=1`, so N8 is now scoped to the study path with the legacy exception named and E15-T8 scheduled to close it; (c) **api-version** — the repository pins `2026-05-01-preview`, not `2026-08-01-preview`, so v0.4.0 stays on the shipped pin and any bump is evidence-gated (E15-T7). | Each was a claim an implementer would have acted on and found false, and two of them were safety claims. |
| **6** | **Structural corrections from the same review:** FR-22's command trail moved from per-caller calls to an automatic hook at the `Invoke-AzChaos` / `Invoke-AzRest` seam (EPIC-006, renamed *Provenance*); retention/purge gained a real implementation and tests (E14-T6/T8) instead of being a documented knob with no code; the seal manifest now states exactly which files it hashes; EPIC-005 was split, with the seven remaining fault guides and two scenario guides moved to the new **EPIC-016**, whose acceptance criterion is that its diff touches no code — turning G9's additivity claim into a test; **FR-7a** was added as the single observability-blocking rule after three sections stated it three different ways; and the Contents, source-label convention, Deleted Files table and progressive-discovery section were corrected for accuracy. | Recorded because each changes what an implementer builds, not merely how the document reads. |
| **6 — final pass** | **Verification, not redesign.** Every Revision-6 correction was re-checked against the working tree rather than against the previous draft, and all held: the E3 diff is exactly 9 modified files / +1180 / −24 with 5 untracked files; `Invoke-SetupScenario.ps1` emits exits `2`/`3`/`4` at lines 139/175/313; `Invoke-RunScenario.ps1:48` honours `STARTCHAOS_NONINTERACTIVE`; both pin files read `2026-05-01-preview`. Four narrow defects were then fixed: (a) **the front-door arithmetic was wrong** — G2 claimed "exactly five user-facing skills" while the design keeps the five shipped skills, so v0.4.x actually ships ten; P1, G2, D2 and FR-3 now state 13 → 10 and hand the end state to Q12; (b) the `[E3]` inventory omitted `Invoke-SetupScenario.ps1` (+88) and `Invoke-RunScenario.ps1` (+13) although it claimed nine modified files — both are now listed and dispositioned; (c) `Seal-Study` used a verb `Get-Verb` rejects, so the seal operation is `Complete-Study` with `Seal-Study` as an alias; (d) the plan did not account for its own companion `docs/targeted-chaos-skills.decisions.md`, which is now a Modified-Files row and part of E15-T3. | An overstated goal, a two-file gap in an inventory the reader is told is exhaustive, and a function name that fails the repository's own linting are each things an implementer would act on and find false. Recorded so the next reader does not re-derive "five skills" as the shipped surface. |
