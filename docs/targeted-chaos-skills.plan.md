# Targeted Chaos Skills & Tools — Solution Design and Implementation Plan

| | |
|---|---|
| **Repository** | `microsoft/chaos-studio` |
| **Component** | `copilot-cli-plugin/` (plugin `startchaos`), `copilot-cli-plugin/mcp/chaos_mcp` (MCP server `chaos-studio`) |
| **Status** | Draft for implementation review; independent review corrections applied (Technical 86/100, Readability 91/100; re-review pending) |
| **Audience** | Chaos Studio engineering, Copilot plugin owners, Azure Monitor/Advisor partners |
| **Revision** | Revision 5 — contract-correction pass; see §Appendix A |
| **Research baseline** | **`55c74c59a5eb123edecd91374be4d385407be8f0`** (authoritative `main` snapshot for every `[MAIN]` statement) |

---

## How to Read This Document

**Evidence/source labels.** Every implementation claim is classified:

- **`[MAIN]`** — proved from commit **`55c74c59a5eb123edecd91374be4d385407be8f0`** with `git show`/`git ls-tree`.
- **`[PR32 PROTOTYPE]`** — useful prior art from PR #32 / `renzopretto-microsoft-add-chaos-loop-plugin`; it never merged and does **not** exist on current main.
- **`[NEW]`** — proposed additive or backward-compatible hardening.

**ID namespaces.** Ten reference schemes are used throughout; every cross-reference resolves to one of these.

| Prefix | Meaning | Defined in |
|---|---|---|
| **F1–F15** | Field evidence — observations from a real engagement, treated as requirements | §Background → Field evidence |
| **P1–P11** | Problems the design addresses | §Problem Statement |
| **G1–G11** / **N1–N8** | Goals / Non-Goals | §Goals and Non-Goals |
| **FR-1–FR-18** / **NFR-1–NFR-10** | Functional / Non-functional requirements | §Requirements |
| **D1–D18** | Design decisions with rationale | §Proposed Design → Design Decisions |
| **DQ-\*** | Deterministic disqualification rules for recommendations | §Recommendation Scoring and Disqualification |
| **ALT-1–ALT-10** | Alternatives evaluated and why they were rejected or deferred | §Alternatives Considered |
| **Q1–Q13** | Open questions with a stated current lean | §Open Questions |
| **CS-1–CS-10** | Chaos Studio **product/service** issues — filed with the service team, not fixed here | §Chaos Studio Product Issues |
| **E\<n\>-T\<n\>** | Epic *n*, task *n* | §Implementation Plan |

**Contents**

1. [Executive Summary](#executive-summary)
2. [Background](#background) — current state, prior art, why now, field evidence F1–F15, corrections
3. [Problem Statement](#problem-statement) — P1–P11
4. [Goals and Non-Goals](#goals-and-non-goals) — G1–G11, N1–N8
5. [Requirements](#requirements) — FR-1–FR-18, NFR-1–NFR-10
6. [Proposed Design](#proposed-design) — architecture, the eight skills, reference documents, permission-blocker acquisition, MCP tools, data flow, API contracts, decisions D1–D18
7. [Detailed Design](#detailed-design) — code/IaC analysis, scoring and disqualification, execution guardrails, run monitoring, evidence provenance, testing strategy, migration and reuse
8. [Chaos Studio Product Issues](#chaos-studio-product-issues-separate-from-this-plan) — CS-1–CS-10
9. [Alternatives Considered](#alternatives-considered) — ALT-1–ALT-10
10. [Dependencies](#dependencies) · [Impact Analysis](#impact-analysis) · [Security Considerations](#security-considerations) · [Risks and Mitigations](#risks-and-mitigations)
11. [Open Questions](#open-questions) — Q1–Q13
12. [Implementation Phases](#implementation-phases) — Phases 0–7 mapped to epics
13. [Files Affected](#files-affected) — modified main assets, new assets, and prototype assets not ported
14. [Implementation Plan](#implementation-plan) — Epics 1–11 plus Epic 7a
15. [References](#references)
16. [Appendix A: Revision History and Corrections](#appendix-a-revision-history-and-corrections)

---

## Executive Summary

This is an **evolution and hardening plan for the shipped `startchaos` v0.3.0 plugin**, not a greenfield replacement. **`[MAIN]`** already provides five independently invocable skills, a resumable orchestration path, shared PowerShell libraries, an impact schema/report and offline replay, and 15 MCP tools for workspace, scenario, run, auth, metrics, logs and Activity Log. **`[NEW]`** work begins by making those contracts safer and more durable, then adds targeted entry skills only where they clarify ownership. **Do not port the never-merged prototype; evolve current shipped assets.**

The proposed targeted entry points remain `chaos-scope-setup`, `chaos-inventory`, `chaos-availability`, `chaos-analyze`, `chaos-recommend`, `chaos-run`, `chaos-diagnose`, and `chaos-evidence`, but they compose the current five skills rather than replacing them in the first release. Deterministic code owns discovery joins, scoring, window arithmetic, proof and verdicts; the model owns semantic code/IaC analysis and narrative. The field-derived verdict decisions remain load-bearing: two-sided per-leg proof, mechanism liveness, failure-mechanism classes, and `CONFIRMED` / `REFUTED` / `NOT EXERCISED`.

---

## Background

### Current state — authoritative `[MAIN]` baseline

**Research SHA: `55c74c59a5eb123edecd91374be4d385407be8f0`.** All facts in this section were read from that tree; runtime/service behavior not represented there remains an open question.

`[MAIN]` `startchaos` is version **0.3.0** in `copilot-cli-plugin/plugin.json`, `copilot-cli-plugin/mcp/pyproject.toml`, and `.github/plugin/marketplace.json`. It already provides:

- workspace create/get and recommendation refresh;
- scenario listing, configuration create, validation, permission fix, execute/get/cancel;
- CLI and managed-identity authentication;
- MCP metrics, Log Analytics logs, and Activity Log queries;
- PowerShell impact collection across metrics, logs, Activity Log, **alert instances, and Service Health**;
- impact schema/report generation and an offline replay harness;
- resumable state through `$env:STARTCHAOS_STATE_PATH`, defaulting to **`./startchaos-state.json`** through `scripts/State.ps1`.

The last two surfaces must not be conflated: `[MAIN]` PowerShell `chaos-impact` queries alerts and Service Health; `[MAIN]` MCP exposes only metrics/logs/Activity Log monitoring. Also, `[MAIN]` has **no durable evidence store outside the repository/session tree**. Its configurable state path and reports are resumable, but default to the current directory or alongside that state file.

#### Exhaustive baseline inventory and disposition

Disposition is conservative. No shipped asset is retired in the initial hardening release.

| Existing asset/path | Current responsibility | Strengths | Observed field/source gap | Disposition |
|---|---|---|---|---|
| `[MAIN] copilot-cli-plugin/skills/start-chaos/SKILL.md` + `copilot-cli-plugin/skills/start-chaos/scripts/Invoke-StartChaos.ps1` | Human orchestration: auth → workspace → setup → run with resumable state | Shipped trigger/front door; fixed error/exit protocol | Does not own durable external evidence or targeted cold-entry diagnosis (F12/F14) | EXTEND |
| `[MAIN] copilot-cli-plugin/skills/create-workspace/**` | Workspace, identity, scope validation and Reader grants | Explicit interactive path; uses shared CLI/RBAC/state | Scope planning/reuse proof and evidence durability can improve | EXTEND |
| `[MAIN] copilot-cli-plugin/skills/setup-scenario/**` | Refresh/list recommendations, configure, validate, fix permissions | Already validates and persists results; scenario names come from service | Broad permission fix is default fallback; exclusions/fault semantics are hard to discover (F8) | REFACTOR |
| `[MAIN] copilot-cli-plugin/skills/run-scenario/**` | Confirm, validate/fix, start, recover run ID, poll, report | Strict validation gate exists before CLI `--skip-validation`; resumable polling/report | Run fallback lacks request-time/concurrency proof; identity fields may be null (F7) | EXTEND |
| `[MAIN] copilot-cli-plugin/skills/chaos-impact/**` | Post-run impact collection/correlation/report | Mature schema, templates, Pester tests, replay; alerts + Service Health included | No two-sided data-plane verdict, normalized App Insights pack, or durable external store (F2–F6/F12) | EXTEND |
| `[MAIN] copilot-cli-plugin/agents/start-chaos.md` | Top-level agent instructions for the shipped workflow | Preserves the guided path | Needs runtime tool preflight and new evidence/verdict contracts | EXTEND |
| `[MAIN] copilot-cli-plugin/scripts/Ensure-AzLogin.ps1`, `copilot-cli-plugin/scripts/Invoke-AzRest.ps1`, `copilot-cli-plugin/scripts/Invoke-AzChaos.ps1`, `copilot-cli-plugin/scripts/Wait-AzureLro.ps1` | Auth, ARM/CLI invocation, Chaos extension bootstrap, LRO polling | Central retry/invocation seams; cross-platform | API/version and provenance metadata are distributed | EXTEND |
| `[MAIN] copilot-cli-plugin/scripts/Rbac.ps1`, `copilot-cli-plugin/scripts/Validate-AndFix.ps1` | RBAC preflight/remediation and validate/fix/revalidate | Existing exact remediation helpers and strict validation flow | Auto-fix is broad; targeted validation output should be preferred | REFACTOR |
| `[MAIN] copilot-cli-plugin/scripts/State.ps1`, `copilot-cli-plugin/scripts/Render.ps1`, `copilot-cli-plugin/scripts/New-RunReport.ps1` | JSON state, terminal rendering, run report | Reusable and already integrated | Repo/session-local default does not survive F12-class cleanup | EXTEND |
| `[MAIN] copilot-cli-plugin/.chaos-plugins.yaml.example` | Optional API/polling/workspace/state overrides | Existing compatibility/configuration surface | No external evidence-root/retention or proof policy | EXTEND |
| `[MAIN] copilot-cli-plugin/skills/chaos-impact/schema/impact-report.schema.json` | `impactReportSchemaVersion: 1` contract | Stable machine-readable sidecar | Not a verdict/evidence-bundle schema | EXTEND |
| `[MAIN] copilot-cli-plugin/skills/chaos-impact/templates/{kql,metrics}/**`, `copilot-cli-plugin/skills/chaos-impact/templates/report.md.tmpl` | KQL, metric defaults/thresholds, report rendering | Service/resource-specific reusable knowledge | App Insights classic normalization and proof predicates are incomplete | EXTEND |
| `[MAIN] copilot-cli-plugin/skills/chaos-impact/scripts/{Constants,Get-DiagnosticSettings,Get-MonitorSignals,Build-ImpactCorrelation,New-ImpactReport,Invoke-ChaosImpact}.ps1` | Six-surface collection, correlation and report pipeline | Alerts fallback, Service Health separation, query trail, partial-mode handling | Fault-window normalization and data-plane proof are not first-class | EXTEND |
| `[MAIN] copilot-cli-plugin/skills/chaos-impact/tests/*.Tests.ps1` | Unit/regression coverage for impact scripts | Existing Pester investment | Needs F1–F15 regressions and compatibility assertions | EXTEND |
| `[MAIN] copilot-cli-plugin/skills/chaos-impact/tests/e2e/OfflineReplayE2E.Tests.ps1`, `copilot-cli-plugin/skills/chaos-impact/tests/e2e/Run-OfflineReplay.ps1`, `copilot-cli-plugin/skills/chaos-impact/tests/e2e/recorded-*.json`, `copilot-cli-plugin/skills/chaos-impact/tests/e2e/expected-impact.json` | Hermetic replay and golden expected impact | Network-free, recorded evidence | Covers impact path, not all targeted contracts | EXTEND |
| `[MAIN] copilot-cli-plugin/mcp/chaos_mcp/server.py` | **All 15 `@mcp.tool()` registrations** and 12 Chaos/auth implementations plus 3 monitor wrappers | Single registry; stable envelope; direct lifecycle coverage | Missing additive proof/pack tools and stronger run identity | EXTEND |
| `[MAIN] copilot-cli-plugin/mcp/chaos_mcp/azure.py` | CLI/MSI token acquisition, ARM/LA HTTP, retry/LRO, `_TEST_TRANSPORT` | Offline-test seam; structured `AzureError` | API pins distributed; list/paging/provenance helpers limited | EXTEND |
| `[MAIN] copilot-cli-plugin/mcp/chaos_mcp/monitor.py` | Helpers called by the 3 monitor wrappers | Correct metrics/logs/Activity Log request construction and envelope | No alert-instance/App Insights normalization/fault-window pack (F2–F4) | EXTEND |
| `[MAIN] copilot-cli-plugin/mcp/tests/test_auth_mode.py`, `copilot-cli-plugin/mcp/tests/test_monitor_tools.py` | Auth/tool tests; monitor happy/error/retry tests; tool-list count | Hermetic pytest and explicit 15-tool registry assertion | Ten lifecycle tools lack direct tests | EXTEND |
| `[MAIN] copilot-cli-plugin/mcp/pyproject.toml`, `copilot-cli-plugin/mcp/README.md`, `copilot-cli-plugin/mcp/mcp-config.example.json`, `copilot-cli-plugin/mcp/LICENSE`, `copilot-cli-plugin/mcp/chaos_mcp/__init__.py` | Package/version/entry point, operator docs/config, package identity | `chaos-mcp` console script; Python 3.10+; MCP guidance | Actual PyPI publication/runtime installation is not proved by source | EXTEND |
| `[MAIN] copilot-cli-plugin/plugin.json` | Registers `skills/`, `agents/`, and `mcpServers.chaos-studio` command `chaos-mcp` | One installable plugin surface | Registration does not prove a given runtime session exposes any tool (F5) | EXTEND |
| `[MAIN] .github/plugin/marketplace.json` | Marketplace metadata/version | Version aligned at 0.3.0 | Must remain lockstep with package/manifest | EXTEND |
| `[MAIN] copilot-cli-plugin/README.md`, `copilot-cli-plugin/CHANGELOG.md`, `copilot-cli-plugin/CONTRIBUTING.md`, `copilot-cli-plugin/docs/impact-synthesis-skill.md` | User, release, contributor, and impact docs | Documents both skill/MCP surfaces and impact output | Some historical counts/names drift; targeted evolution needs explicit compatibility docs | EXTEND |
| `[MAIN] .github/workflows/test.yml` | Pester on ubuntu/windows/macos; pytest Python 3.10–3.13; ruff | Cross-OS/cross-version matrices | Needs compatibility/contract regressions, not replacement | EXTEND |
| `[MAIN] .github/workflows/release.yml` | Builds sdist/wheel, publishes `chaos-mcp`, creates GitHub release | Existing release automation | Workflow presence does not prove current PyPI publication status | RETAIN AS-IS |
| `[MAIN] .github/dependabot.yml` | Weekly pip and GitHub Actions updates | Existing dependency hygiene | No field-derived gap | RETAIN AS-IS |

#### Exact current-state 15-tool matrix

All **15 decorators are in `[MAIN] copilot-cli-plugin/mcp/chaos_mcp/server.py`**. `monitor.py` contains helpers called by the final three wrappers; it contains **no decorators**. Every tool returns `{"ok": true, "result": ...}` or an `{"ok": false, "errorType": ..., "error": ...}` envelope. Chaos/auth tools currently use `AzureError`; monitor helpers additionally classify HTTP 401/403 as `AuthenticationFailed`/`PermissionDenied`. Additive work preserves these envelopes.

`plugin.json` registers `skills/`, `agents/`, and `mcpServers.chaos-studio.command = "chaos-mcp"`. That registration makes tools installable; it does **not** guarantee that a particular runtime session connected the server or surfaced every tool (F5).

In the matrix, **Manifest/skill availability** means the server is registered once for the plugin and the named skill documentation recommends the MCP tool as the autonomous alternative. The interactive skill scripts remain a separate PowerShell surface; they do not invoke the Python MCP server internally.

| Tool | Parameters (current signature) | Current output/behavior | Implementation | Manifest/skill availability | Tests on main | Proposed additive/breaking change |
|---|---|---|---|---|---|---|
| `chaos_set_auth_mode` | `mode`, `msi_client_id=None` | Sets session override; returns effective `{mode, msiClientId, source}` | `server.py` → `azure.py` | MCP README; server registered, not host-guaranteed | `test_auth_mode.py` | Preserve name/signature/envelope; add preflight/docs only; **no breaking change** |
| `chaos_get_auth_mode` | none | Returns effective auth config | `server.py` → `azure.py` | MCP README; server registered, not host-guaranteed | `test_auth_mode.py` | Preserve unchanged |
| `chaos_create_workspace` | `subscription_id`, `resource_group`, `workspace_name`, `location`, `scopes`, `identity_type="SystemAssigned"`, `user_assigned_identity_resource_id=None` | PUT + LRO + GET; grants workspace identity Reader on scopes | `server.py` + `azure.py` | `create-workspace`, `start-chaos`, README | No direct lifecycle test | Add optional provenance/dry-run fields only if backward compatible |
| `chaos_get_workspace` | `subscription_id`, `resource_group`, `workspace_name` | GET workspace | `server.py` + `azure.py` | README/start workflow | No direct lifecycle test | Preserve; enrich result only additively |
| `chaos_refresh_recommendations` | `subscription_id`, `resource_group`, `workspace_name` | POST `refreshRecommendations`, wait, GET `evaluations/latest` | `server.py` + `azure.py` | `setup-scenario`, README | No direct lifecycle test | Retain canonical current name; additive freshness/provenance fields |
| `chaos_list_recommended_scenarios` | `subscription_id`, `resource_group`, `workspace_name` | GET scenarios; returns `value[]` | `server.py` + `azure.py` | `setup-scenario`, README | No direct lifecycle test | Extend returned metadata; do not rename initially |
| `chaos_create_scenario_configuration` | `subscription_id`, `resource_group`, `workspace_name`, `scenario_name`, `configuration_name`, `configuration` | PUT + LRO + GET final configuration | `server.py` + `azure.py` | `setup-scenario`, README | No direct lifecycle test | Preserve; support explicit targeting/exclusions through existing body |
| `chaos_validate_scenario_configuration` | `subscription_id`, `resource_group`, `workspace_name`, `scenario_name`, `configuration_name` | POST validate + LRO + GET configuration-scoped `validations/latest` | `server.py` + `azure.py` | `setup-scenario`, run flow, README | No direct lifecycle test | Preserve; expose normalized errors additively |
| `chaos_fix_resource_permissions` | same five identity fields, `what_if=False` | POST broad fix + LRO + GET latest fix result | `server.py` + `azure.py` | `setup-scenario`, README | No direct lifecycle test | Retain behind explicit consent; prefer targeted guidance; no initial deprecation |
| `chaos_execute_scenario` | `subscription_id`, `resource_group`, `workspace_name`, `scenario_name`, `configuration_name` | POST execute; parse Location or choose newest matching config run; returns `scenarioRunId` or error | `server.py` + `azure.py` | `run-scenario`, `start-chaos`, README | No direct lifecycle test | Add request timestamp/retry and optional identity metadata in result; signature/envelope stay |
| `chaos_get_scenario_run` | `subscription_id`, `resource_group`, `workspace_name`, `scenario_name`, `scenario_run_id` | GET one run snapshot | `server.py` + `azure.py` | `run-scenario`, README | No direct lifecycle test | Add normalized action identity fields without removing raw payload |
| `chaos_cancel_scenario_run` | `subscription_id`, `resource_group`, `workspace_name`, `scenario_name`, `scenario_run_id` | POST best-effort cancel; returns `cancelRequested` | `server.py` + `azure.py` | `run-scenario`, README | No direct lifecycle test | Preserve semantics; actual service cancellation behavior remains open |
| `monitor_query_metrics` | `resource_id`, `metric_names`, `start_time`, `end_time`, `aggregation="Average"`, `interval="PT1M"` | Validates names; Monitor metrics query | `server.py` wrapper → `monitor.py` | `chaos-impact`, README | `test_monitor_tools.py` | Preserve; compose into new pack |
| `monitor_query_logs` | `workspace_id`, `kql`, `timespan=None` | Validates KQL; Log Analytics POST | `server.py` wrapper → `monitor.py` | `chaos-impact`, README | `test_monitor_tools.py` | Preserve raw escape hatch; add distinct App Insights normalizer |
| `monitor_search_activity_log` | `subscription_id`, `start_time`, `end_time`, `resource_uri=None` | OData Activity Log query; returns `{count, events}` | `server.py` wrapper → `monitor.py` | `chaos-impact`, README | `test_monitor_tools.py` | Preserve; never treat as fault-landed proof |

### Prior art — `[PR32 PROTOTYPE]`, never merged

PR #32 / branch `renzopretto-microsoft-add-chaos-loop-plugin` introduced `chaos-loop`, internal phases, `chaos_loop_state.py`, three schemas, and reference documents. **None of those paths exist on `[MAIN]`. Do not port the never-merged prototype; evolve current shipped assets.**

Useful patterns to re-express in `[MAIN]` assets are the proposal/evaluate split, locked revisioned writes, evidence invariants, `frozenValidation`, the three-verdict vocabulary, and the verify-mode changed-path rule. `[PR32 PROTOTYPE]` artifacts that are explicitly **not ported** are:

- the monolithic `chaos-loop` controller and `advisory`/`coding` phases;
- `references/chaos-loop/scenario-catalog.v1.json` and `.md` — **do not port** the prototype catalog; there is nothing to delete from main;
- repo-local `tmp/chaos-loop/...` state;
- the all-or-nothing external gate and monolithic run-state schema.

### Why evolve now

1. `[MAIN]` proves the end-to-end workspace/scenario/run and impact paths already work as a shipped plugin; hardening can be incremental.
2. `[NEW]` can build on service-returned recommendation/scenario/configuration data and existing validation rather than prompt-side catalogs.
3. Field evidence F1–F15 identifies concrete gaps in proof, durability, telemetry normalization and tool visibility without invalidating the current workflow.
4. Workspace/service API availability, retention/cancel semantics, preview operation availability, and actual PyPI publication status remain open until verified in the target runtime; source alone does not settle them.

### Field evidence — a real engagement

The following observations come from an engineer running the Chaos Loop skills against a live workload. They are cited throughout this document as **F1–F15** and are the primary motivation for several requirements that would otherwise look like gold-plating.

| ID | Observation | Consequence |
|---|---|---|
| **F1** | No build-identity attestation existed. The running build was ultimately identified *behaviourally*, by the disappearance of `ServiceBusReceiver.Peek` dependency spans. No `/version` endpoint, ACR tags were timestamps, VMSS `customData` was null. | Largest single time sink of the engagement; the `external-gate` demand for artifact→deployment→serving-revision proof was unsatisfiable. |
| **F2** | The same pre/during/post telemetry bundle (requests, dependencies, customMetrics, fired alerts) was hand-assembled four times across three runs. | Pure repeated toil; high transcription-error risk. |
| **F3** | "Did an alert instance fire inside the window" — the core acceptance predicate — required dropping to `az rest` against `Microsoft.AlertsManagement` with a hand-built `timeRange` filter. | Core predicate had no first-class tool. |
| **F4** | App Insights querying failed three times before returning data. Two causes are confirmed: `--subscription` had to be supplied even though the resource ID contains it; and resource-scoped queries silently need the **classic** schema (`dependencies`, `customMetrics`, `requests`, lowercase columns), not `AppDependencies`/`AppMetrics`. A third cause was originally recorded as "`first` is a reserved token" — see the correction note below. | Schema knowledge lived only in the engineer's memory file. |
| **F5** | The `diagnostic` skill instructed use of `monitor_query_logs` / `monitor_query_metrics` / `monitor_search_activity_log` "from the bundled chaos-studio MCP server". **Those tools were not present in the session's tool list.** | A skill naming non-existent tools is a silent trap; the engineer substituted `az` by hand. |
| **F6** | Chaos reported the Event Hubs entity status as `Disabled` — a control-plane assertion. `EventHubProducerClient.Send` was **60/60 successful** in the same window (58/0 in the prior run). The dependency was never disrupted. | **Both Event Hubs verdicts across two runs were unsound.** The originally recorded mechanism (`AmqpSender` caching `MaxMessageSize`) has been falsified — see the correction note below. The surviving, unfalsified part of the observation is that **an already-open AMQP producer link was not torn down by disabling the namespace**, which is exactly the class of SDK/service behaviour oracle that no code review catches. |
| **F7** | In run `f7cf6241`, `scenarioRunSummary[].actionName` came back **null for all three actions**. The engineer could not tell which leg was which from `run show` and had to infer from per-resource-type ARM polls. Separately, `run start --no-wait` returns an empty 2xx **with no run id**, forcing a `run list` filtered on `startTime` after every start. | Service bugs that directly obstruct evidence collection. |
| **F8** | Per-fault semantics are undocumented, `config validate` was unreachable from the agent's write allow-list, and exclusion-based leg starvation — the only way to isolate a single dependency — was undiscoverable. | Correct experiment design was not reachable from the tool surface. |
| **F9** | Azure Advisor was an **anti-correlation**: 16 HighAvailability recommendations on the resource group, **zero** matched any finding. Its nearest item, "Enable automatic repair policy on VMSS", was already satisfied — and auto-repair is driven by the `/health/ready` probe that this very investigation proved blind. | Advisor reasons about configuration *shape*; chaos findings are about *behaviour under fault*. Acting on Advisor here would have been a no-op that increased false confidence. |
| **F10** | Advisory A3's acceptance predicate (`dependency.ready → 0`) was formally valid and completely failed to detect that the new probe code was a no-op. Zero dependency spans from an "active" probe means it is not on the data plane. | A predicate can be valid and useless; the mechanism itself must be proven live. |
| **F11** | Three advisories failed for the same reason with three different implementations: `IsClosed` flags → `$management` round-trip → cached batch creation. All three were "a probe answerable from local state." `attemptedFixes` recorded the fixes, not the class. | The no-repeat rule keyed on the wrong field. |
| **F12** | `tmp/` was wiped twice. The second wipe also took `memories/sessionInsights/`; only `memories/synthesizedKnowledge/` survived. | Cost two runs, forced manual mode, and thereby lost the verify-mode rule that would have caught F10. |
| **F13** | A3 was ranked last (score 6.0) as "changes no signal the platform consumes" — true only until A2 shipped a reader. A2 without A3 was *worse than no signal*: a confidently green dashboard during a total outage. | Probe-accuracy fixes must be ranked and shipped jointly with their consumer. |
| **F14** | The `diagnostic` verify-mode rule was correct and load-bearing: A3 emitted zero dependency spans, so the correct verdict was `NOT EXERCISED` routed to an exercise-repair brief — not the `REFUTED` reached manually. | The loop already encoded the needed control; manual mode lost it. |
| **F15** | Two facts lived only in the engineer's personal memory file: prove fault-landed from **ARM entity state, not the Activity Log**; and **re-poll the NSG leg**, because an empty first read is a false negative. | Undocumented tribal knowledge determining verdict soundness. |

#### Corrections to the field record (external verification)

Field evidence is observational and was recorded under time pressure. Two of the *explanations* attached to it have since been falsified. The **observations** stand; the **mechanisms** do not, and this distinction matters because the plan turns mechanisms into normative documents.

| Item | Recorded explanation | Verification result | Consequence for this plan |
|---|---|---|---|
| **F4-c** | "`first` is a reserved token in KQL." | **Falsified.** `first` is not a KQL keyword or operator (KQL uses `take`/`limit`; `arg_min`/`arg_max` for first-row selection). `--first` is an **Azure CLI / Azure Resource Graph** paging parameter mapping to REST `$top`, with a documented maximum of 1000. The most probable real cause is CLI argument parsing, not KQL syntax. | **No escaping layer is built.** `monitor_query_appinsights` implements only the two verified fixes (subscription injection, classic resource-scoped schema). Re-deriving the third failure is **Q11**, and the regression test is renamed accordingly. |
| **F6** | "`AmqpSender` caches `MaxMessageSize` after first attach." | **Falsified.** In `Azure.Messaging.EventHubs`, `AmqpProducer.CreateLinkAndEnsureProducerStateAsync` sets `MaximumMessageSize` on **every** link open, with the explicit source comment *"Update the known maximum message size each time a link is opened, as the configuration can be changed on-the-fly and may not match the previously cached value."* (`InitializedPartitionProperties` *is* cached once; `MaximumMessageSize` is not.) | The **observation** — namespace `Disabled` with 60/60 successful sends — is unaffected and remains the canonical motivating case for two-sided attestation. The **seed entry** of `fault-semantics.md` is rewritten to state only what is observed, with the candidate mechanism marked `mechanismConfidence: unverified`. |
| **F6 (secondary)** | "Disabling a namespace does not force-detach an open AMQP producer link." | **Uncertain.** Plausible and consistent with the observation, but not documented by Microsoft. | Recorded in `fault-semantics.md` as `observed` with `mechanismConfidence: unverified`, and raised as **CS-5** for the Event Hubs/Chaos teams to confirm. |

**Rule adopted from this exercise, and enforced in `fault-semantics.md`:** every entry separates `observedEffect` (what was measured, with citations) from `candidateMechanism` (why we think it happened) and carries a `mechanismConfidence` of `verified` \| `plausible` \| `unverified`. Only `observedEffect` may drive a verdict. A behaviour oracle seeded with a misattributed mechanism is worse than an empty one.

---

## Problem Statement

**P1 — `[PR32 PROTOTYPE]` monolithic control.** The never-merged prototype exposed one skill (`chaos-loop`) covering nine journey steps. This is prior-art evidence, not current-main behavior.

**P2 — `[PR32 PROTOTYPE]` fabricated scenario knowledge.** Its `scenario-catalog.v1.json` hard-coded eleven scenario families. It is not on main and must not be ported.

**P3 — Control-plane assertions masquerading as disruption proof.** Chaos reports what it *intended* to mutate. F6 proves that intent ≠ effect: an entity marked `Disabled` while its producer link kept succeeding 60/60. Nothing in the current or prototype design distinguishes control-plane mutation from data-plane disruption, so verdicts can be — and were — unsound.

**P4 — Build identity is unprovable.** F1: the gate demanded artifact → deployment → serving-revision proof with no defined fallback. In practice this is either unsatisfiable (making the gate a blocker) or silently skipped (making it theatre).

**P5 — Telemetry assembly is manual and schema-fragile.** F2 and F4: the same pre/during/post bundle was hand-built four times, and App Insights schema quirks cost three failed calls per attempt. `monitor_query_logs` is a raw KQL passthrough that provides none of this.

**P6 — Core predicates lack tools.** F3: alert-instance queries required raw `az rest`. F7: run-ID recovery required a `run list` filtered on `startTime` after every start, and `actionName` was null so per-leg attribution required inference.

**P7 — Skills reference tools that may not exist.** F5: a skill named three MCP tools absent from the session. There is no declaration of required tools and no preflight reconciliation.

**P8 — Evidence durability gap.** F12 destroyed prototype/field `tmp/` evidence. `[MAIN]` improves this with configurable resumable `STARTCHAOS_STATE_PATH`, but has no default external evidence store and therefore still needs an additive mirror.

**P9 — Grounding sources inverted.** F9: the prototype's `advisory` skill required "a directly matching Azure Advisor reliability recommendation, or one named WAF guideline when Advisor has no coverage." Advisor will nearly always have no coverage for behaviour-under-fault findings, so the exception clause is the default path. Meanwhile the genuinely valuable output — chaos evidence that a health probe is blind — has no path back into Advisor.

**P10 — Weak no-repeat semantics.** F11: recording attempted *fixes* rather than failure *mechanism classes* let the same error class recur three times.

**P11 — Ranking ignores consumer coupling.** F13: a fix scored in isolation was ranked last, then became the correctness blocker for a higher-ranked fix that shipped first.

---

## Goals and Non-Goals

### Goals

- **G1** — Eight independently invocable, user-facing skills, each owning exactly one journey step, each emitting a versioned JSON artifact and opinionated next-step guidance. No agent handoffs.
- **G2** — Zero hard-coded runtime scenario catalogs. Scenario/action eligibility comes from service responses; the separate fault-semantics reference records observed effects/probes and never fabricates availability.
- **G3** — Every recommendation carries evidence with provenance, freshness, and a confidence band; no recommendation may cite a scenario the service has not returned for that scope.
- **G4** — Deterministic-by-default: discovery, eligibility joins, scoring, blast-radius computation, window arithmetic, fault-landed proof, work-starvation checks and verdict derivation are computed by code. The model produces only semantic analysis, hypotheses, and narrative.
- **G5** — Fault-landed proof is **two-sided**: a control-plane attestation (ARM entity state, per F15 — not the Activity Log) *and* a per-leg data-plane disruption attestation. A run with control-plane-only proof yields `NOT EXERCISED` for that leg.
- **G6** — Build identity is attested through a documented **fallback ladder** with the used rung recorded in the artifact (F1).
- **G7** — A single `monitor_fault_window_pack` tool returns the complete pre/during/post evidence bundle for a run ID, on the correct App Insights schema, including fired alert instances (F2, F3, F4).
- **G8** — Every skill declares its required MCP tools; a preflight reconciliation fails fast and names the missing tools (F5, F7-adjacent).
- **G9** — Evidence is persisted to a durable, configurable store outside `tmp/`, mirrored after every phase, and re-openable by run ID in a later session (F12, P8).
- **G10** — Verdicts are `CONFIRMED` / `REFUTED` / `NOT EXERCISED` only, computed by a deterministic matrix over numeric evidence.
- **G11** — Chaos Studio product/service defects are tracked and reported separately from skill-instruction changes, with the plan degrading gracefully around each open defect.

### Non-Goals

- **N1** — Not a code-remediation agent. The prototype's `coding` phase and autonomous PR authoring are out of scope. `chaos-analyze` may describe a remediation; it does not implement one.
- **N2** — No new Azure control-plane surface is designed here. Service-side gaps (§"Chaos Studio Product Issues") are filed, not built.
- **N3** — Not a replacement for `chaos-impact`. Its schema, thresholds, KQL templates and offline-replay harness are retained and reused.
- **N4** — No unattended, approval-free fault injection. Execution always crosses an explicit human approval boundary.
- **N5** — No source-repository write access. Repositories are read-only inputs to analysis.
- **N6** — Not an SLO management product. SLO/SLI definitions are consumed as inputs; the suite does not author them.
- **N7** — No general Azure inventory tool. Inventory is scoped to what chaos targeting, telemetry correlation and blast-radius computation require.
- **N8** — Advisor is not a grounding gate (F9). Advisor data is optional context and a *destination* for chaos findings, not a prerequisite.

---

## Requirements

### Functional

| ID | Requirement |
|---|---|
| **FR-1** | Accept an Azure scope (subscription, resource group, or explicit resource ID list) and discover an existing Chaos Workspace or plan/provision one, never mutating an existing workspace without explicit confirmation. |
| **FR-2** | Inventory resources, inferred service dependencies, observability wiring (App Insights / LA workspace / diagnostic settings / alert rules), deployment topology, and candidate source/IaC repositories for that scope. |
| **FR-3** | Return the scenarios and actions the service actually reports for the scope, with `recommendationStatus`, evaluation timestamp, required parameters, action URNs and target capability requirements. Permission blockers are returned **only when a probe validation has been authorised** (see FR-16), and their absence is reported as `permissionBlockers: null` with a caveat — never as "no blockers". |
| **FR-4** | Analyse infrastructure and service code to produce ranked, falsifiable hypotheses, each grounded in cited code/IaC/resource evidence with an explicit correlation confidence. |
| **FR-5** | Map each hypothesis to an *eligible* scenario, producing: proving fault (action URN), steady-state predicate, work/exercise predicate, confirm/refute telemetry predicate, blast radius (as `resourceTargeting`), safety guardrails, and expected changed code path. Hypotheses with no eligible scenario are reported as unmappable with the eligibility gap named. |
| **FR-6** | Present ranked recommendations with evidence, confidence, eligibility gaps and remediation steps; never emit a scenario absent from the service response for that scope. |
| **FR-7** | Configure and execute exactly one selected scenario behind an approval boundary, with `frozenValidation` drift detection, deterministic run-ID recovery, cancellation, and recovery guidance. |
| **FR-8** | Monitor the exact run window across Azure Monitor metrics, App Insights, Log Analytics, Activity Log and alert instances; emit numeric evidence and a computed verdict. |
| **FR-9** | Attest build identity via the fallback ladder and record which rung was used. |
| **FR-10** | Attest fault landing per targeted leg, separating control-plane mutation from data-plane disruption, with re-poll on empty first reads. |
| **FR-11** | Persist run identity and all phase evidence to a durable store; support `chaos-diagnose --run-id` and `chaos-evidence --run-id` in a fresh session with no prior conversational context. |
| **FR-12** | Record attempted-fix **failure mechanism classes**, not just fix descriptions, and block a new proposal that falls in an already-failed class without new evidence. |
| **FR-13** | Any hypothesis or advisory that changes an observability or health-probe signal must carry a second **mechanism-liveness predicate** asserting the mechanism executes (e.g. emits telemetry per invocation). |
| **FR-14** | Each skill declares required MCP tools and reference files in its manifest; a preflight check reconciles the declaration against the **host-visible** tool inventory (the MCP host's `tools/list` result, which the agent already sees) and fails with the missing names. Reconciliation must not depend on a tool hosted by the server whose availability is in question. |
| **FR-15** | Export a self-contained evidence bundle (JSON + rendered Markdown) suitable for review outside the tool. |
| **FR-16** | Because `validations/latest` is configuration-scoped and unreachable without creating a `ScenarioConfiguration`, `chaos-availability` operates in two explicit tiers: **Tier A (non-destructive, default)** derives eligibility from the capability map, `recommendationStatus` and parameter satisfiability; **Tier B (probe validation, opt-in)** creates a disposable, non-executing `ScenarioConfiguration` per candidate scenario, POSTs `validate`, reads `validations/latest`, and deletes the configuration. Tier B creates and deletes customer-visible resources, requires explicit consent naming the scenarios and the configurations, and is never entered implicitly. |
| **FR-17** | The failed-mechanism-class ledger is a first-class, schema-validated, durably-stored artifact (`mechanism-ledger.v1.json`) keyed on `scopeId`, appended by `chaos-diagnose` and read by `chaos-analyze`. |
| **FR-18** | Execution approval is represented by a token that is issued outside the model's control, bound to the `frozenValidation` hash, single-use, and time-bounded. |

### Non-Functional

| ID | Requirement |
|---|---|
| **NFR-1** | Deterministic components are unit-testable offline via the existing `_TEST_TRANSPORT` MockTransport and recorded fixtures; no test requires Azure. |
| **NFR-2** | All timestamps ISO-8601 UTC with a `Z` suffix; all windows half-open `[start, end)`. |
| **NFR-3** | Missing data is `null` with a caveat string. A cited `0` must be a measured zero. Null-vs-zero conflation is a contract violation. |
| **NFR-4** | Least privilege: `Reader` for discovery/inventory/analysis. `chaos-availability` Tier A is **non-destructive but not strictly read-only** — when freshness requires it, it calls shipped `chaos_refresh_recommendations` (`POST …/refreshRecommendations`, then `GET …/evaluations/latest`); it creates no customer-visible resource and mutates no customer workload. Tier B additionally requires configuration create/delete on the workspace and is opt-in. Execution write scope is limited to the workspace and the explicitly targeted resources. |
| **NFR-5** | Every artifact carries `schemaVersion`, `generatedAt`, `source` and `freshness`; consumers reject artifacts older than a configured staleness bound with an explicit refresh instruction. |
| **NFR-6** | ARM/ARG calls use the existing backoff helpers; ARG paging respects the **documented** limits — 1,000 records per page and a maximum of three `join`/`union` operations per query. No per-query time limit is designed around, because none is documented in the public ARG reference; throttling is a documented per-5-second quota that the existing backoff helpers already handle. |
| **NFR-7** | MCP tools carry accurate annotations. `outputSchema` is conditional: the source range `mcp>=1.2.0,<2` does not prove the installed version or host protocol capability. Epic 1 verifies the target runtime; otherwise contract tests enforce the existing envelope without claiming structured-output support. |
| **NFR-8** | No secret, connection string, or token is written to any artifact; repository content is quoted only as file path + line range + a bounded excerpt. |
| **NFR-9** | *Target state.* Pinned API versions live in one place per language — `scripts/Constants.ps1` for PowerShell, a new `chaos_mcp/apiversions.py` for Python. **This is not true today**: pins live in `azure.py` (3), `monitor.py` (2) and `server.py` (1). E1-T7 consolidates them and adds a lint test that fails on any `API_VERSION` literal outside the constants module. |
| **NFR-10** | `[NEW]` changes are additive: retain the five current skill names/triggers, all 15 tool names/signatures/envelopes, `impactReportSchemaVersion: 1`, and existing `STARTCHAOS_STATE_PATH` files throughout the v0.x migration. |

### Source + field gap-to-improvement matrix

This is the minimum hardening backlog. It ties each improvement to current behavior and prevents a targeted skill from duplicating a capability `[MAIN]` already owns.

| Evidence/source | Current behavior | Failure/pain | Minimal improvement | Target asset | Compatibility/migration |
|---|---|---|---|---|---|
| **F1** build attestation | `[MAIN]` run/report records run identity, not serving build identity | Artifact→deployment→serving proof was unavailable | Add version→digest→windowed behavioral ladder with rung/caveats | Extend `server.py` run retrieval/execution result plus `[NEW] proof.py` only for distinct attestation logic | Add fields; old consumers ignore them |
| **F2** fault-window telemetry pack | `[MAIN]` `chaos-impact` collects a buffered window; MCP exposes raw metrics/logs/activity calls | Same pre/during/post pack hand-built repeatedly | Compose existing collectors into one normalized pack | Extend `copilot-cli-plugin/mcp/chaos_mcp/monitor.py`, add `server.py` wrapper and `copilot-cli-plugin/mcp/tests/test_monitor_tools.py`; reuse `Get-MonitorSignals.ps1` | Existing three monitor tools remain unchanged |
| **F3** alert instances | `[MAIN]` PowerShell impact queries AlertsManagement; MCP does not | Agent used raw `az rest` for exact window | Reuse request/normalization knowledge in a new MCP wrapper | Extend `monitor.py` + `server.py` + `test_monitor_tools.py` | Additive tool; PowerShell output/schema retained |
| **F4** App Insights classic schema + subscription | `[MAIN]` raw Log Analytics tool and KQL templates do not normalize resource-scoped classic queries | Repeated schema/subscription failures | Inject subscription and map classic lowercase tables/columns | Extend `monitor.py`; server wrapper; recorded test | Keep raw `monitor_query_logs` as escape hatch |
| **F5** runtime availability | `[MAIN]` manifest registers server; skills name tools | A session may not expose registered tools | Host-visible preflight + CI manifest lint | Existing SKILL.md files, `plugin.json`, `.github/workflows/test.yml` | No server self-introspection tool; named failure only |
| **F6/F15** per-leg disruption proof | `[MAIN]` impact correlates signals but does not require two planes; Activity Log is available | Control-plane state produced unsound verdicts | Per-leg ARM entity read + independent data-plane delta; re-poll empty reads | `[NEW] proof.py`, `server.py` wrapper; consume current impact/monitor outputs | Additive proof tool; no impact-schema break |
| **F7** action identity/run-ID recovery | `[MAIN]` PowerShell and MCP recover IDs; MCP chooses newest matching configuration; action name may be null | Concurrent run ambiguity and leg mislabeling | Filter after `requestSentAt`, bounded retry, return raw + normalized identity source/confidence | Extend `server.py`; direct lifecycle tests | Same execute/get signatures; additive result fields |
| **F8** fault semantics | `[MAIN]` service configuration/validation works but semantic effect is undocumented | Correct probe/starvation recipe unavailable | Versioned observed-effect oracle separated from candidate mechanism | `[NEW] references/chaos/fault-semantics.md`; consumed by proof | No runtime catalog replacement |
| **F8** exclusions/config validation | `[MAIN]` setup/run already validate and can carry `resourceTargeting`; broad fix may run | Exclusion recipes and targeted blockers are hard to discover | Surface include/exclude preview, normalized errors, targeted remediation before broad fix | Refactor `setup-scenario`, `run-scenario`, `Validate-AndFix.ps1`; extend validation tool output | Preserve configuration body and broad fix behind consent |
| **F12** durable evidence | `[MAIN]` configurable state defaults to `./startchaos-state.json`; reports live beside state/session | Repo/session cleanup destroyed evidence | Mirror current state/artifacts atomically to per-user configurable evidence root | Extend `State.ps1`; `[NEW] evidence.py` only if MCP access is required | Existing state remains source-compatible and importable |
| **F10/F14** mechanism-liveness predicates | `[MAIN]` impact shows signals; no explicit predicate that the measuring mechanism ran | Dead probe can satisfy a formal predicate | Require liveness predicate before verify verdict | `[NEW] verdict.py` + evidence/verdict references; targeted diagnose skill | Additive artifact fields; no old path regression |
| **F11** failure-mechanism classes | `[MAIN]` no durable class ledger | Same class repeated under different fixes | Append-only class + occurrence ledger | Durable evidence layer + `[NEW] analysis.py` pure function | New artifact; never rewrite old state |
| **F9/F13** Advisor de-emphasis/reverse flow | `[MAIN]` does not need Advisor for execution | Advisor anti-correlated with behavioral findings | Keep Advisor optional; defer reverse export until a consumer exists | Docs/evidence transform only | No dependency or release gate |
| Service issues | `[MAIN]` impact reports Service Health separately | Platform incidents can be mistaken for chaos effects | Preserve separate `platformEvent`/Service Health classification | Extend current impact report without merging verdict inputs | `impactReportSchemaVersion: 1` stays readable |

---

## Proposed Design

Unless a row is explicitly marked `[MAIN]` or `[PR32 PROTOTYPE]`, it describes `[NEW]` work. Every `[NEW]` entry names the current asset it composes or extends.

### Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         Copilot CLI — user-facing skills                      │
│                                                                              │
│  chaos-scope-setup → chaos-inventory → chaos-availability                    │
│                                    ↘                    ↘                    │
│                                     chaos-analyze → chaos-recommend          │
│                                                            ↓                 │
│                                        chaos-run → chaos-diagnose            │
│                                                            ↓                 │
│                                                     chaos-evidence           │
│  (every arrow is *guidance*, not a handoff — each skill is entered directly) │
└──────────────────────────────────────────────────────────────────────────────┘
        │ reads/writes versioned artifacts by runId / scopeId
        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  [NEW] Evidence Store  (durable, outside repo/session tmp/)                    │
│  $CHAOS_EVIDENCE_ROOT/<scopeHash>/<runId>/{artifacts,raw,rendered}            │
│  mirrors [MAIN] STARTCHAOS_STATE_PATH artifacts; never replaces them in v0.x  │
└──────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  Deterministic layer                                                          │
│                                                                              │
│  [MAIN]+[NEW] chaos_mcp           │  [MAIN] PowerShell skill scripts          │
│  ─ existing 15 tools stay stable │  ─ Invoke-ChaosImpact.ps1 (+helpers)      │
│    discovery, capability map,     │  ─ Constants.ps1 (pinned API versions)    │
│    eligibility, scoring, exec,    │  ─ Rbac.ps1, Invoke-AzRest.ps1,           │
│    fault-landed proof, build      │    Wait-AzureLro.ps1, State.ps1           │
│    attestation, evidence store    │  ─ templates/metrics/defaults.json        │
│  ─ monitor_* : metrics, logs,     │  ─ tests/e2e/Run-OfflineReplay.ps1        │
│    activity log, appinsights,     │                                           │
│    alert instances, window pack   │                                           │
└──────────────────────────────────────────────────────────────────────────────┘
        │
        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│  Azure  │ Chaos Studio v2 workspaces │ Chaos v1 targetTypes/capabilityTypes   │
│         │ Resource Graph │ Azure Monitor │ App Insights │ Log Analytics       │
│         │ Activity Log │ AlertsManagement │ Deployments history │ ACR/AKS/VMSS│
└──────────────────────────────────────────────────────────────────────────────┘
```

Two rules govern the whole architecture:

1. **The model never computes an outcome.** `[NEW]` deterministic code evaluates proposals; this is a pattern re-expressed from `[PR32 PROTOTYPE]`, not a port.
2. **Compatibility comes first.** `[MAIN]` state at `STARTCHAOS_STATE_PATH` remains readable/writable. `[NEW]` durable evidence mirrors it by `scopeId` / `runId`; targeted skills do not require conversational memory (F12).

### Key Components

#### 1. The eight skills

All eight are proposed **additive user-facing entry points**. They compose the current five skills, scripts and 15 tools; none replaces a shipped skill in the initial release. Shared logic stays in the existing scripts/modules unless it is semantically distinct.

Every SKILL.md carries frontmatter extended with two new keys consumed by the preflight reconciler (FR-14):

```yaml
---
name: chaos-diagnose
description: >-
  Diagnose a Chaos Studio scenario run: prove fault landing, check work
  starvation, evaluate predicates, and emit a CONFIRMED / REFUTED /
  NOT EXERCISED verdict with numeric evidence.
requiredTools:
  - chaos_get_scenario_run
  - chaos_prove_fault_landed
  - monitor_fault_window_pack
  - evidence_put
optionalTools:
  - monitor_list_alert_instances
  - chaos_attest_build_identity
references:
  - references/chaos/evidence-contract.md
  - references/chaos/verdict-matrix.md
---
```

---

**1.1 `chaos-scope-setup`** *(user-facing)*

| | |
|---|---|
| **Triggers** | "set up chaos for &lt;scope&gt;", "which chaos workspace covers this resource group", "create a chaos workspace", "prepare my subscription for chaos testing" |
| **Inputs** | `scope` (subscription ID \| resource group ID \| resource ID list), optional `workspaceId`, optional `location`, optional `identity` (system/user-assigned), `dryRun` (default `true`) |
| **Deterministic work** | `[NEW] chaos_resolve_scope`, `[NEW] chaos_list_workspaces`, `[NEW] chaos_plan_workspace`, shipped `chaos_create_workspace` / `chaos_get_workspace`, and shipped `chaos_refresh_recommendations` when discovery/recommendation freshness is requested; `Rbac.ps1` role-assignment preflight |
| **Model work** | Explaining the plan and the safety trade-offs; nothing computed |
| **Output** | `scope-setup.v1.json` — `{scopeId, scope, workspace:{id,state,identity,createdByThisRun}, discovery:{operationId,status,startedAt,completedAt}, rbac:{callerCanAssignRoles, missingAssignments[], remediation[]}, planOnly, warnings[]}` |
| **Safety** | Reuses an existing workspace by default. Creating a workspace, assigning roles, or enabling targets requires explicit confirmation. `dryRun: true` emits `workspace-plan` only. |
| **Reuses / extends** | Extends `[MAIN] create-workspace`, `start-chaos`, `Invoke-CreateWorkspace.ps1`, `State.ps1`, `Rbac.ps1`, `chaos_create_workspace`, and `chaos_get_workspace`; may become their preferred setup entry only after measured adoption. |
| **RBAC** | `Reader` on scope to discover; **`Chaos Studio Experiment Contributor`** on the resource group (plus `Contributor` if the RG itself must be created) and `User Access Administrator` or `Role Based Access Control Administrator` only when provisioning. See §Least-privilege RBAC — Chaos Studio has exactly four built-in roles and "Chaos Studio Owner"/"Contributor" are not among them |
| **Next step** | "Run `chaos-inventory` for this scope" — plus, if RBAC gaps exist, the exact `az role assignment create` commands from `Build-RoleAssignmentRemediation`. |

**1.2 `chaos-inventory`** *(user-facing)*

| | |
|---|---|
| **Triggers** | "what's in this scope", "inventory my resources for chaos", "what depends on what here", "which repos build this service" |
| **Inputs** | `scopeId` or `scope`, optional `repoHints[]`, optional `includeCode` (default `false`), `topologySources[]` (default `["arg","appinsights","config"]`) |
| **Deterministic work** | ARG resource enumeration (paged); zone/region/SKU/replica extraction; diagnostic-settings and alert-rule enumeration; App Insights & LA workspace resolution; `Microsoft.Resources/deployments` history read; App Insights `dependencies` aggregation for observed edges; tag and naming-convention correlation |
| **Model work** | Naming-convention inference; repository identification from deployment metadata and tags; describing the topology in prose |
| **Output** | `inventory.v1.json` (see §API Contracts) |
| **Notes** | Dependency edges are **observed** (App Insights `dependencies`), **declared** (IaC `dependsOn`, app config), or **inferred** (naming/tags) — each edge carries `edgeSource` and `correlationConfidence`. ARG has no dependency-edge table; the Application Map has no public REST API, so observed edges come from `dependencies` rows whose `Target` is a hostname requiring a second lookup to reach an ARM ID (recorded as `targetResourceId: null` when unresolvable). |
| **Reuses / extends** | Composes `[MAIN] create-workspace` state, `Invoke-AzRest.ps1`, `azure.py`, current workspace tools, and `chaos-impact` diagnostic-settings/monitor collection; adds inventory-only code where no owner exists. |
| **Next step** | `chaos-availability` for the same scope. |

**1.3 `chaos-availability`** *(user-facing)*

| | |
|---|---|
| **Triggers** | "what chaos scenarios can I run here", "why isn't &lt;scenario&gt; available", "what do I need to enable for chaos" |
| **Inputs** | `scopeId`, optional `forceEvaluate` (default `false`), optional `maxAgeMinutes` (default 1440), optional `probeValidation` (default `false`) with `probeScenarios[]` and `probeConsentToken` |
| **Deterministic work — Tier A (non-destructive, default)** | Shipped `chaos_refresh_recommendations` (`POST …/refreshRecommendations` + `evaluations/latest` read, only when stale/forced); shipped `chaos_list_recommended_scenarios` with additive recommendation/freshness metadata; `[NEW] chaos_get_target_capability_map` joining verified v1 target/capability catalog reads; parameter-satisfiability check against `inventory.v1.json` |
| **Deterministic work — Tier B (probe validation, opt-in write)** | `chaos_probe_validate_scenarios` — for each named candidate: create a disposable `ScenarioConfiguration` (`chaos-probe-<scenario>-<shortHash>`), `POST …/configurations/{c}/validate`, poll `…/configurations/{c}/validations/latest`, capture `validationErrors.permission[]`, then delete the configuration. Idempotent, bounded, and never executed. |
| **Model work** | None on eligibility. Narrative only. |
| **Output** | `availability.v1.json` — the **only** legitimate source of scenario names anywhere in the suite |
| **Critical rule** | No downstream skill may name a scenario absent from this service-derived artifact. `[PR32 PROTOTYPE] scenario-catalog.v1.json` is **not ported**; it is not deleted from main because it never existed there. |
| **Reuses / extends** | Extends `[MAIN] setup-scenario`, `Invoke-SetupScenario.ps1`, `chaos_refresh_recommendations`, `chaos_list_recommended_scenarios`, configuration create/validate, and `Validate-AndFix.ps1`. |
| **Gap** | The service exposes `recommendationStatus` but **no `notRecommendedReason`**. `eligibility.gapReason` is therefore synthesised deterministically from observable sources: (a) capability-map misses (`targetType` not enabled on any in-scope resource), (b) parameter requirements unsatisfiable from inventory, and — **only in Tier B** — (c) `validations/latest` permission errors. Anything else is `gapReason: "unknown"` — never guessed. Tracked as **CS-4**. |
| **Next step** | `chaos-analyze`, or the named remediation for each blocked scenario. |

##### Permission-Blocker Acquisition (the `validations/latest` scoping constraint)

It is tempting to treat `validations/latest` as a workspace polling artifact alongside `discoveries/latest` and `evaluations/latest` — the naming symmetry invites it — and to then specify `chaos-availability` as unconditionally read-only while requiring it to emit `validation.permissionErrors[]`. **That combination is not achievable**, and the reason is worth stating precisely because the API's shape actively suggests it.

Verified against `Azure/azure-rest-api-specs` (`Microsoft.Chaos/Chaos/scenarioConfiguration.models.tsp`):

- `WorkspaceDiscovery` is `@parentResource(Workspace)` `@singleton("latest")` → `/workspaces/{ws}/discoveries/latest` — **workspace-scoped, read-only after a `discover` POST.**
- `WorkspaceEvaluation` is `@parentResource(Workspace)` `@singleton("latest")` → `/workspaces/{ws}/evaluations/latest` — **workspace-scoped**, and carries only aggregate template-evaluation counts plus a per-template `RecommendationStatus`. **No permission errors.**
- `Validation` is `@parentResource(ScenarioConfiguration)` `@singleton("latest")` → `/workspaces/{ws}/scenarios/{s}/configurations/{c}/validations/latest`, populated by `POST …/configurations/{c}/validate`. `ValidationProperties.validationErrors` is a `ScenarioErrors` carrying `permission: PermissionError[]` (`requiredPermissions`, `missingPermissions`, `recommendedRoles`) and `resource: ResourceStateError[]`.
- `fixResourcePermissions` is likewise a `ScenarioConfiguration` operation.

**Consequence:** per-resource permission blockers are *unobtainable* without creating a `ScenarioConfiguration`. There is no read-only path. This is a real service constraint, not an implementation choice.

**Resolution — the two-tier design:**

| | Tier A — Eligibility (default) | Tier B — Probe validation (opt-in) |
|---|---|---|
| **Writes?** | **Not strictly read-only when refresh runs.** Shipped `chaos_list_recommended_scenarios` and `[NEW] chaos_get_target_capability_map` are GETs. Shipped `chaos_refresh_recommendations` performs `POST …/refreshRecommendations` and then reads `evaluations/latest`; the proposed contract annotates it `readOnlyHint: false, destructiveHint: false, idempotentHint: true` and does not auto-allow it. No distinct `/evaluate` tool or endpoint is assumed. | Yes — creates and deletes `ScenarioConfiguration` resources. |
| **RBAC** | `Reader` on scope + workspace | Configuration write on the workspace (`Chaos Studio Experiment Contributor` scoped to the workspace) |
| **Answers** | Is the target type enabled? Does the capability exist? Is `recommendationStatus` favourable and fresh? Are required parameters satisfiable? | Which exact resources are missing which exact permissions, and which roles the service recommends. |
| **Cost** | One shipped recommendation refresh (optional) + catalog reads | One create + one validate LRO + one delete **per candidate scenario** |
| **Consent** | Implicit | Explicit, naming every scenario and every configuration name to be created and deleted |
| **Output field** | `permissionBlockers: null`, `permissionBlockersReason: "tier-a-read-only"` | `permissionBlockers: [...]`, `permissionBlockersReason: null` |

**Downstream effects, all now consistent:**

- `DQ-PERMISSION-BLOCKED` fires **only** when Tier B data exists. In Tier A it is not evaluated, and the recommendation carries `permissionCheck: "not-performed"` rather than an implied pass. A recommendation validated only at Tier A is capped at `eligibilityConfidence: 0.6`.
- **D13** (targeted least-privilege remediation from `recommendedRoles`) requires Tier B; without it the skill offers the generic `Reader` + target-enablement guidance from `Rbac.ps1` instead, and says so.
- `chaos-run` always performs a real `validate` on the real configuration before executing (D12), so **execution is never blind to permission errors** even when availability ran at Tier A. Tier B exists to move that discovery *earlier*, not to make it possible.
- Tier B is bounded: it validates only the scenarios the user names, defaults to the top-N candidates from Tier A, and cleans up on both success and failure paths.

**Alternative rejected:** running Tier B automatically for every catalogued scenario. That is O(scenarios) write operations against a customer workspace, before any hypothesis exists, purely to populate an advisory field. See ALT-9.

**1.4 `chaos-analyze`** *(user-facing)*

| | |
|---|---|
| **Triggers** | "where are my single points of failure", "analyse resilience risk for this scope", "what could break here" |
| **Inputs** | `scopeId`, `inventory.v1.json`, optional repository paths / IaC roots, optional SLO document, `analysisDepth` (`resources` \| `iac` \| `code`) |
| **Deterministic work** | IaC parsing and normalisation (see §Code and IaC Analysis); resource-shape rules (single-zone, single-replica, no-retry-configured, single-region dependency, no health probe, probe-not-wired); ARM-ID correlation via deployment history → tags → naming; evidence citation assembly with file/line ranges; hypothesis schema validation; `learningScore = likelihood × blastRadius × falsifiability` (integers 1–5) |
| **Model work** | **This is the model's primary domain.** Reading service code and IaC to identify failure modes a rule cannot see; writing falsifiable hypotheses; naming the expected changed code path; classifying failure mechanisms. |
| **Output** | `hypotheses.v1.json` — ranked, each with `evidence[]`, `correlationConfidence`, `expectedChangedCodePath`, `mechanismClass`, and `requiresMechanismLiveness` |
| **F10/F13 rules** | Any hypothesis whose subject is an observability or health-probe signal **must** carry `mechanismLivenessPredicate` (FR-13) and must declare `consumerCoupling` naming the component that reads the signal. A probe-accuracy item is ranked jointly with its consumer, never independently (F13). |
| **F11 rule** | Each hypothesis declares `mechanismClass` (e.g. `probe-answerable-from-local-state`). The `check_mechanism_class()` library function (D15) rejects a hypothesis whose class already appears in the durable mechanism ledger with a failed outcome unless `newEvidence[]` is supplied. |
| **Reuses / extends** | Consumes `[MAIN] state, impact schema/report, monitor evidence, workspace/scenario payloads`; adds `[NEW]` analysis and ledger contracts. It does not replace a current skill. |
| **Next step** | `chaos-recommend`. |

**1.5 `chaos-recommend`** *(user-facing)*

| | |
|---|---|
| **Triggers** | "which chaos experiment should I run", "rank my chaos options", "map my hypotheses to scenarios" |
| **Inputs** | `hypotheses.v1.json`, `availability.v1.json`, `inventory.v1.json`, optional `riskBudget`, optional `environmentClass` (`dev` \| `test` \| `prod`) |
| **Deterministic work** | The hypothesis × scenario join; disqualification rules; scoring and ranking; blast-radius computation into a concrete `resourceTargeting` include/exclude document; predicate template instantiation; telemetry-contract sufficiency check |
| **Model work** | The recommendation *narrative* — why this experiment answers this hypothesis, in the user's own domain terms |
| **Output** | `recommendations.v1.json` — ranked entries each carrying `scenarioId` (from `availability.v1.json` only), `actionUrn`, `steadyStatePredicate`, `workPredicate`, `confirmRefutePredicate`, `mechanismLivenessPredicate?`, `resourceTargeting`, `guardrails`, `expectedChangedCodePath`, `score`, `scoreBreakdown`, `disqualifications[]` |
| **Reuses / extends** | Composes `[MAIN] setup-scenario` service output and validation payloads plus `[NEW]` pure scoring functions. It does not rename current recommendation tools. |
| **Next step** | `chaos-run` with a selected `recommendationId`. |

Kept **separate from `chaos-analyze`** deliberately — see §Alternatives, ALT-2.

**1.6 `chaos-run`** *(user-facing)*

| | |
|---|---|
| **Triggers** | "run this scenario", "execute the recommended experiment", "cancel my chaos run" |
| **Inputs** | `recommendationId` or explicit `{scenarioId, parameters, resourceTargeting, duration}`, `approvalToken`, optional `cancel: true`, optional `runId` |
| **Deterministic work** | `chaos_create_scenario_configuration`; `chaos_validate_scenario_configuration` (never `--skip-validation`); `frozenValidation` hash over exactly `scenarioName, configurationName, faultType, parameters, targetResources, blastRadius, duration` and byte-for-byte drift comparison at execute time; `chaos_execute_scenario` with **deterministic run-ID recovery** (F7: `run start --no-wait` returns an empty 2xx, so the tool falls back to a `run list` filtered on `startTime ≥ requestSentAt` and matched on configuration name, retrying with backoff, and fails loudly rather than returning null); pre-flight steady-state capture; build attestation; `chaos_cancel_scenario_run`; recovery guidance from `ResourceStateError` / `OperationError` |
| **Model work** | Presenting the approval prompt and the recovery narrative |
| **Output** | `run-record.v1.json` — `{runId, scenarioId, configurationId, frozenValidation, buildAttestation, steadyStateBaseline, window:{plannedStart,plannedEnd,actualStart,actualEnd}, targeting, approval:{approvedBy, approvedAt, token}, status}` |
| **Approval boundary** | Fault execution is the highest-risk write and always requires explicit confirmation. Workspace/configuration/evaluation writes remain separately disclosed. `dryRun` produces configuration + targeting and stops. |
| **Reuses / extends** | Extends `[MAIN] setup-scenario`, `run-scenario`, `Invoke-SetupScenario.ps1`, `Invoke-RunScenario.ps1`, `Validate-AndFix.ps1`, and the existing create/validate/fix/execute/get/cancel tools. Initial release preserves their names and triggers. |
| **Next step** | `chaos-diagnose --run-id <runId>`. |

**1.7 `chaos-diagnose`** *(user-facing, entry point in its own right)*

| | |
|---|---|
| **Triggers** | "diagnose run &lt;id&gt;", "what happened during my chaos run", "did the fault land", "was the hypothesis confirmed" |
| **Inputs** | `runId` (sufficient on its own — no prior conversation required), optional `mode` (`explore` \| `verify`), optional predicate overrides |
| **Deterministic work** | `chaos_get_scenario_run` → exact window; `monitor_fault_window_pack` (pre/during/post buckets); `chaos_prove_fault_landed` (two-sided, per leg); work-starvation check; predicate evaluation; verdict matrix; evidence persistence after each step |
| **Model work** | Explanation and the exercise-repair brief |
| **Output** | `diagnosis.v1.json` with a per-leg verdict and an overall verdict |
| **Reuses / extends** | Composes `[MAIN] chaos-impact` scripts/schema/templates/replay and all three monitor tools; adds distinct proof/verdict logic and may later become the preferred diagnostic entry after compatibility evidence. |
| **Verify-mode rule (F14, retained verbatim in spirit)** | In `verify` mode the changed-code-path execution must be proven separately. Without that proof the verdict is `NOT EXERCISED` and the skill emits an exercise-repair brief — it may **not** emit `REFUTED`. |
| **Next step** | `chaos-evidence --run-id`, or `chaos-analyze` with the new evidence. |

**1.8 `chaos-evidence`** *(user-facing)*

| | |
|---|---|
| **Triggers** | "export the evidence for run &lt;id&gt;", "give me the chaos report", "what runs do I have" |
| **Inputs** | `runId` or `scopeId`, optional `format` (`json` \| `markdown` \| `both`), optional `redact` (default `true`) |
| **Deterministic work** | `evidence_list` / `evidence_get`; bundle assembly; schema validation; Markdown rendering via the existing `Render.ps1`; optional `chaos-impact` report attachment |
| **Model work** | Executive summary prose only |
| **Output** | `evidence-bundle.v1.json` + `report.md` |
| **Reuses / extends** | Extends `[MAIN] State.ps1`, `Render.ps1`, `New-RunReport.ps1`, impact schema/report and offline fixtures; mirrors rather than replaces existing state/report files. |
| **Next step** | File the finding; optionally emit an Advisor-candidate record (see §Reverse Advisor Flow). |

#### 2. Shared reference documents (not skills)

| File | Contents |
|---|---|
| `references/chaos/evidence-contract.md` | The universal invariants, extended. Carried from the prototype's `shared-contract.md`: absence of failure ≠ exercise; check work-starvation *before* interpreting low counts; `null` + caveat, never a fabricated zero; ISO-8601 UTC `Z`; build/test success ≠ resilience proof; frozen workspace during a run. **New:** control-plane state is not data-plane disruption (F6); a predicate over a signal must be paired with a predicate that the signal's mechanism is live (F10); an empty first read of a fault-landed probe is a false negative and must be re-polled (F15); prove fault landing from ARM entity state, not the Activity Log (F15). |
| `references/chaos/verdict-matrix.md` | The deterministic verdict table (§Run Monitoring). |
| `references/chaos/fault-semantics.md` | Per-fault data-plane semantics. **Every entry separates what was seen from why it might have happened**, because a behaviour oracle seeded with a misattributed mechanism is worse than an empty one. Fields: `controlPlaneMutation`, `observedEffect`, `candidateMechanism`, `mechanismConfidence` (`verified` \| `plausible` \| `unverified`), `dataPlaneProbe`, `starvationRecipe` (`resourceTargeting.exclude`, F8), `coverage`. Seed entry (F6), stated exactly as the evidence supports: `controlPlaneMutation:` Event Hubs namespace status set to `Disabled`; `observedEffect:` `EventHubProducerClient.Send` succeeded 60/60 (58/0 in the prior run) from an already-connected producer throughout the window; `candidateMechanism:` an already-open AMQP producer link is not force-detached by namespace disable, `mechanismConfidence: unverified`; `rejectedMechanisms:` *"`AmqpSender` caches `MaxMessageSize` after first attach"* — **falsified**, `AmqpProducer.CreateLinkAndEnsureProducerStateAsync` refreshes it on every link open (recorded so it is not re-derived). Only `observedEffect` and `dataPlaneProbe` may influence a verdict; `candidateMechanism` is narrative only. |
| `references/chaos/telemetry-contract.md` | The minimum telemetry/SLO contract required before execution (§Open Questions Q5), plus the App Insights schema rules from F4. |
| `references/chaos/blast-radius.md` | `resourceTargeting` semantics: include is AND across dimensions, exclude is OR, exclude wins; `physicalZones` format `{region}-az{N}`; `types` supports trailing wildcard. |

#### 3. MCP tool additions

The initial implementation extends `server.py`, `azure.py`, and `monitor.py` before adding semantically distinct modules. Every new tool preserves the current `{"ok": true, "result": ...}` / `{"ok": false, "errorType": ..., "error": ...}` envelope. Annotation shorthand below is `R/W/D/I` = `readOnlyHint` / performs writes / `destructiveHint` / `idempotentHint`.

| `[NEW]` tool | Parameters | `result` contract | R/W/D/I | Owner; consumers; tests | Name status |
|---|---|---|---|---|---|
| `chaos_resolve_scope` | `scope` (subscription/RG/resource IDs) | `{scopeId, canonicalScope, subscriptionIds, resourceIds, warnings}` | T/F/F/T | `[NEW] scope.py` + `server.py`; scope/inventory; `test_scope.py` | Final |
| `chaos_list_workspaces` | `subscription_id`, optional `resource_group` | `{value[], continuationToken?, source}` with paging/provenance | T/F/F/T | Extend `azure.py` + `server.py`; scope setup; lifecycle tests | Final |
| `chaos_plan_workspace` | `scope`, optional `workspace_id`, `location`, `identity_type` | `{reuseCandidate?, createPlan?, rbacPlan, mutations[]}`; performs no mutation | T/F/F/T | `[NEW] scope.py` + current RBAC helpers; scope setup; `test_scope.py` | Final |
| `chaos_get_target_capability_map` | `subscription_id`, `location`, `resource_ids[]` | `{targetTypes[], capabilityTypes[], resourceMatches[], source}` | T/F/F/T | Extend `azure.py` + `server.py`; inventory/availability; lifecycle fixtures | Final after v1 catalog contract fixture |
| `chaos_probe_validate_scenarios` | workspace identity fields, `scenario_names[]`, `configuration_inputs`, `consent_token` | `{validations[], cleanup:{deleted[],failed[]}, warnings}`; never executes faults | F/T/F/T for same inputs after cleanup | Compose current create/validate APIs in `[NEW] availability.py`; availability; cleanup/consent tests | Final; opt-in only |
| `chaos_attest_build_identity` | `run_id`, `resource_ids[]`, `window`, optional `version_endpoint` | `{rung, identity, confidence, evidence[], caveats[]}` | T/F/F/T | `[NEW] proof.py` + `server.py`; run/diagnose; `test_proof.py` | Final |
| `chaos_prove_fault_landed` | run identity fields, `legs[]`, `fault_semantics_version` | `{legs:[{controlPlane,dataPlane,proven,caveats[]}]}`; no candidate mechanism affects `proven` | T/F/F/T | `[NEW] proof.py` + current Monitor/ARM helpers; diagnose; `test_proof.py` | Final, gated by semantics coverage |
| `evidence_put` | `scope_id`, optional `run_id`, `artifact_type`, `artifact`, optional `expected_revision` | `{path, revision, digest, redactions[]}` | F/T/F/F | `[NEW] evidence.py` + `server.py`; all targeted skills; traversal/redaction/concurrency tests | Final |
| `evidence_get` | `scope_id` or `run_id`, `artifact_type` | `{artifact, revision, digest, path}` or named not-found error | T/F/F/T | `[NEW] evidence.py`; diagnose/evidence; denylist/path tests | Final |
| `evidence_list` | optional `scope_id`, `run_id`, `artifact_type`, paging inputs | `{items[], continuationToken?}` | T/F/F/T | `[NEW] evidence.py`; evidence; paging/path tests | Final |
| `monitor_query_appinsights` | `subscription_id`, `component_resource_id`, `kql`, optional `timespan` | normalized `{tables[], schema:"classic", query}` | T/F/F/T | Extend `monitor.py` + `server.py`; inventory/diagnose; `test_monitor_tools.py` | Final |
| `monitor_list_alert_instances` | `subscription_id`, `start_time`, `end_time`, optional `resource_id` | `{count, alerts[], apiVersionUsed, filter}` | T/F/F/T | Extend `monitor.py` + `server.py`; diagnose/pack; PowerShell-parity fixtures | Final; pin migration spike-gated |
| `monitor_fault_window_pack` | run identity fields, `pre_buffer`, `post_buffer`, optional resource/workspace/component IDs | `{window, pre, during, post, sources, caveats[]}` | T/F/F/T | Extend `monitor.py` + existing collectors; diagnose; pack/replay tests | Final |
| `monitor_check_work_starvation` | `pack`, `work_predicate` | `{exercised, measured, threshold, reason, evidence[]}` | T/F/F/T | `[NEW] verdict.py` wrapper in `server.py`; diagnose; verdict tests | Final |

Earlier draft aliases for discovery, evaluation, and scenario listing are **removed before implementation**. Discovery/recommendation refresh uses shipped `chaos_refresh_recommendations`; scenario listing uses shipped `chaos_list_recommended_scenarios`. The plan assumes no distinct `/evaluate` endpoint. If a future service operation is needed, Epic 1 must first prove its endpoint, API version, request/response shape, and runtime availability, then add a separately named `[NEW]` contract.

Pure scoring, correlation, and verdict functions remain in `[NEW] scoring.py`, `analysis.py`, and `verdict.py`; they are not model-callable tools except for the bounded `monitor_check_work_starvation` contract above.

`chaos_execute_scenario` already has MCP fallback logic, and `Invoke-RunScenario.ps1` already validates then recovers/polls a run. `[NEW]` work hardens those paths; it does not introduce recovery from scratch. Rung-3 behavioral build attestation is windowed and requires a sample floor.

Annotations reflect real HTTP side effects. `outputSchema` remains conditional on the resolved MCP SDK capability. No `chaos_list_tools` is added: if the server is absent, its introspection tool is absent too. Skills declare requirements, compare them with the **host-visible** inventory, and CI checks names against the 15 existing plus any additive registrations.

### Data Flow

**Flow A — full journey (happy path)**

1. `chaos-scope-setup(scope)` → resolves scope, finds or plans a workspace, triggers `discover`, checks RBAC → `scope-setup.v1.json` → `evidence_put`.
2. `chaos-inventory(scopeId)` → ARG enumeration + observability wiring + deployment history + observed dependency edges → `inventory.v1.json`.
3. `chaos-availability(scopeId)` → shipped recommendation refresh (when stale/forced) + shipped recommended-scenario list + capability map (+ optional Tier B probe validation) → `availability.v1.json`.
4. `chaos-analyze(scopeId)` → deterministic resource rules + model-driven IaC/code reading + `correlate_iac_to_resources()` + `check_mechanism_class()` → `hypotheses.v1.json`.
5. `chaos-recommend(...)` → deterministic join, disqualification, scoring, blast-radius computation; model narrative → `recommendations.v1.json`.
6. `chaos-run(recommendationId, approvalToken)` → configure → validate → freeze → attest build → capture steady state → execute → recover run ID → `run-record.v1.json`.
7. `chaos-diagnose(runId)` → window from the run → `monitor_fault_window_pack` → `chaos_prove_fault_landed` per leg → starvation check → predicate evaluation → verdict matrix → `diagnosis.v1.json` (+ ledger append on failure).
8. `chaos-evidence(runId)` → bundle + Markdown.

**Flow B — cold entry after a session ends (the F12 scenario)**

`chaos-diagnose --run-id f7cf6241` with an empty conversation: the skill calls `evidence_get(runId)` for the run record (frozen validation, baseline, predicates, build attestation) and `chaos_get_scenario_run` for the authoritative window, then proceeds.

**If no evidence record exists, the degraded mode is strictly bounded.** A `CONFIRMED` verdict against a `null` `steadyStateBaseline` is incoherent, because `CONFIRMED` is defined as degradation past a threshold *relative to a baseline*. There are exactly two coherent options and this design takes both, explicitly labelled:

| Degraded sub-mode | Precondition | Permitted verdicts |
|---|---|---|
| **Absolute-threshold mode** | The recommendation's `confirmRefutePredicate` carries an **absolute** threshold (e.g. `successRate < 0.95`) rather than a relative one (`successRate < baseline − 2σ`), **and** a historical baseline is recoverable from the `pre` bucket of the same run | `CONFIRMED`, `REFUTED`, `NOT EXERCISED`, with `baselineSource: "pre-bucket"` or `"absolute-threshold"` recorded |
| **No-baseline mode** | Neither an absolute threshold nor a usable `pre` bucket exists | **`NOT EXERCISED` only.** The diagnosis states `verdictReason: "no-baseline-and-no-absolute-threshold"` and routes to a re-run with predicates captured up front. |

Predicates are therefore required to declare `thresholdKind: "absolute" | "relative"` at recommendation time, so the cold path can tell which sub-mode applies without guessing. Fault-landed attestation and window computation work identically in both sub-modes — they do not depend on a baseline.

**Flow C — targeted entry**

`chaos-availability` alone answers "what can I run here"; `chaos-analyze` alone answers "where are my SPOFs"; `chaos-evidence` alone lists prior runs. None require the others.

### API Contracts

All artifacts share an envelope:

```jsonc
{
  "schemaVersion": "1",
  "artifactType": "inventory",
  "generatedAt": "2025-01-01T00:00:00Z",
  "scopeId": "scope:sub-0a1b2c3d:rg-payments:v1",
  "scopeFingerprint": "sha256:9f2c…",
  "runId": null,
  "source": { "tool": "chaos_resolve_scope", "apiVersion": "<from chaos_mcp.apiversions>" },
  "freshness": { "collectedAt": "…Z", "maxAgeMinutes": 1440, "stale": false },
  "warnings": [],
  "result": { }
}
```

**`scopeId` versus `scopeFingerprint` — identity and change detection.** A single undifferentiated scope hash is ambiguous in exactly the way that matters: if the hash covers the *resolved resource set*, adding one resource orphans every cached artifact; if it covers only the *scope string*, cached artifacts silently misrepresent a changed scope. This design splits the two concerns:

- **`scopeId`** is derived **only** from the user-supplied scope declaration (subscription ID + resource-group name, or a canonicalised sorted resource-ID list, plus a schema-version suffix). It is stable across resource churn and is the **storage key** for the evidence store. It is human-legible on purpose.
- **`scopeFingerprint`** is `sha256` over the *resolved* resource set (sorted ARM IDs + type + location + a small set of chaos-relevant properties). It is **never** a storage key; it is a **change detector**. When a consumer loads an artifact whose `scopeFingerprint` differs from a freshly computed one, it does not discard the artifact — it emits `scopeDrift: {added[], removed[], changed[]}` as a warning and marks affected findings stale, so the user sees *what* changed rather than losing their history.

Consequences: adding a resource never orphans cached artifacts (fixing the first failure mode); and no artifact can silently describe a scope it no longer matches (fixing the second). `chaos-analyze` and `chaos-recommend` refuse to rank a hypothesis whose cited resource appears in `scopeDrift.removed`.

**API version in `source`.** `source.apiVersion` is populated at runtime from the single constants module (NFR-9 / E1-T7), never hard-coded in a schema, example or fixture. Fixtures record whatever version the constants module held when they were captured, and the fixture-refresh task is a one-line constant change plus a re-record.

**`inventory.v1.json` → `result`**

```jsonc
{
  "resources": [{
    "id": "/subscriptions/…/providers/Microsoft.Compute/virtualMachineScaleSets/vmss1",
    "type": "Microsoft.Compute/virtualMachineScaleSets",
    "location": "eastus",
    "zones": ["1"],
    "physicalZones": ["eastus-az1"],
    "sku": { "name": "Standard_D2s_v3", "capacity": 3 },
    "tags": {},
    "chaosTargets": ["Microsoft-VirtualMachineScaleSet"],
    "singlePoints": ["single-zone"]
  }],
  "observability": {
    "appInsights": [{ "id": "…", "connectedResources": ["…"], "schema": "classic" }],
    "logAnalytics": [{ "id": "…" }],
    "diagnosticSettings": [{ "resourceId": "…", "destinations": ["…"] }],
    "alertRules": [{ "id": "…", "targetResourceIds": ["…"], "severity": 2 }]
  },
  "deployments": [{ "name": "main-20250101", "timestamp": "…Z", "resourceIds": ["…"], "templateHash": "…" }],
  "dependencies": [{
    "fromResourceId": "…", "toResourceId": null, "toTargetHost": "sb-prod.servicebus.windows.net",
    "edgeSource": "observed-appinsights", "correlationConfidence": "medium",
    "callCount7d": 41233, "caveat": "Target is a hostname; no ARM ID resolution available."
  }],
  "repositories": [{ "url": "…", "evidence": "deployment tag azd-service-name", "confidence": "medium" }],
  "slo": null
}
```

**`availability.v1.json` → `result`**

```jsonc
{
  "workspaceId": "…",
  "evaluation": { "operationId": "…", "runAt": "…Z", "status": "Succeeded" },
  "scenarios": [{
    "id": "/…/workspaces/ws1/scenarios/vmss-zone-down",
    "name": "vmss-zone-down",
    "version": "1.0.0",
    "recommendationStatus": "Recommended",
    "evaluationRunAt": "…Z",
    "parameters": [{ "name": "duration", "type": "string", "required": true, "default": "PT10M" }],
    "actions": [{ "name": "shutdown", "actionId": "urn:csci:microsoft:compute:shutdown/1.0.0",
                  "duration": "%%{parameters.duration}%%", "runAfter": [] }],
    "eligibility": {
      "eligible": true,
      "matchedResources": ["/…/vmss1"],
      "prerequisites": [],
      "blockers": [],
      "gapReason": null
    }
  }],
  "capabilityMap": [{ "resourceId": "…", "targetType": "Microsoft-VirtualMachineScaleSet",
                      "targetEnabled": true, "capabilities": ["Shutdown-2.0"], "missingCapabilities": [] }],
  "tier": "A",
  "permissionBlockers": null,
  "permissionBlockersReason": "tier-a-read-only: validations/latest is scoped to a ScenarioConfiguration and requires probeValidation consent"
}
```

Under Tier B the last three fields become:

```jsonc
  "tier": "B",
  "permissionBlockers": [{
    "scenarioId": "/…/scenarios/vmss-zone-down",
    "probeConfigurationName": "chaos-probe-vmss-zone-down-9f2c",
    "probeConfigurationDeleted": true,
    "validationStatus": "RequiresAttention",
    "errors": [{ "resourceId": "…", "requiredPermissions": ["…"],
                 "missingPermissions": ["…"], "recommendedRoles": ["Chaos Studio Experiment Contributor"] }]
  }],
  "permissionBlockersReason": null
```

**`mechanism-ledger.v1.json` → `result`** *(FR-17; the store for F11)*

```jsonc
{
  "scopeId": "scope:sub-0a1b2c3d:rg-payments:v1",
  "entries": [{
    "mechanismClass": "probe-answerable-from-local-state",
    "description": "A health probe whose result is computable without touching the dependency it claims to check.",
    "firstObservedAt": "…Z",
    "occurrences": [
      { "hypothesisId": "H7", "runId": "a1…", "implementation": "IsClosed flag check",       "outcome": "failed", "diagnosisRunId": "a1…" },
      { "hypothesisId": "H9", "runId": "b2…", "implementation": "$management round-trip",     "outcome": "failed", "diagnosisRunId": "b2…" },
      { "hypothesisId": "H12","runId": "c3…", "implementation": "cached batch creation",      "outcome": "failed", "diagnosisRunId": "c3…" }
    ],
    "status": "failed",
    "requiresNewEvidenceToRetry": true,
    "newEvidenceAccepted": []
  }]
}
```

The ledger is appended **only** by `chaos-diagnose` (which alone has a computed verdict) and read by `chaos-analyze` via `check_mechanism_class()`. Three distinct implementations of one class are one ledger entry with three `occurrences`, which is precisely the distinction the prototype's `attemptedFixes` list could not make. It is stored through `evidence_put` under the `scopeId` key, not the `runId` key, because it must outlive any single run.

**`hypotheses.v1.json` → `result.hypotheses[]`**

```jsonc
{
  "id": "H1",
  "statement": "If AZ1 is lost, the order API loses all healthy replicas because the VMSS is single-zone.",
  "failureMode": "zonal-loss",
  "mechanismClass": "single-zone-compute",
  "targetResourceIds": ["/…/vmss1"],
  "evidence": [{
    "kind": "iac", "uri": "infra/main.bicep", "lines": [42, 47],
    "excerpt": "zones: ['1']", "correlationConfidence": "high",
    "correlationMethod": "deployments-history"
  }],
  "expectedChangedCodePath": "src/Api/Startup.cs:ConfigureHealth",
  "requiresMechanismLiveness": false,
  "mechanismLivenessPredicate": null,
  "consumerCoupling": null,
  "likelihood": 4, "blastRadius": 5, "falsifiability": 5, "learningScore": 100
}
```

An observability/probe hypothesis instead carries:

```jsonc
{
  "id": "H7",
  "mechanismClass": "probe-answerable-from-local-state",
  "requiresMechanismLiveness": true,
  "mechanismLivenessPredicate": {
    "description": "Readiness probe emits one dependency span per invocation.",
    "query": "dependencies | where name == 'health.ready.eventhub' | summarize c=count()",
    "expect": { "op": ">=", "value": 1, "per": "probeInterval" },
    "rationale": "Zero dependency spans from an active probe means it is not on the data plane (F10)."
  },
  "consumerCoupling": { "consumer": "VMSS automatic repair policy", "shipTogether": true }
}
```

**`recommendations.v1.json` → `result.recommendations[]`**

```jsonc
{
  "id": "R1",
  "hypothesisId": "H1",
  "scenarioId": "/…/scenarios/vmss-zone-down",
  "actionUrn": "urn:csci:microsoft:compute:shutdown/1.0.0",
  "provingFault": "Shut down all VMSS instances in eastus-az1 for 10 minutes.",
  "steadyStatePredicate": { "signal": "requests/successRate", "op": ">=", "value": 0.995, "window": "PT30M", "thresholdKind": "absolute" },
  "workPredicate":        { "signal": "requests/count",       "op": ">=", "value": 500,   "window": "PT10M", "thresholdKind": "absolute" },
  "confirmRefutePredicate": {
    "thresholdKind": "absolute",
    "confirmIf": { "signal": "requests/successRate", "op": "<", "value": 0.95 },
    "refuteIf":  { "signal": "requests/successRate", "op": ">=", "value": 0.995 }
  },
  "mechanismLivenessPredicate": null,
  "resourceTargeting": {
    "include": { "types": ["Microsoft.Compute/virtualMachineScaleSets"], "physicalZones": ["eastus-az1"] },
    "exclude": { "tags": { "chaos-exempt": "true" } }
  },
  "guardrails": { "maxDuration": "PT10M", "environmentClass": "test", "abortIf": [{ "signal": "requests/successRate", "op": "<", "value": 0.5 }] },
  "expectedChangedCodePath": "src/Api/Startup.cs:ConfigureHealth",
  "telemetryContract": { "sufficient": true, "missing": [] },
  "permissionCheck": "not-performed",
  "dataPlaneProbe": { "faultSemanticsEntry": "urn:csci:microsoft:compute:shutdown/1.0.0",
                      "coverage": "documented", "probe": "requests/count against az1 instances" },
  "score": 0.82,
  "scoreBreakdown": { "learning": 0.34, "eligibility": 0.20, "evidence": 0.18, "safety": 0.10, "telemetry": 0.00, "coupling": 0.00 },
  "disqualifications": []
}
```

`thresholdKind` is mandatory on every predicate: it is what lets the cold-entry path (Flow B) decide between absolute-threshold mode and no-baseline mode without guessing. `permissionCheck` is `"not-performed"` under Tier A and `"passed"` / `"blocked"` under Tier B. `dataPlaneProbe.coverage` is `documented` \| `heuristic` \| `none`, propagated from `fault-semantics.md`; `none` triggers `DQ-NO-DATAPLANE-PROBE` (§Disqualification).

**`diagnosis.v1.json` → `result`**

```jsonc
{
  "runId": "f7cf6241",
  "window": { "start": "…Z", "end": "…Z", "source": "chaos_get_scenario_run" },
  "buildAttestation": { "rung": 3, "confidence": "medium", "identity": "build-inferred-A3",
                        "window": { "pre": ["…Z","…Z"], "during": ["…Z","…Z"] },
                        "samples": { "pre": 412, "during": 388 },
                        "evidence": ["ServiceBusReceiver.Peek spans present in pre-bucket (412), absent in during-bucket (0)"],
                        "caveats": ["No /version endpoint; ACR tags are timestamps; VMSS customData null."] },
  "legs": [{
    "actionUrn": "urn:csci:microsoft:eventhub:disable/1.0.0",
    "actionName": null,
    "actionNameSource": "unavailable-service-returned-null",
    "inferredLegIdentity": { "method": "resource-type-poll", "confidence": "medium" },
    "controlPlane": { "proven": true, "evidence": { "entityStatus": "Disabled", "readAt": "…Z", "repolled": true, "reads": 2 } },
    "dataPlane":    { "proven": false, "probe": "dependency EventHubProducerClient.Send failure rate",
                      "probeCoverage": "documented",
                      "evidence": { "pre": { "success": 58, "failure": 0 },
                                    "during": { "success": 60, "failure": 0, "failureRate": 0.0 },
                                    "deltaVsPre": 0.0 },
                      "caveat": "Observed: sends continued to succeed while the namespace reported Disabled. Candidate mechanism (an already-open AMQP producer link is not force-detached by namespace disable) is UNVERIFIED — see fault-semantics.md and CS-5. Verdict rests on the observation, not the mechanism." },
    "verdict": "NOT EXERCISED"
  }],
  "workStarvation": { "workObserved": 612, "threshold": 500, "starved": false },
  "predicates": [{ "id": "steadyState", "evaluated": true, "value": 0.998, "pass": true }],
  "verdict": "NOT EXERCISED",
  "verdictReason": "Data-plane disruption not proven for any targeted leg.",
  "baselineSource": "pre-bucket",
  "degradedMode": null,
  "ledgerAppend": { "mechanismClass": "control-plane-only-disruption", "occurrenceRecorded": true },
  "nextAction": "exercise-repair-brief"
}
```

### Design Decisions

| # | Decision | Rationale |
|---|---|---|
| **D1** | Eight additive peer entry skills, no internal skill handoffs | P1/F14. They compose the shipped five; no current skill is replaced in the initial release. |
| **D2** | Do not port `[PR32 PROTOTYPE] scenario-catalog.v1.json`; scenario names come only from service-derived availability | P2/G2. The prototype file never existed on main, so this is not a deletion. |
| **D3** | Fault-landed proof is two-sided and per leg | F6. Control-plane state is intent; data-plane disruption is effect. Verdicts built on intent are unsound. |
| **D4** | Build identity uses a rung ladder, and records the rung | F1. A gate that cannot be satisfied is either a blocker or theatre. Recording the rung preserves rigour without blocking. |
| **D5** | One `monitor_fault_window_pack` tool, not N raw queries | F2/F4. The bundle is the unit of evidence; assembling it by hand four times is both toil and a correctness risk. |
| **D6** | Skills declare `requiredTools`, reconciled at preflight | F5. A skill naming absent tools is a silent trap. |
| **D7** | Evidence store outside `tmp/`, mirrored per phase | F12. Durability is a functional requirement of the journey, not a convenience. |
| **D8** | `mechanismClass` ledger, not `attemptedFixes` list | F11. Three implementations of the same error class are one failure, not three. |
| **D9** | Mechanism-liveness predicate mandatory for probe/observability changes | F10. A formally valid predicate over a dead mechanism proves nothing. |
| **D10** | Advisor is optional context and a downstream destination, not a grounding gate | F9. Advisor reasons about configuration shape; chaos findings are about behaviour under fault. Requiring Advisor grounding makes the exception clause the default path. |
| **D11** | Probe-accuracy items are scored jointly with their consumer | F13. A2-without-A3 was worse than no signal. |
| **D12** | Preserve the strict pre-execute validation gate | `[MAIN] run-scenario` already validates/fixes/revalidates before invoking CLI start with `--skip-validation`; `[NEW] chaos-run` must preserve that gate and may remove the CLI flag only if behavior/tests prove it is redundant. |
| **D13** | Least-privilege via `validations/latest` remediation rather than `chaos_fix_resource_permissions` by default | `fixResourcePermissions` grants broadly; the validation payload names `missingPermissions` and `recommendedRoles` per resource, enabling a targeted grant. **This decision only applies where validation data exists** — i.e. inside `chaos-run` (always), or in `chaos-availability` under Tier B (opt-in). Under Tier A no per-resource remediation is offered; the skill states that permissions are unchecked. `fixResourcePermissions` remains available behind explicit consent. |
| **D14** | The model proposes, code evaluates | Carried from the prototype's `evaluate`/`apply` split — the single most valuable pattern on that branch. |
| **D15** | Pure decision functions stay **library functions**, not MCP tools | Correlation, mechanism-class lookup, scoring and blast-radius are pure. Purity — not MCP exposure — is what makes them testable. Exposing them would let the model invoke the scorer with fabricated inputs and present the output as a deterministic result, which is strictly worse than not exposing them. They are called only from within `chaos_*` tools that own the real inputs. |
| **D16** | `scopeId` (declaration-derived, stable) is separate from `scopeFingerprint` (resolution-derived, change detector) | A single hash either orphans cached artifacts on any resource churn or silently misrepresents a changed scope. Splitting them gives stable storage keys *and* honest drift reporting. |
| **D17** | Predicates declare `thresholdKind` | Without it the cold-entry path cannot tell whether a verdict is computable from absolute thresholds or requires a baseline it does not have; a `CONFIRMED` verdict against a null baseline is incoherent, because `CONFIRMED` is defined relative to that baseline. |
| **D18** | `approvalToken` is issued outside model control | An approval the model can mint is not an approval. See §Execution Guardrails. |

**Compatibility decision spanning D1–D18:** v0.x retains the current five skill names/triggers, all 15 MCP names/signatures/envelopes, current state-file compatibility, `impactReportSchemaVersion: 1`, and offline replay. New names are additive; an alias exists for at least one minor release before any removal.

---

## Detailed Design

The sections below are the detailed half of the Proposed Design: the analysis, scoring, guardrail, monitoring, evidence, testing and migration contracts that the eight skills and the MCP tool set depend on. They are grouped here so the top-level document skeleton stays legible.

### Code and IaC Analysis

#### Parsing strategy

| Stack | Approach | ARM-ID recoverability |
|---|---|---|
| **ARM JSON** | Parse directly: `resources[].type`, `dependsOn`, `copy`, nested deployments | Types and dependency edges are reliable; **names are not** when built from `uniqueString()`/`concat()` |
| **Bicep** | `bicep build` → ARM JSON, then as above; module graph from `module` declarations | Same limitation; `uniqueString()` is not invertible |
| **Terraform** | Prefer `terraform show -json` (state) — contains **real ARM IDs**; fall back to `terraform show -json <plan>`; last resort, HCL parse | State gives high-confidence IDs; plan/HCL gives medium/low |
| **Kubernetes / Helm / Kustomize** | `helm template` / `kustomize build` to static YAML; extract Deployments, replica counts, PDBs, topology-spread constraints, probes, HPA, Services, and `image` references (digest pinning is a build-identity rung-2 input) | Cluster-internal; correlate to the AKS resource ID via kubeconfig context / cluster name |
| **App code (.NET, Java, Node, Python, Go)** | Model-driven read of client construction, retry/timeout/circuit-breaker configuration, connection-string/endpoint configuration keys, health-probe handlers, and telemetry emission | Endpoints in config → hostname → medium-confidence ARM ID resolution |

#### Correlating to ARM resource IDs without overclaiming

The `correlate_iac_to_resources()` library function (D15 — a pure function in `chaos_mcp/analysis.py`, not a model-callable MCP tool) applies a strict ladder and records both the method and a confidence:

1. **`Microsoft.Resources/deployments` history** (`high`) — the deployment record links a template/`templateHash` to the resource IDs it actually produced. Most authoritative available signal.
2. **Tags** (`high` when a convention tag such as `azd-env-name` / `azd-service-name` / a repo tag is present and unique; `medium` otherwise).
3. **Naming convention** (`low`) — regex-derived, always `low`, and always accompanied by a caveat.
4. **Unresolvable** → `targetResourceId: null` with `caveat`. **Never** a guessed ID (NFR-3).

Rules that prevent overclaim:

- An evidence item without an ARM ID may still support a hypothesis, but caps that hypothesis's `correlationConfidence` at `low` and disqualifies it from automatic top-3 ranking.
- App Insights `dependencies.Target` is a **hostname**, not an ARM ID (F4-adjacent). A hostname → ARM ID resolution attempt is recorded as its own evidence item with its own confidence; failure is `null`, not omission.
- IaC that is not demonstrably deployed to the scope under analysis is labelled `deployedState: unknown` and cannot alone justify a `high`-confidence hypothesis.

---

### Recommendation Scoring and Disqualification

#### Disqualification (applied first, deterministically)

A hypothesis × scenario pair is **disqualified** — never ranked, always explained — if any of the following holds:

| Code | Rule |
|---|---|
| `DQ-NOT-IN-CATALOG` | The scenario does not appear in `availability.v1.json` for this scope. |
| `DQ-NOT-RECOMMENDED` | `recommendationStatus` ∈ `{NotApplicable, EvaluationFailed, EvaluationCancelled}`. |
| `DQ-STALE-EVALUATION` | `evaluationRunAt` older than `maxAgeMinutes`; remediation is "re-run `chaos-availability --forceEvaluate`". |
| `DQ-CAPABILITY-MISSING` | The action URN's target type/capability is not enabled on any in-scope resource. |
| `DQ-PERMISSION-BLOCKED` | Validation reports `missingPermissions` for a targeted resource. **Only reachable when validation data exists** — Tier B availability or inside `chaos-run`. Under Tier A this rule never fires and `permissionCheck` is `"not-performed"` (see §Permission-Blocker Acquisition). |
| `DQ-NO-TELEMETRY` | The confirm/refute predicate's signal has no source in `inventory.observability` — the experiment cannot produce evidence. |
| `DQ-NO-WORK` | Historical work volume in the proposed window is below the work predicate threshold; the run would be starved by construction. |
| `DQ-MECHANISM-CLASS-REPEAT` | The hypothesis's `mechanismClass` is in the failed ledger without `newEvidence[]` (F11). |
| `DQ-LIVENESS-MISSING` | `requiresMechanismLiveness` is true but no `mechanismLivenessPredicate` is present (F10). |
| `DQ-NO-DATAPLANE-PROBE` | The scenario's fault type has **no** `fault-semantics.md` entry and no heuristic probe, so a data-plane attestation is impossible by construction and the run could only ever return `NOT EXERCISED`. **Warn-only until the coverage bar in Epic 7a is met** (see the launch-usability analysis there); disqualifying from day one would eliminate most of the catalog. |
| `DQ-BLAST-RADIUS` | The computed `resourceTargeting` exceeds the guardrail (e.g. matches production resources when `environmentClass != prod`, or matches more than the configured fraction of replicas). |
| `DQ-UNSAFE-DURATION` | Requested duration exceeds the guardrail or the 12-hour platform ceiling. |

#### Scoring (only for qualified pairs)

```
score = 0.35 · learningNorm
      + 0.20 · eligibilityConfidence
      + 0.20 · evidenceConfidence
      + 0.15 · safetyHeadroom
      + 0.10 · telemetrySufficiency
      +        couplingAdjustment
```

- `learningNorm` = `(likelihood × blastRadius × falsifiability) / 125`, each factor an integer 1–5 (carried from the prototype).
- `eligibilityConfidence` — 1.0 for `Recommended` with a fresh evaluation and a full capability match; 0.6 for `NotEvaluated` with a capability match; 0.0 otherwise (already disqualified).
- `evidenceConfidence` — mean of evidence-item confidences (`high`=1.0, `medium`=0.6, `low`=0.3), penalised 0.2 if any item lacks an ARM ID.
- `safetyHeadroom` — 1.0 when the blast radius is a strict subset of a redundancy group (e.g. one of three zones), decreasing toward 0 as it approaches total.
- `telemetrySufficiency` — fraction of the predicate signals with a confirmed source, including a live alert rule for alert-based predicates.
- `couplingAdjustment` (**F13**) — if `consumerCoupling.shipTogether` is true and the consumer is not part of the same recommendation, apply **−0.25 and emit a `COUPLING-SPLIT` warning**; if the pair is bundled, apply **+0.10**. This directly prevents the A2-without-A3 ordering that produced a confidently green dashboard during a total outage.

Ties break on: higher `evidenceConfidence`, then smaller blast radius, then shorter duration.

Every score is emitted with its `scoreBreakdown` so a user can see exactly why an item ranked where it did. `score_recommendations()` is a **pure library function** over the three input artifacts (`chaos_mcp/scoring.py`), not an MCP tool — see D15. It is called from the `chaos-recommend` entry script, which owns the real artifact inputs; making it a tool would let the model invoke the scorer with fabricated inputs and present the result as deterministic. Reproducibility and unit-testability come from purity, not from MCP exposure.

---

### Execution Guardrails, Approval and RBAC

#### Approval boundary

`chaos-run` is the only targeted entry that executes a fault. Other setup/availability entries may perform disclosed ARM writes, but fault execution requires the stronger approval turn carrying:

- the frozen configuration (`scenarioName`, `configurationName`, `faultType`, `parameters`, `targetResources`, `blastRadius`, `duration`);
- the resolved target list with counts (e.g. "3 of 9 VMSS instances, all in `eastus-az1`");
- the abort predicates;
- the environment class and any `prod` acknowledgement.

`frozenValidation` is hashed at validate time and compared **byte-for-byte** at execute time. Any drift aborts with `FROZEN-DRIFT` and the diff. This is retained unchanged from the prototype.

##### `approvalToken` — issuance and verification (FR-18)

Passing an `approvalToken` into `chaos-run` without saying who issues it leaves the whole security question open: **an approval the model can mint is not an approval.** The token is therefore never produced by, visible to, or derivable by the model.

| Property | Design |
|---|---|
| **Issuer** | The `chaos-run` *entry script* (`Request-ChaosApproval.ps1`), invoked by the CLI host as a distinct, non-model step. It renders the frozen configuration to the terminal and reads a typed confirmation from the human on stdin. |
| **Binding** | `token = HMAC-SHA256(k_session, frozenValidationHash ‖ scenarioConfigurationId ‖ resourceTargetingHash ‖ notAfter)`. |
| **Key transport** | `k_session` is generated by the entry script and handed to the MCP server process **out of band of any model-visible channel**. It is *not* stored in the evidence store, because the evidence store is fronted by the model-callable `evidence_get` and anything reachable through that tool is reachable by the model. Preference order: (1) an **OS keyring** entry (`Windows Credential Manager` / `libsecret` / macOS Keychain) named `chaos-approval-<sessionId>`, read once at server start; (2) a file at `$CHAOS_KEY_DIR/session.key` created with user-only ACL, whose directory is on an explicit `evidence_*` **path denylist** and is outside `$CHAOS_EVIDENCE_ROOT`; (3) an environment variable on the server process, which is acceptable only because tool code cannot enumerate the host's environment back to the model. In all three cases the key never appears in a tool argument, a tool result, an artifact, or a log line. |
| **Enforcement** | `evidence_get`/`evidence_put`/`evidence_list` resolve every requested path against `$CHAOS_EVIDENCE_ROOT` after symlink resolution and reject anything outside it, and additionally reject any path under `$CHAOS_KEY_DIR`. `test_evidence_get_cannot_reach_key_material` asserts this for a direct path, a traversal (`../`), a symlink, and an absolute path — and asserts that no `evidence_*` result ever contains the key bytes. If this test fails, the approval boundary is void and CI blocks the build. |
| **Scope** | Bound to one configuration and one resolved target set. Re-targeting, re-parameterising or a changed duration changes `frozenValidationHash` or `resourceTargetingHash` and invalidates the token. |
| **Lifetime** | `notAfter` defaults to **15 minutes** after issuance. Expiry forces re-approval, so a stale approval cannot be replayed against a scope that has drifted. |
| **Single use** | The token's HMAC is recorded in the evidence store on first successful `chaos_execute_scenario`. A second presentation is rejected with `APPROVAL-REPLAY`. |
| **Verification** | Performed inside `chaos_execute_scenario` (server side), not in prompt text. A missing, malformed, expired, replayed or mis-bound token fails closed with no execution attempt. |
| **Audit** | `run-record.v1.json` stores `approval: { hash, issuedAt, notAfter, confirmedBy, frozenValidationHash }` — the hash, never the token. |

The consequence that matters: the model can *ask* for approval and can *present* the configuration, but the only path from "recommended" to "executing" runs through a human keystroke into a process the model does not control.

#### Tool allowlists

| Phase | Allowed tools |
|---|---|
| Setup / inventory / analyse / recommend | Read-only tools only (`readOnlyHint: true`), plus `chaos_create_workspace` and role assignment behind explicit consent in `chaos-scope-setup` |
| Availability — **Tier A** (default, non-destructive) | Shipped `chaos_refresh_recommendations`, shipped `chaos_list_recommended_scenarios`, `[NEW] chaos_get_target_capability_map`. The list/map calls are read-only; refresh performs a disclosed, non-destructive POST (see below). |
| Availability — **Tier B** (opt-in) | Tier A plus `chaos_probe_validate_scenarios`, which internally creates, validates and deletes a disposable `ScenarioConfiguration`. Requires an explicit `--probe-validation` flag **and** a consent turn naming the configurations it will create and delete. Not covered by the `chaos-run` approval token; it has its own, weaker consent because it never executes a fault. |
| Run | `chaos_create_scenario_configuration`, `chaos_validate_scenario_configuration`, `chaos_execute_scenario`, `chaos_cancel_scenario_run`, `evidence_put` |
| Diagnose / evidence | Read-only + `evidence_put` |

**F8 fix:** `chaos_validate_scenario_configuration` is explicitly present in the run-phase allowlist. The engagement found `config validate` unreachable from the agent's write allow-list, which forced `--skip-validation` and forfeited the permission-blocker data. This is the reason `chaos-run` can always obtain authoritative blockers even when availability ran at Tier A.

#### Least-privilege RBAC

Azure Chaos Studio ships exactly four built-in roles — **Chaos Studio Experiment Contributor**, **Chaos Studio Operator**, **Chaos Studio Reader** and **Chaos Studio Target Contributor**. "Chaos Studio Contributor" and "Chaos Studio Owner" do **not** exist; a plan that instructs an operator to grant either fails at the first `az role assignment create`.

| Operation | Minimum role |
|---|---|
| Scope resolution, inventory, analysis | `Reader` on the scope |
| Telemetry reads | `Monitoring Reader` (+ App Insights component reader) |
| Workspace read, scenario/configuration read | **`Chaos Studio Reader`** on the workspace |
| Availability Tier A (optional recommendation refresh + list + capability map) | Verify the caller can invoke shipped `refreshRecommendations`; otherwise use cached scenario/evaluation data with a staleness warning or require `Chaos Studio Experiment Contributor` for refresh |
| Availability **Tier B** (create/validate/delete a probe configuration) | **`Chaos Studio Experiment Contributor`** on the workspace — this is the concrete privilege cost of Tier B and must be stated in the consent turn |
| Workspace create / resource-group-level Chaos resource creation | **`Chaos Studio Experiment Contributor`** on the resource group (plus `Contributor` if the RG itself must be created) |
| Target enablement | **`Chaos Studio Target Contributor`** on the targeted resources |
| Role assignment for the workspace identity | `User Access Administrator` or `Role Based Access Control Administrator`, scoped to the targeted resources only |
| Execute / cancel a run | **`Chaos Studio Operator`** on the workspace; separately, the *workspace identity* holds only the roles named in `validations/latest → recommendedRoles`, scoped per resource |

Role assignments are proposed as concrete `az role assignment create` commands via `Build-RoleAssignmentRemediation` and never applied silently. `chaos_fix_resource_permissions` is retained but demoted: it is offered only after the targeted remediation is declined, and its broader grant is stated explicitly (D13).

#### No-impact and no-exercise handling

Three distinct outcomes, never conflated:

| Situation | Verdict | Next action |
|---|---|---|
| Fault landed on both planes, work present, steady state degraded past the confirm threshold | `CONFIRMED` | Remediation brief |
| Fault landed on both planes, work present, steady state held above the refute threshold | `REFUTED` | Record the resilience proof; consider a larger blast radius |
| Fault landed on control plane only (F6), **or** work starved, **or** changed-code-path execution unproven in verify mode (F14), **or** build attestation failed at all rungs | `NOT EXERCISED` | Exercise-repair brief naming the exact missing proof and the leg-starvation recipe from `fault-semantics.md` |

`NOT EXERCISED` is never downgraded to `REFUTED`. This single rule would have prevented the unsound Event Hubs verdicts (F6) and the manual `REFUTED` on A3 (F14).

---

### Run Monitoring Contracts

#### Window derivation

The authoritative window comes from `chaos_get_scenario_run` (`properties.startTime`, `properties.endTime`), never from wall-clock estimation. Per-leg windows come from `scenarioRunSummary[]` (`startedAt`, `completedAt`).

Buckets are half-open and symmetric by default:

```
pre    = [start - D, start)
during = [start, end)
post   = [end, end + D)      where D = end - start
```

`monitor_fault_window_pack` returns all three buckets in a single call with per-bucket counts, rates, p50/p95/p99, and `null` (never `0`) where a source is missing.

#### Baseline continuity

The `pre` bucket must satisfy a continuity check before it may serve as a baseline:

| Check | Source | Default | Configurable |
|---|---|---|---|
| Same build identity in `pre` and `during` | `chaos_attest_build_identity` at both boundaries | required at rung ≥ 3 | no |
| No deployment event inside the `pre` window | Activity Log, `Microsoft.Resources/deployments/write` and equivalents | required | no |
| Work-volume ratio `workDuring / workPre` | `monitor_fault_window_pack` counts | within **[0.5, 2.0]** | yes — `baselineContinuity.workRatioBounds` |

**Why ±50% and why it is configurable.** The bound exists to reject baselines drawn from a materially different traffic regime — comparing a 10 a.m. `pre` bucket against a 3 a.m. `during` bucket makes a rate comparison meaningless even though both buckets are "successful queries". The specific factor-of-two is a **heuristic, not a derived value**: it is roughly the diurnal swing of a steadily-loaded service over a window of tens of minutes, and it is wide enough not to reject well-behaved runs while narrow enough to catch a shift-change or a batch job. It is *not* defensible as a universal constant — a service with a nightly ETL spike or a bursty consumer will legitimately exceed it — so it is exposed as `baselineContinuity.workRatioBounds` in the run record, defaulted to `[0.5, 2.0]`, recorded in every diagnosis so a reader can see which bound was applied, and overridable per scope after a rejected-baseline warning. A tighter bound is the right choice for a steady request/response API; a looser one for anything batch-shaped.

Rate-based predicates (success *rate*, failure *rate*) are the reason this is a warning rather than a hard failure: a ratio outside bounds inflates variance but does not invalidate a rate comparison the way it invalidates a count comparison. Count-based predicates therefore hard-fail continuity; rate-based predicates degrade to `baselineQuality: "low"` and cap the diagnosis at `confidence: medium`.

Failing continuity, the baseline is marked `usable: false` and the steady-state predicate is evaluated against a stored historical baseline instead — or, absent that, the no-baseline rules of Flow B apply (`NOT EXERCISED` unless the predicate carries `thresholdKind: "absolute"`).

#### Work-starvation check (runs first)

`monitor_check_work_starvation` runs **before** any low-count signal is interpreted. If `workObserved < threshold`, every failure-count-based predicate is reported as `null` with `starved: true`, and the run verdict is `NOT EXERCISED`. This ordering is a hard invariant carried from the prototype's shared contract.

#### Fault-landed proof

Per leg, `chaos_prove_fault_landed` produces:

- **Control plane** — an ARM read of the targeted entity's state (e.g. Event Hubs namespace/entity `status`, VMSS instance `powerState`, NSG rule presence), taken from **ARM entity state, not the Activity Log** (F15), with a **mandatory re-poll** after a bounded delay when the first read is empty — an empty first read is a known false negative, observed on the NSG leg (F15).
- **Data plane** — a per-leg disruption probe defined in `fault-semantics.md`: dependency-span failure rate for the specific `Target` host, connection reset/retry counts, resource-specific throttling or error metrics. The probe must show a **change relative to `pre`**, not merely a nonzero value.

`controlPlane.proven && !dataPlane.proven` → leg verdict `NOT EXERCISED` with the fault-semantics caveat attached (F6).

Leg identity: `scenarioRunSummary[].actionName` is used when non-null. When the service returns null (F7, observed on all three actions of run `f7cf6241`), the tool falls back to `actionUrn` and then to a per-resource-type ARM poll, recording `actionNameSource` and `inferredLegIdentity.confidence`. The fallback never silently mislabels a leg.

#### Alert-instance predicate

`monitor_list_alert_instances` answers "did an alert instance fire inside the window" by matching shipped PowerShell behavior first. `[MAIN] Get-MonitorSignals.ps1` sends **both** `timeRange=custom` and `customTimeRange=<start>/<end>`, and `[MAIN] Constants.ps1` pins AlertsManagement `2023-05-01-preview` with `2018-05-05` fallback. The Python helper uses the same paired parameters and pin/fallback, records `apiVersionUsed`, and has parity fixtures for preview success and fallback. Any future change to parameter pairing or API versions requires verified service evidence and a migration spike; this plan does not assert that the parameters are mutually exclusive.

The tool extends `[MAIN] chaos_mcp/monitor.py`, is wrapped in `server.py`, and is tested in `mcp/tests/test_monitor_tools.py`. AlertsManagement remains a distinct helper/function inside that module, but reuses its current envelope, retry, filtering and time-window conventions.

An alert-based confirm predicate is disqualified at recommendation time (`DQ-NO-TELEMETRY`) unless a matching alert rule exists in `inventory.observability.alertRules`.

#### Durable state

After each phase, the skill calls `evidence_put`. The store root is `$CHAOS_EVIDENCE_ROOT` (default: a per-user application-data directory), explicitly **not** a repository `tmp/` path (F12). Writes are atomic with a revision counter, mirroring the prototype's locked-state semantics. `chaos-diagnose --run-id` and `chaos-evidence --run-id` are the recovery entry points.

---

### Evidence Provenance, Confidence and Freshness

| Rule | Statement |
|---|---|
| **Provenance** | Every evidence item carries `source` (tool + API version), `collectedAt`, and `query` where applicable. An item without provenance is invalid and rejected by schema validation. |
| **Confidence** | `high` \| `medium` \| `low`, defined per evidence kind (see the correlation ladder). Confidence is assigned by code from the collection method, never chosen by the model. |
| **Freshness** | `collectedAt` + `maxAgeMinutes` + computed `stale`. A stale artifact is usable only with an explicit warning and never for a `CONFIRMED` verdict. |
| **Missing data** | Represented as `null` plus a `caveat` string naming why. Omitting the field entirely is a contract violation. |
| **Null vs zero** | A cited `0` means "measured zero from a successful query". Absence, failure, or an unqueryable source is `null`. Conflation is the single most common source of unsound verdicts. |
| **Absence of failure** | Never evidence of resilience on its own — it must be paired with a satisfied work predicate and a proven data-plane disruption. |
| **Control vs data plane** | Control-plane state is evidence about the platform's intent only. It may never satisfy a disruption predicate (F6). |
| **Mechanism liveness** | A predicate over a signal is invalid unless the signal's producing mechanism is separately proven to execute (F10). |
| **Build/test success** | Not evidence of resilience (carried from the prototype). |
| **Timestamps** | ISO-8601 UTC with `Z`. Windows are half-open. |

---

### Testing Strategy

#### Layers

| Layer | Scope | Tooling | Runs in CI |
|---|---|---|---|
| **Schema/contract tests** | Every artifact schema validates its fixtures; every MCP tool's returned envelope matches its declared contract — asserted against `outputSchema` where E1-T5 confirms SDK support, and against a checked-in envelope schema otherwise, so the layer is not blocked on the spike | pytest + `jsonschema`; Pester for PowerShell artifacts | Yes |
| **Deterministic policy tests** | Disqualification rules, scoring, tie-breaks, verdict matrix, window arithmetic, null-vs-zero, freshness, blast-radius computation | pytest, pure functions, no I/O | Yes |
| **Recorded integration tests** | MCP tools against `_TEST_TRANSPORT` MockTransport with recorded ARM/Monitor payloads | pytest + existing hook | Yes |
| **Offline replay E2E** | Full journey over recorded fixtures — split into two harnesses sharing one fixture corpus (see below) | Pester (PowerShell skills) + pytest (Python journey) | Yes |
| **Live smoke** | A single low-blast-radius scenario in a dedicated test subscription | Manual/nightly, gated | No (opt-in) |
| **Recommendation quality eval** | nDCG@3 over a golden set | pytest + a scoring script | Yes (threshold-gated) |

**Note on CI dependencies.** The schema/contract layer needs `jsonschema`, which the current workflow does **not** install (`.github/workflows/test.yml` installs only `pytest pytest-cov httpx` after `pip install -e .`). Adding `jsonschema` to a `test` extra in `copilot-cli-plugin/mcp/pyproject.toml` and installing `.[test]` in CI is a prerequisite for Epic 1, not an afterthought — without it the schema tests would be collected and skipped, which is worse than not having them.

##### The cross-language E2E problem, and why it is two harnesses rather than a bridge

The suite spans two runtimes: the existing skills are PowerShell (with a Pester harness and seven `recorded-*.json` fixtures), and the new deterministic core is Python (`chaos_mcp`, with the `_TEST_TRANSPORT` MockTransport hook). Asserting a single "full journey E2E" is not enough — it must be said how one harness would drive the other. The two candidate designs:

| Option | Mechanism | Assessment |
|---|---|---|
| **Single Pester harness driving Python** | Pester shells out to the `chaos-mcp` console script (declared in `pyproject.toml`) with `_TEST_TRANSPORT` pointed at a fixture directory, parsing stdout artifacts | Superficially attractive — one green/red signal. But it makes every Python assertion failure surface as an opaque non-zero exit inside a PowerShell test, requires marshalling structured failures through stdout, and puts a Python dependency on the PowerShell CI job. Debugging cost is high and grows with the Python surface. |
| **Two harnesses, one fixture corpus** ✅ | `tests/e2e/Run-OfflineReplay.ps1` (Pester) covers the PowerShell skill scripts; `tests/e2e/test_journey_replay.py` (pytest) covers the Python journey end to end via `_TEST_TRANSPORT`. Both read the **same** `fixtures/` tree and both validate their outputs against the **same** artifact JSON schemas. | Chosen. Each failure surfaces in its native runtime with a native stack trace. The shared fixture corpus and shared schemas are what make the two halves compose — the integration risk is "do the artifacts match the contract", and that is exactly what both halves assert. |

The integration seam is therefore the **artifact contract**, not a process boundary: the Pester harness asserts that the PowerShell skills *produce and consume* schema-valid artifacts, and the pytest harness asserts the Python journey does the same over identical inputs. A **golden-artifact test** pins one complete journey's artifact set (byte-comparable after timestamp normalisation) so a change in either runtime that alters the shared shape fails loudly on both sides.

**Acceptance criterion (revised).** *Not* "one E2E harness runs the full journey". Instead: (a) `Run-OfflineReplay.ps1` exercises every PowerShell skill script against the shared corpus and validates outputs against the artifact schemas; (b) `test_journey_replay.py` exercises scope → inventory → availability → analyze → recommend → run → diagnose → evidence against the same corpus with no network access; (c) a golden-artifact set is committed and compared in both harnesses; (d) both are wired into `.github/workflows/test.yml` as separate jobs.

#### Fixtures to add

| Fixture | Purpose |
|---|---|
| `fixtures/arm/scenarios-list.json` | Scenario list with mixed `recommendationStatus` values including `NotApplicable` and `EvaluationFailed` |
| `fixtures/arm/capability-map.json` | v1 `targetTypes` + `capabilityTypes` join, with a deliberate missing capability |
| `fixtures/arm/validations-latest-permission-errors.json` | `RequiresAttention` with `missingPermissions`/`recommendedRoles` — **Tier B / `chaos-run` only** |
| `fixtures/arm/probe-validation-lifecycle.json` | **Tier B fixture** — create → validate → delete sequence, plus a variant where `validate` fails so cleanup must still run |
| `fixtures/arm/run-null-actionname.json` | **F7 regression fixture** — `scenarioRunSummary[].actionName` null on all actions |
| `fixtures/arm/run-start-empty-2xx.json` | **F7 regression fixture** — empty 2xx on start, exercising run-ID recovery |
| `fixtures/appinsights/classic-schema.json` | **F4 regression fixture** — lowercase `dependencies`/`customMetrics` columns, resource-scoped, no subscription in the request |
| `fixtures/appinsights/eventhub-send-60-0.json` | **F6 regression fixture** — 60 successes / 0 failures during a "landed" fault |
| `fixtures/alerts/instances-custom-time-range.json` | **F3 fixture** — alert instances inside and outside an exact window; asserts `timeRange=custom` and `customTimeRange=<start>/<end>` are both sent, with preview success and fallback variants |
| `fixtures/arm/nsg-empty-then-populated.json` | **F15 regression fixture** — empty first read, populated on re-poll |
| `fixtures/build/no-version-endpoint.json` | **F1 fixture** — forces the ladder to rung 3 |
| `fixtures/ledger/mechanism-class-three-implementations.json` | **F11 fixture** — one class, three occurrences, three distinct implementations |
| `fixtures/iac/{bicep,terraform-state,helm}/…` | Correlation-ladder fixtures with high/medium/low/unresolvable cases |

#### Named regression tests (each traceable to field evidence)

| Test | Asserts |
|---|---|
| `test_control_plane_only_yields_not_exercised` | F6 — entity `Disabled` + 60/0 sends → `NOT EXERCISED`, never `REFUTED` |
| `test_run_id_recovered_from_empty_start` | F7 — empty 2xx → run ID recovered by `startTime` filter; failure raises, never returns null |
| `test_null_action_name_falls_back_to_urn` | F7 — `actionNameSource` recorded, leg not mislabelled |
| `test_appinsights_subscription_injection_and_classic_schema` | F4 — the two *verified* causes only: the subscription ID is injected into the resource-scoped query path, and lowercase classic column names are handled. **No assertion about escaping `first`** — that cause was not reproducible and the claim that `first` is a reserved token is unsupported (see §Corrections to the field record). |
| `test_alert_instance_custom_time_range` | F3 — paired `timeRange=custom` + `customTimeRange=<start>/<end>` carry the exact window, `apiVersionUsed` records preview or fallback, and half-open boundary behaviour holds |
| `test_nsg_empty_first_read_repolled` | F15 — one empty read does not produce `proven: false` |
| `test_build_ladder_records_rung` | F1 — rung 3 fingerprint accepted with `confidence: medium`, `minSamples` enforced, caveats present |
| `test_liveness_predicate_required_for_probe_hypothesis` | F10 — `DQ-LIVENESS-MISSING` fires |
| `test_mechanism_class_repeat_blocked` | F11 — three distinct implementations of one class are blocked as one |
| `test_mechanism_ledger_schema_and_append_only` | FR-17 — the ledger validates against `mechanism-ledger.v1.schema.json`; only `chaos-diagnose` may append; occurrences accumulate rather than replacing |
| `test_coupling_split_penalty` | F13 — probe fix without its consumer is penalised and warned |
| `test_required_tools_preflight_fails_named` | F5 — a `requiredTools` entry absent from the host's `tools/list` produces a named failure, not a substitution |
| `test_evidence_survives_tmp_wipe` | F12 — artifacts resolve from `$CHAOS_EVIDENCE_ROOT` with `tmp/` deleted |
| `test_null_vs_zero` | NFR-3 — unqueryable source yields `null` + caveat, not `0` |
| `test_work_starvation_precedes_interpretation` | Invariant ordering |
| `test_tier_a_never_claims_no_blockers` | FR-3 — with no validation data, `permissionBlockers` is `null` with a reason, `DQ-PERMISSION-BLOCKED` does not fire, and `eligibilityConfidence` is capped at 0.6 |
| `test_tier_b_probe_validation_always_cleans_up` | Tier B — the disposable `ScenarioConfiguration` is deleted on the success path **and** on the validate-failure and exception paths; the test asserts the DELETE was issued in a `finally`-equivalent |
| `test_approval_token_binding` | FR-18/D18 — a token minted for configuration A is rejected for configuration B; an expired token is rejected; a replayed token is rejected with `APPROVAL-REPLAY`; execution is not attempted in any rejection case |
| `test_cold_entry_without_baseline_is_not_exercised_only` | D17 — with `steadyStateBaseline: null` and `thresholdKind: "relative"`, only `NOT EXERCISED` is reachable; with `thresholdKind: "absolute"`, `CONFIRMED`/`REFUTED` become reachable and `baselineSource` is recorded |
| `test_scope_drift_marks_stale_not_orphaned` | D16 — a changed `scopeFingerprint` yields `scopeDrift` warnings and stale marks, and the artifact is still loadable under the same `scopeId` |
| `test_baseline_work_ratio_bounds_configurable` | Baseline continuity — the default `[0.5, 2.0]` is applied and recorded; an override is honoured; count-based predicates hard-fail while rate-based degrade to `baselineQuality: "low"` |
| `test_api_versions_centralised` | NFR-9/E1-T7 — a lint test asserts no api-version string literal appears outside `chaos_mcp/apiversions.py` |

#### Recommendation-quality evaluation

No public benchmark for chaos-scenario recommendation exists, so the plan defines its own. A golden set of **30 cases** (scope fixture + hypotheses + availability + a human-graded relevance label per candidate on a 0/1/2 scale) lives in `evals/recommendation/`. Primary metric **nDCG@3**; secondary precision@3 and MRR. CI gates on a regression threshold (nDCG@3 must not drop more than 0.05 below the recorded baseline). Grading rubric and inter-grader process are documented alongside the set; the initial grading is by two reviewers with disagreements resolved in writing.

---

### Migration and Reuse

| Source asset | Initial disposition | Reuse/migration contract |
|---|---|---|
| `[MAIN] skills/start-chaos`, `create-workspace`, `setup-scenario`, `run-scenario`, `chaos-impact` | **EXTEND/REFACTOR, not replace** | Keep names, trigger phrases, entry scripts and exit behavior. Targeted skills call/compose their scripts and tools. |
| `[MAIN] State.ps1` and `STARTCHAOS_STATE_PATH` files | **EXTEND** | Existing JSON remains readable/writable. Durable evidence mirrors/imports it; no forced move. |
| `[MAIN] chaos-impact` schema/templates/scripts/tests/replay | **EXTEND** | Preserve schema v1 and PowerShell replay; consume report as a diagnosis source and add fixtures rather than a parallel collector. |
| `[MAIN] all 15 MCP tools` | **EXTEND** | Names, positional/optional parameters and envelope stay. Add fields or new semantically distinct tools only. |
| `[MAIN] monitor.py` and `test_monitor_tools.py` | **EXTEND** | Own App Insights normalization, alert instances and the pack so transport/retry/envelope logic is not duplicated. |
| `[MAIN] chaos_fix_resource_permissions` | **RETAIN behind explicit consent** | Targeted remediation is preferred. Do not deprecate until usage/service data supports it. |
| `[PR32 PROTOTYPE] state engine and shared contract` | **Pattern reuse only** | Re-express atomic write, proposal/evaluate, invariants and verdict vocabulary in current modules. Do not copy the monolith. |
| `[PR32 PROTOTYPE] run-state/external-gate schemas` | **NOT PORTED** | New focused artifacts and the build ladder supersede their ideas; they never existed on main. |
| `[PR32 PROTOTYPE] scenario catalog` | **NOT PORTED** | Service response is authoritative. No main deletion. |
| `[PR32 PROTOTYPE] chaos-loop/advisory/coding skills` | **NOT PORTED** | Current shipped workflow remains; remediation coding stays out of scope. |

**Version/deprecation strategy.** Ship backward-compatible hardening as additive v0.x minors (first target 0.4.0 only after all three version files are updated together). Retain current skill names/triggers, 15 tool names/signatures/envelopes, state files and impact schema. If a future name is preferred, keep an alias for **at least one minor release** and publish telemetry/rollback criteria before removal. Broad permission fix remains available behind explicit consent until a separately approved deprecation.

**Measurable compatibility gate.** Before each phase merges: (1) `/start-chaos` completes the existing recorded path; (2) each of the five skills remains directly invocable; (3) the registry still lists all 15 tools with unchanged callable signatures and envelopes; (4) current `startchaos-state.json` fixtures resume; (5) `OfflineReplayE2E.Tests.ps1` / `Run-OfflineReplay.ps1` stay green; and (6) Pester ubuntu/windows/macos, pytest Python 3.10–3.13, and ruff all pass.

---

## Chaos Studio Product Issues (separate from this plan)

These are **service/product defects and gaps**, not skill-instruction changes. This plan degrades gracefully around each, but each should be filed with the Chaos Studio service team. The workaround column is what the suite implements in the meantime.

| ID | Issue | Evidence | Workaround in this plan |
|---|---|---|---|
| **CS-1** | `scenarioRunSummary[].actionName` returns `null` | F7, run `f7cf6241`, null on all three actions | Fall back to `actionUrn`, then per-resource-type ARM poll; record `actionNameSource` and confidence |
| **CS-2** | `run start --no-wait` returns an empty 2xx with no run ID | F7, every run required a `run list` filtered on `startTime` | Deterministic run-ID recovery inside `chaos_execute_scenario`, failing loudly rather than returning null |
| **CS-3** | No per-leg data-plane disruption attestation. The service reports intended mutation only | F6, Event Hubs `Disabled` with `EventHubProducerClient.Send` 60/60 successful | Independent data-plane probes per leg from `fault-semantics.md`; `NOT EXERCISED` when only the control plane is proven |
| **CS-4** | `RecommendationStatus` has no `notRecommendedReason` / ineligibility-reason field | Availability design; eligibility gaps are otherwise unexplainable | Synthesise `gapReason` from capability-map misses and unsatisfiable parameters (Tier A), plus validation permission errors where available (Tier B / run); otherwise `"unknown"` |
| **CS-4b** | Permission blockers are only obtainable through a **configuration-scoped** `validations/latest`; there is no workspace- or scenario-scoped "would this be permitted?" read. `WorkspaceEvaluation` returns aggregate counts and per-template `RecommendationStatus` only | TypeSpec: `Validation` is `@parentResource(ScenarioConfiguration)` `@singleton("latest")`; `fixResourcePermissions` is likewise configuration-scoped | A read-only permission-preflight at workspace or scenario scope would remove the need for Tier B entirely. Until then: Tier A reports `permissionBlockers: null` with a reason; Tier B creates and deletes a disposable configuration behind explicit consent |
| **CS-5** | Per-fault data-plane semantics are undocumented, and the observed behaviour contradicts the documented control-plane state | F6: an Event Hubs namespace reported `Disabled` while `EventHubProducerClient.Send` continued to succeed 60/60 from an already-connected producer. **The mechanism is unverified** — the originally-hypothesised cause (`AmqpSender` caching `MaxMessageSize` after first attach) is *falsified*: `CreateLinkAndEnsureProducerStateAsync` refreshes it on every link open, with an explicit source comment that the value "can be changed on-the-fly". The surviving candidate — that namespace disable does not force-detach already-open AMQP links — is plausible but undocumented | Maintain `references/chaos/fault-semantics.md` as a living document with `observedEffect` separated from `candidateMechanism` + `mechanismConfidence`. Only `observedEffect` drives verdicts. Ask the Event Hubs team to document link-detach behaviour on namespace disable; ask the Chaos team to publish per-fault data-plane semantics |
| **CS-6** | `config validate` unreachable from the agent write allow-list | F8 | Explicitly allowlist `chaos_validate_scenario_configuration` in the run phase (D12) |
| **CS-7** | Exclusion-based leg starvation is undiscoverable | F8 | Document `resourceTargeting.exclude` recipes per fault in `fault-semantics.md`; `compute_blast_radius()` emits them |
| **CS-8** | No repo-proved v2 service limits, retention, or cancel semantics; workspace-era Chaos types are not confirmed in ARG's `ChaosResources` | API research | Phase 0 verifies target runtime behavior; use configurable safety caps, do not assume history retention, and avoid ARG dependence for Chaos resources |
| **CS-9** | Application Map has no public REST API | API research | Reconstruct observed edges from `dependencies` rows; accept hostname-only targets with `targetResourceId: null` |
| **CS-10** | The repository pins `2026-05-01-preview`; external spec research confirmed that version exists, correcting an earlier claim that it was invalid. This does **not** prove every preview operation is deployed in a target runtime. | Repo pin + external spec check; runtime unverified | Keep the current pin initially; Phase 0 exercises required operations. A move to `2026-08-01-preview` remains Q6. |

### Reverse Advisor flow (proposal, not a dependency)

F9 shows Advisor is an anti-correlation source for chaos findings: 16 HighAvailability recommendations on the resource group, zero matched, and the nearest one was already satisfied while depending on the very probe proven blind. Advisor reasons about configuration shape; chaos findings are about behaviour under fault.

The useful direction is therefore **reversed**. `chaos-evidence` optionally emits an `advisor-candidate.v1.json` record — a chaos-proven finding (e.g. "readiness probe returned 200 throughout a total dependency outage") in a shape an Advisor recommendation generator could consume. This is proposed as a partner-team conversation, not built here (N2, N8).

---

## Alternatives Considered

**ALT-1 — Keep the monolithic `chaos-loop` skill and add entry points.**
*Pros:* less refactoring; a single place for the invariants. *Cons:* F14 shows the failure mode directly — when the loop was interrupted, work degraded to manual mode and the invariants were lost. Entry points into a monolith still share one state document and one failure domain. **Rejected.**

**ALT-2 — Merge `chaos-analyze` and `chaos-recommend` into one skill.**
*Pros:* one fewer skill; hypotheses and recommendations are tightly related; avoids a redundant artifact hop. *Cons:* the two have different determinism profiles — analysis is model-heavy, recommendation is almost entirely deterministic — and different input freshness requirements (analysis can run without a workspace; recommendation cannot run without `availability.v1.json`). Merging them makes the deterministic scoring untestable in isolation and re-couples hypothesis generation to workspace availability. **Kept separate**, but this is a genuine trade-off and is listed as Open Question Q1.

**ALT-3 — Hard-code a curated scenario catalog for offline/air-gapped use.**
*Pros:* works without a workspace; faster. *Cons:* exactly the failure the prototype demonstrated — fabrication and drift. **Rejected**, except as a *test fixture* (never a runtime source).

**ALT-4 — Use Azure Advisor as the grounding source for findings.**
*Pros:* first-party, already in the portal, familiar to users. *Cons:* F9 — anti-correlated with behaviour-under-fault findings; the "no coverage" exception fires as the default path. **Rejected as a gate**; retained as optional context and as a downstream destination.

**ALT-5 — Derive dependency topology solely from Azure Resource Graph.**
*Pros:* single query surface, fast, no telemetry dependency. *Cons:* ARG has no dependency-edge table; edges must be inferred from resource properties, and its 3-join and 1,000-record-per-page constraints bite (there is no documented per-query time limit; throttling is a per-5-second quota). **Rejected as sole source**; used as one of three sources with `edgeSource` recorded (Open Question Q3).

**ALT-6 — Require a `/version` endpoint as a hard precondition for execution.**
*Pros:* clean, unambiguous build identity. *Cons:* F1 — unobtainable in the observed environment; would have blocked the entire engagement. **Rejected** in favour of the rung ladder with the rung recorded.

**ALT-7 — Keep evidence in the repository working tree (`tmp/`).**
*Pros:* zero configuration; visible to the user. *Cons:* F12 — wiped twice, destroying two runs. **Rejected**; `$CHAOS_EVIDENCE_ROOT` outside the tree, with an optional repo-local export via `chaos-evidence`.

**ALT-8 — Put the pre/during/post assembly in the skill prompt rather than a tool.**
*Pros:* no new tool; flexible. *Cons:* F2/F4 — four hand-assemblies and three schema failures per attempt. Prompt-side assembly is not testable and not reproducible. **Rejected.**

**ALT-9 — Run probe-validation (Tier B) automatically for every candidate scenario, so permission blockers are always available.**
*Pros:* uniform, complete eligibility data; no two-tier complexity; `DQ-PERMISSION-BLOCKED` always usable. *Cons:* the cost is not proportional to the benefit. A read-only-feeling "what could I run here?" question would (a) create and delete one `ScenarioConfiguration` per candidate — tens of ARM writes on a real scope; (b) require `Chaos Studio Experiment Contributor` merely to *look*, which many users exploring the tool will not have and should not need; (c) leave orphaned probe configurations if the process dies mid-loop; (d) make an advertised read-only skill perform writes, which is a genuine trust violation regardless of how benign the writes are. **Rejected as the default.** Tier B is opt-in per invocation with a consent turn that names the configurations and the role requirement, and `chaos-run` — which legitimately creates a configuration anyway — always validates, so nothing is ever *executed* without authoritative blocker data.

**ALT-10 — Add a `monitor_metrics_batch` tool in v1 for multi-resource metric fan-out.**
*Pros:* one call for N resources; the Metrics Batch API (`2023-10-01`) exists and is regional. *Cons:* it introduces a second metrics auth audience (`https://metrics.monitor.azure.com/.default`) and a regional endpoint-construction rule, both of which are new failure modes, for a latency win on a path that is not currently the bottleneck — `monitor_fault_window_pack` already collapses the per-run round trips that actually hurt (F2). **Deferred**, not rejected: revisit when a scope with >20 metric-bearing resources demonstrates the fan-out cost, and land it behind the same pack interface so no caller changes.

---

## Dependencies

**External**

- Chaos Studio v2 workspace APIs proved by pinned main (`workspaces`, `scenarios`, `configurations`, `runs`, `refreshRecommendations`, `evaluations/latest`, and the **configuration-scoped** `validations/latest`) — API-version pin tracked in Q6. Additional discovery/evaluate operations are not assumed and remain spike-gated.
- Chaos Studio v1 GA `2025-01-01` catalog APIs (`/subscriptions/{sub}/providers/Microsoft.Chaos/locations/{loc}/targetTypes` and `/subscriptions/{sub}/providers/Microsoft.Chaos/locations/{loc}/targetTypes/{tt}/capabilityTypes/{ct}`) for capability grounding. The `locations/{loc}` segment is mandatory — there is no location-free form.
- Azure Resource Graph — paging, max 3 joins, 1,000 records per page; throttling is a documented **15 queries per 5-second window** per user. No per-query time limit is documented, so none is designed around.
- Azure Monitor metrics, Log Analytics query API, Application Insights (classic resource-scoped schema). The Metrics Batch API is **not** a v1 dependency (ALT-10).
- `Microsoft.AlertsManagement` alert instances API using shipped `2023-05-01-preview` with `2018-05-05` fallback and the paired query `timeRange=custom&customTimeRange=<start>/<end>`.
- Azure Activity Log (deployment events for baseline continuity only — **not** for fault-landed proof, F15).
- Azure CLI + `chaos` extension; required command/version availability is verified in Phase 0 rather than inferred from repository wrappers.
- `bicep` CLI, `terraform` CLI, `helm`/`kustomize` — all **optional**; absence degrades `analysisDepth` and is reported, not fatal.
- Python `mcp` — source pins `>=1.2.0,<2`; the installed version and host protocol capability are runtime facts verified in Epic 1. Do not infer `outputSchema` support from the range.
- Python `httpx`; **`jsonschema`** (new — required by the schema/contract test layer and *not* currently installed in CI); PowerShell `Az` modules; Pester ≥ 5.5.

**Internal**

- Synchronized additive minor versioning across `plugin.json`, `mcp/pyproject.toml`, and marketplace metadata; no removal release is scheduled.
- The existing `_TEST_TRANSPORT` MockTransport hook (all new MCP tests depend on it).
- The `chaos-impact` schema and offline-replay harness.
- CI workflow paths in `.github/workflows/test.yml`.

**Sequencing**

Evidence store and schemas must land before any skill that persists artifacts. `chaos-availability` must land before `chaos-recommend` (it is the only legitimate scenario source). `monitor_fault_window_pack` and `chaos_prove_fault_landed` must land before `chaos-diagnose`.

---

## Impact Analysis

- **Codebase areas affected:** `copilot-cli-plugin/skills/` (additive targeted entries plus shipped-skill hardening), `copilot-cli-plugin/mcp/chaos_mcp/` (the additive wrappers named in §MCP tool additions plus pure-function modules), `copilot-cli-plugin/references/` and `copilot-cli-plugin/schemas/` (new), existing and new test families, `evals/`, docs, package manifests, and CI.
- **Backward compatibility:** additive. The five existing skills and all **15** existing MCP tools keep working. No initial renames; any future alias survives at least one minor version. `impactReportSchemaVersion: 1` is unchanged.
- **Performance:** `chaos-inventory` is the heaviest step (ARG paging + deployment history + telemetry aggregation); it is cached per `scopeId` with a freshness bound. `monitor_fault_window_pack` replaces N round trips with one, reducing latency and token usage materially. `chaos-availability` calls shipped `chaos_refresh_recommendations` only when forced or cached evaluation data is stale; Tier B adds 2N ARM writes and is therefore opt-in (ALT-9).
- **Operational:** a new on-disk store (`$CHAOS_EVIDENCE_ROOT`) requires a documented location, size expectations, and a retention/cleanup command. Tool-availability reconciliation costs nothing at runtime — it reads the host's existing `tools/list` result — but eliminates an entire class of silent failure (F5).

---

## Security Considerations

- **Auth:** unchanged — the existing `chaos_set_auth_mode` lever (`cli` vs `managed-identity`) governs all new tools.
- **Least privilege:** reads are preferred; workspace/configuration/evaluation writes are disclosed and consented, while fault execution has the strongest approval. Validation-derived targeted roles are preferred over broad permission fix (D13).
- **Attack surface:** the largest new surface is source-repository reading. Repositories are read **locally and read-only**; no credentials are used to clone remote repositories on the user's behalf without explicit paths, and repository selection requires confirmation (Open Question Q2). No repository content is written to any artifact beyond a bounded excerpt with a file path and line range (NFR-8).
- **Secret hygiene:** artifacts are scanned for connection-string, key and token patterns before `evidence_put`; matches are redacted with a marker. `chaos-evidence --redact` (default on) applies a second pass at export.
- **Evidence store:** contains resource IDs, telemetry aggregates and code excerpts. It is created with user-only permissions and documented as sensitive. `chaos-evidence` supports a purge command.
- **Destructive-action gating:** `destructiveHint: true` on `chaos_execute_scenario` and `chaos_cancel_scenario_run` so hosts prompt; execution additionally requires the in-skill approval token.

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Service returns no ineligibility reason (CS-4), so eligibility gaps stay opaque | High | Medium | Synthesise `gapReason` from **two** observable sources at Tier A (capability-map misses, unsatisfiable parameters) and a third at Tier B (configuration-scoped validation errors); report `"unknown"` rather than guessing; file CS-4 and CS-4b |
| Data-plane probes are wrong or missing for a fault type | **High at launch**, falling to Medium as coverage lands | High | This is **Epic 7a**, not a fallback. The safe-by-default behaviour (unknown fault type → `dataPlane.proven: false` → `NOT EXERCISED`) prevents *unsound* verdicts but does not prevent *useless* ones: at launch it would fire for nearly every fault type. Mitigation is therefore the coverage programme — documentation-sourced heuristic entries for every fault type reachable by a top-20 scenario, empirical probe runs upgrading the top 10 to `verified`, `dataPlaneProbe.coverage` surfaced at recommendation time so a user learns *before* executing, and warn-only `DQ-NO-DATAPLANE-PROBE` becoming disqualifying once the bar is met. `fault-semantics.md` remains authoritative and versioned, with `observedEffect` separated from `candidateMechanism`. |
| Build attestation stuck at rung 3 gives weak identity | High | Medium | Rung is recorded and surfaced; rung-3-only runs cannot yield `CONFIRMED` on a code-change verification (verify mode) |
| API-version drift (`2026-05-01-preview` vs `2026-08-01-preview`) | Medium | Medium | Single pin file per language (NFR-9); contract tests over recorded fixtures fail loudly on shape change |
| IaC → ARM-ID correlation overclaims | Medium | High | Strict ladder with recorded method + confidence; `low` confidence caps ranking; `null` never guessed |
| Evidence store grows unbounded | Medium | Low | Retention policy + `chaos-evidence purge`; raw telemetry stored as aggregates, not row dumps |
| Eight skills confuse users versus one entry point | Medium | Medium | Each skill ends with explicit next-step guidance; `chaos-scope-setup` doubles as the natural front door; docs include the full journey walkthrough |
| Recommendation eval set is small (30 cases) and self-graded | High | Medium | Publish the rubric, use two graders with written disagreement resolution, gate on regression rather than absolute quality, grow the set from real engagements |
| Model still fabricates a scenario name in narrative prose | Medium | High | `chaos-recommend` validates every emitted `scenarioId` against `availability.v1.json` and fails the artifact on a mismatch — a schema-level check, not a prompt instruction |
| ARG constraints break inventory at large scope | Medium | Medium | Paging + type-partitioned queries; explicit `truncated: true` with a narrower-scope instruction |

---

## Open Questions

| # | Question | Why it matters | Current lean |
|---|---|---|---|
| **Q1** | Should recommendation be a distinct skill from analysis? | Determines skill count and where the deterministic boundary falls | **Keep separate** (ALT-2): different determinism profiles, different prerequisites, and separable testing. Revisit after the first usability round. |
| **Q2** | How are source repositories selected and authorised? | Analysis quality depends on it; it is also the largest new attack surface | Explicit user-provided local paths, plus inference from deployment tags offered as *suggestions requiring confirmation*. No automatic remote clone. Needs a decision on whether GitHub-authenticated remote reads are ever permitted. |
| **Q3** | Where does dependency topology come from — ARG, Application Map, config, or code? | Determines edge quality and whether telemetry is a hard prerequisite | **All four, labelled.** Each edge records `edgeSource` and `correlationConfidence`. Open: whether an observed (telemetry) edge should be required before a dependency-fault recommendation may rank in the top 3. |
| **Q4** | How do we get live service-side scenario eligibility, given no `notRecommendedReason`? | Without it, "why can't I run this" is unanswerable | Synthesise from capability map + parameter satisfiability (Tier A), plus configuration-scoped validation when the user opts into Tier B; file CS-4 and CS-4b. Open: whether the Discovered Resources / Connections operation groups expose a richer read-only signal we have not yet exercised — this is the single change that would let Tier B be deleted. |
| **Q5** | What is the minimum telemetry/SLO contract required before execution? | Determines `DQ-NO-TELEMETRY` strictness | Proposed minimum: (a) one request/throughput signal for the work predicate, (b) one success/error signal for steady state, (c) for dependency faults, dependency spans for the specific target host, (d) for alert predicates, a matching alert rule. SLO is optional; when absent, thresholds derive from the `pre` baseline. Needs sign-off. |
| **Q6** | Are required preview operations available in target runtimes, and should the pin move from `2026-05-01-preview` to `2026-08-01-preview`? | Source proves the pin, not deployed operation availability | Stay on the current pin until Phase 0 exercises required calls. Move only with recorded fixtures and compatibility evidence. |
| **Q7** | Should `chaos-analyze` be allowed to run without a workspace? | Affects whether analysis is usable pre-onboarding | Lean yes — analysis is a code/IaC/resource activity; only `chaos-recommend` requires availability data. |
| **Q8** | Does the reverse-Advisor flow have a receiving partner? | Determines whether `advisor-candidate.v1.json` is worth emitting | Unknown. **Treated as a design note, not a work item** — no schema, tool or task is scheduled for it, and the corresponding Epic 11 task slot (E11-T2) is marked removed rather than TO DO. If a partner appears, the shape is a small additive transform over `diagnosis.v1.json`, so deferring costs nothing. |
| **Q9** | Where should `$CHAOS_EVIDENCE_ROOT` default to on each OS, and what is the retention default? | Durability vs disk footprint | Lean: per-user app-data directory, 90-day retention, aggregates only. |
| **Q10** | Do we retain `chaos_fix_resource_permissions` at all once targeted remediation exists? | Broad grants are a security smell | Lean: retain for one release behind explicit consent, then re-evaluate on telemetry. |
| **Q11** | What was the *third* App Insights query failure in F4? | The field record names three failures; only two survive verification (subscription injection, classic schema). The third was attributed to `first` being a reserved token, which is unsupported — the KQL reserved-keywords reference does not list it, and `--first` is an Azure CLI/ARG paging parameter mapping to REST `$top`, not a KQL construct | Needs the original session transcript re-read to recover the actual error text. Until then the plan encodes only the two verified causes and `test_appinsights_subscription_injection_and_classic_schema` asserts only those. If the third cause is recovered and is real, it becomes a third assertion; if it was a mis-attribution of one of the other two, nothing changes. |
| **Q12** | Where does `fault-semantics.md` coverage come from, and how much is needed before the suite is usable? | This is the **launch-blocking usability question**, not a documentation detail — see the analysis in Epic 7a | Proposed: seed from the Chaos fault library documentation + Azure SDK behaviour notes, then confirm empirically per fault via probe runs. Needs a decision on the acceptance bar (proposed: every fault type reachable by a top-20 scenario has an entry with at least `coverage: heuristic`) and on who owns ongoing curation. |
| **Q13** | What are target-service retention/cancel semantics, runtime MCP exposure, and current `chaos-mcp` PyPI publication status? | Repository workflows/configuration show intent, not deployed/runtime state | Verify in Phase 0 against supported target environments; do not encode source-based assumptions. |

---

## Implementation Phases

| Phase | Epics | Content | Exit criteria |
|---|---|---|---|
| **Phase 0 — Baseline contract, tests, preflight** | **E1** | Freeze the five-skill/15-tool/state/impact contracts; add host-visible tool preflight and direct lifecycle contract tests | Existing `/start-chaos`, five skills, 15 signatures/envelopes, replay, Pester matrix, pytest 3.10–3.13 and ruff are green before feature work |
| **Phase 1 — Current state and evidence durability** | **E2** | Mirror/import `STARTCHAOS_STATE_PATH` into an atomic per-user evidence root; add schemas without breaking impact v1 | Current state resumes unchanged; mirror survives repo/session cleanup; secrets/key material are unreachable |
| **Phase 2 — Setup validation and exclusions** | **E3** | Harden current setup/config/validation, expose include/exclude preview and targeted RBAC before broad fix | Existing setup path works; exclusions are visible; broad permission fix requires explicit consent |
| **Phase 3 — Run validation and identity** | **E4** | Preserve strict validate/fix/revalidate; harden run-ID recovery and action identity | Concurrent-run fixture resolves correctly or fails loudly; null action name is never silently mislabeled |
| **Phase 4 — Impact telemetry normalization** | **E5** | Extend `monitor.py`, `server.py`, `chaos-impact`, and replay with App Insights, exact alerts and fault-window pack | F2/F3/F4 regressions pass; PowerShell alerts/Service Health behavior remains; three existing monitor tools stay compatible |
| **Phase 5 — Additive discovery/analysis entries** | **E6–E8** | Add scope/inventory/availability/analyze/recommend by composing current assets | Each entry names reused main assets; no current skill is deprecated; artifacts validate offline |
| **Phase 6 — Targeted run, proof, and diagnosis** | **E9–E10** | Add run/diagnose; build attestation, two-sided proof, liveness, mechanism ledger and verdict | F1/F6/F10/F11/F14/F15 tests pass; control-plane-only is `NOT EXERCISED` |
| **Phase 7 — Evidence and rollout** | **E11** | Add evidence entry; docs, examples, synchronized additive minor version | All compatibility gates pass and all three version files move together |
| **Post-launch** | **E7a empirical tasks** | Upgrade heuristic fault semantics via dedicated-subscription probe runs | Separate funded program; never CI and never claimed as already available |

---

## Files Affected

### Modified `[MAIN]`

| Exact current path | Planned reuse/change |
|---|---|
| `copilot-cli-plugin/skills/start-chaos/SKILL.md` and `copilot-cli-plugin/skills/start-chaos/scripts/Invoke-StartChaos.ps1` | Retain triggers/orchestration; add preflight and evidence mirroring |
| `copilot-cli-plugin/skills/create-workspace/SKILL.md` and `copilot-cli-plugin/skills/create-workspace/scripts/Invoke-CreateWorkspace.ps1` | Add plan/reuse/provenance without replacing |
| `copilot-cli-plugin/skills/setup-scenario/SKILL.md` and `copilot-cli-plugin/skills/setup-scenario/scripts/Invoke-SetupScenario.ps1` | Exclusion preview, normalized validation, targeted RBAC first |
| `copilot-cli-plugin/skills/run-scenario/SKILL.md` and `copilot-cli-plugin/skills/run-scenario/scripts/Invoke-RunScenario.ps1` | Preserve strict gate; harden identity/recovery |
| `copilot-cli-plugin/skills/chaos-impact/**` | Extend collection/schema-compatible output/tests/replay; do not duplicate |
| `copilot-cli-plugin/agents/start-chaos.md` | Add host-visible preflight and targeted entry guidance |
| `copilot-cli-plugin/scripts/{State,Render,New-RunReport,Rbac,Validate-AndFix,Invoke-AzRest,Invoke-AzChaos,Wait-AzureLro,Ensure-AzLogin}.ps1` | Extend current shared seams |
| `copilot-cli-plugin/.chaos-plugins.yaml.example` | Add evidence root/retention and proof-policy examples |
| `copilot-cli-plugin/mcp/chaos_mcp/server.py` | Keep all 15 decorators; add wrappers and additive run/result fields |
| `copilot-cli-plugin/mcp/chaos_mcp/azure.py` | Paging/provenance and optional pin consolidation |
| `copilot-cli-plugin/mcp/chaos_mcp/monitor.py` | App Insights, alert instances and fault-window pack helpers |
| `copilot-cli-plugin/mcp/tests/test_auth_mode.py`, `test_monitor_tools.py` | Preserve existing tests; add regressions |
| `copilot-cli-plugin/mcp/pyproject.toml`, `copilot-cli-plugin/mcp/README.md`, `copilot-cli-plugin/mcp/mcp-config.example.json` | Version/dependencies/docs/config updates as needed |
| `copilot-cli-plugin/plugin.json` | Retain directory/server registrations; synchronize version only after gates |
| `.github/plugin/marketplace.json` | Synchronize additive minor version |
| `copilot-cli-plugin/README.md`, `copilot-cli-plugin/CHANGELOG.md`, `copilot-cli-plugin/CONTRIBUTING.md`, `copilot-cli-plugin/docs/impact-synthesis-skill.md` | Evolution/compatibility documentation |
| `.github/workflows/test.yml` | Add contract/preflight/replay tests without shrinking matrices |

### New `[NEW]`

| Exact proposed path/family | Purpose |
|---|---|
| `copilot-cli-plugin/skills/{chaos-scope-setup,chaos-inventory,chaos-availability,chaos-analyze,chaos-recommend,chaos-run,chaos-diagnose,chaos-evidence}/SKILL.md` | Additive targeted entry definitions that name composed main assets |
| `copilot-cli-plugin/schemas/{scope-setup,inventory,availability,hypotheses,recommendations,run-record,diagnosis,evidence-bundle,mechanism-ledger}.v1.schema.json` | Focused artifacts; no monolithic state replacement |
| `copilot-cli-plugin/references/chaos/{evidence-contract,verdict-matrix,fault-semantics,telemetry-contract,blast-radius}.md` | Shared field-derived contracts |
| `copilot-cli-plugin/mcp/chaos_mcp/{scope,availability,evidence,proof,analysis,scoring,verdict}.py` | Semantically distinct scope/planning, opt-in probe validation, store/proof, and pure decision modules |
| `copilot-cli-plugin/mcp/chaos_mcp/apiversions.py` | Optional Python pin consolidation after a baseline test proves behavior |
| `copilot-cli-plugin/mcp/tests/{test_lifecycle_contract,test_scope,test_evidence,test_proof,test_analysis,test_scoring,test_verdict,test_tool_manifest,test_execute,test_fault_semantics}.py` | New additive tests; monitor regressions modify existing `[MAIN] test_monitor_tools.py` rather than creating a replacement |
| `copilot-cli-plugin/mcp/tests/fixtures/**` | F1–F15 and compatibility fixtures |
| `copilot-cli-plugin/skills/start-chaos/tests/Preflight.Tests.ps1` | Skill requirement/host-visible inventory contract; located under the existing Pester `Run.Path` |
| `copilot-cli-plugin/mcp/tests/e2e/test_journey_replay.py` | Python replay over the same scrubbed corpus |
| `evals/recommendation/**` | Recommendation-quality golden set/rubric/scorer |
| `docs/targeted-chaos-skills.md`, `docs/examples/{full-journey,cold-diagnose}.md` | User guidance |

### Not ported `[PR32 PROTOTYPE]`

| Prototype-only path | Disposition |
|---|---|
| `copilot-cli-plugin/references/chaos-loop/scenario-catalog.v1.json` and `scenario-catalog.md` | **Do not port**; service-derived availability is authoritative |
| `copilot-cli-plugin/scripts/chaos_loop_state.py` | **Do not port wholesale**; re-express atomic/proposal-evaluate patterns |
| `copilot-cli-plugin/schemas/chaos-loop/{run-state.v1,external-gate.v1,workspace-plan.v1}.schema.json` | **Do not port**; focused new artifacts cover retained concepts |
| `copilot-cli-plugin/skills/{chaos-loop,resilience-analysis,chaos-execution,diagnostic,advisory,coding}/**` | **Do not port**; current shipped skills remain and targeted entries are additive |

There is no "Deleted from main" table because none of these prototype paths exists at the research SHA.

---

## Implementation Plan

### Epic 1 — Baseline contracts, tests, and runtime preflight — DONE

**Goal:** Prove and freeze the shipped behavior before adding anything.
**Prerequisites:** none.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E1-T1 | TEST | Snapshot the five skill names/triggers, current state fixture, impact schema v1, and exact 15 tool signatures/envelopes from the research SHA | `mcp/tests/test_lifecycle_contract.py`, `skills/chaos-impact/tests/e2e/**` | DONE |
| E1-T2 | TEST | Add direct recorded tests for the ten lifecycle tools currently lacking them | `mcp/tests/test_lifecycle_contract.py` | DONE |
| E1-T3 | IMPL | Add `requiredTools` declarations and host-visible inventory preflight to current skills; never add server self-introspection | `skills/*/SKILL.md`, `agents/start-chaos.md` | DONE |
| E1-T4 | TEST | CI lint every declared tool against decorators in `server.py`; assert exactly the original 15 remain callable. Put Pester coverage at `skills/start-chaos/tests/Preflight.Tests.ps1`, under current `Run.Path='./copilot-cli-plugin/skills'` | `mcp/tests/test_tool_manifest.py`, `skills/start-chaos/tests/Preflight.Tests.ps1`, `.github/workflows/test.yml` | DONE |
| E1-T5 | SPIKE | Verify runtime MCP SDK/output-schema support, current PyPI availability, and required preview operations in a target environment; record unknowns rather than inferring from source | `mcp/README.md`, test evidence | DONE |
| E1-T6 | TEST | Run unchanged Pester OS matrix, pytest Python matrix, ruff, and current offline replay as the baseline gate | `.github/workflows/test.yml` | DONE |
| E1-T7 | REFACTOR | After baseline tests, consolidate Python API pins from `azure.py`, `monitor.py`, and `server.py` into `apiversions.py`; keep PowerShell impact pins in `Constants.ps1` | exact current modules + new constants module | DONE |

**Acceptance criteria**
- [x] Five skills, 15 tools, state fixture, impact schema v1 and replay are frozen by tests.
- [x] Registration-vs-runtime availability produces an exact named preflight failure (F5).
- [x] CI test discovery output includes `skills/start-chaos/tests/Preflight.Tests.ps1` without changing or narrowing the current Pester `Run.Path`.
- [x] Existing Pester/pytest/ruff matrices pass before and after each later epic.

**Completed:** 2026-08-24

**Completion notes**
- Verification gate on this machine: `pytest` 104 passed, `ruff check chaos_mcp tests` clean, `Invoke-Pester -Path ./copilot-cli-plugin/skills` 112 passed / 0 failed with `skills/start-chaos/tests/Preflight.Tests.ps1` discovered under the unchanged `Run.Path`.
- E1-T7: `apiversions.py` holds seven flat ARM api-version constants plus one aggregate map and the Log Analytics path version. `azure.py` now builds the Log Analytics query URL from `LOG_ANALYTICS_QUERY_VERSION` (value `"v1"`, byte-identical to the previous hardcoded segment, so recorded fixtures stay valid); `test_no_pin_is_dead` enforces that no pin is unused.
- E1-T1: `FROZEN_SKILLS` holds real normalised description strings for all five skills — no `None` escape hatch, so every trigger is unconditionally frozen.
- E1-T3/T4 (F5): preflight is host-inventory driven and never introspects the server (`test_preflight_never_introspects_the_server`). Failure text is duplicated across Python and PowerShell and pinned by `test_preflight_failure_prefix_matches_powershell`. Negative/edge coverage: empty host inventory, case-sensitivity near-miss, extra host tools, zero declared tools.
- `create-workspace` declares only `chaos_create_workspace`; the over-declared `chaos_get_workspace` was dropped so preflight cannot block on a tool the skill never calls.
- Documented decision: `chaos_set_auth_mode`/`chaos_get_auth_mode` are deliberately excluded from every skill's `requiredTools` — Phase 0 authenticates via `scripts/Ensure-AzLogin.ps1` and the server defaults to CLI auth, making the pair an optional managed-identity override. Rationale recorded in `agents/start-chaos.md` and pinned by `Preflight.Tests.ps1`.

---

### Epic 2 — Compatible state and durable evidence — DONE

**Goal:** Preserve current state while adding evidence that survives repo/session cleanup.
**Prerequisites:** Epic 1.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E2-T1 | IMPL | Define focused artifact schemas plus a backward-compatible importer for current `startchaos-state.json`; keep impact schema v1 | `schemas/*.v1.schema.json`, `scripts/State.ps1` | DONE |
| E2-T2 | IMPL | Mirror phase outputs atomically to `$CHAOS_EVIDENCE_ROOT` (per-user default), while continuing to update `STARTCHAOS_STATE_PATH` | `scripts/State.ps1`, `.chaos-plugins.yaml.example` | DONE |
| E2-T3 | IMPL | Add MCP evidence read/write/list only for cross-session access; path canonicalization, redaction and key denylist are mandatory | `mcp/chaos_mcp/evidence.py`, `server.py` | DONE |
| E2-T4 | IMPL | Add `evidence-contract.md` and `verdict-matrix.md`; re-express `[PR32 PROTOTYPE]` invariants without copying its state engine | `references/chaos/*.md` | DONE |
| E2-T5 | TEST | State round-trip/import, tmp/repo wipe survival, atomic concurrency, redaction, traversal/symlink/key-material denial | `mcp/tests/test_evidence.py`, Pester state tests | DONE |

**Acceptance criteria**
- [x] An existing `startchaos-state.json` resumes unchanged and is mirrored, not relocated.
- [x] Evidence survives deletion of repo/session temporary content (F12).
- [x] No secret or approval key is reachable through evidence tools.

**Completed:** 2026-08-24

**Completion notes**
- Verification gate on this machine: `python -m pytest -q` → 193 passed / 1 skipped; `ruff check chaos_mcp tests` → all checks passed.
- E2-T3 hardening: `_is_ascii_digits(value)` (`bool(value) and value.isascii() and value.isdigit()`) is the single pinned predicate for model-supplied numeric strings. `str.isdigit()` alone was unsafe on both sides — `int('\u00b2')` raises (escaping the `{ok, errorType}` envelope as a raw `ValueError`) while `int('\u0967')` silently succeeds as `1`. `try/except ValueError` would have closed only the crash half, so the alphabet is pinned to ASCII instead.
- Call sites converted: `_coerce_revision` (checks `value.strip()`, so the pre-existing lenient `' 5 '` padding behaviour is preserved) returns `EvidenceBadRevision`; `_decode_token` (after the `isinstance(str)` guard) returns `EvidenceBadToken`.
- Audited every `int(` in `evidence.py` for the same defect: `retention_days()` is env-sourced and already `try/except`-wrapped; the L625 parse reads a revision the store itself wrote. No sibling instances remain.
- Regression coverage was added as parametrized inputs to the tests that already own those behaviours; `test_a_non_integer_expected_revision_stays_inside_the_envelope` asserts the named `errorType` *and* that the refused write never landed, giving the silent-accept path explicit no-side-effect coverage.
- Test hygiene: the manifest guard was renamed to `test_server_registers_the_frozen_fifteen_plus_declared_additions` to match what it now asserts against the 18-tool registry (nothing removed from the frozen 15, nothing added undeclared); the redundant `len(ORIGINAL_FIFTEEN_TOOLS & registered) == 15` assertion was dropped as implied by `missing`. `mcp/README.md` was updated so the cited test name stays resolvable.
- `references/chaos/evidence-contract.md` §10 records the ASCII-digits-only rule for `expected_revision` and `continuation_token`, and folds the `sha256`/`digest` duplicate spelling into the existing deprecation note (`digest` is the contract field, `sha256` the deprecated alias).

---

### Epic 3 — Harden current setup validation and exclusions

**Goal:** Improve the shipped setup path before adding targeted setup/availability entries.
**Prerequisites:** Epics 1–2.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E3-T1 | IMPL | Render resolved include/exclude targeting and blast radius before configuration creation | `skills/setup-scenario/scripts/Invoke-SetupScenario.ps1`, `Render.ps1` | TO DO |
| E3-T2 | IMPL | Normalize `validations/latest` permission/resource errors; propose exact targeted grants from current `Rbac.ps1` before broad fix | `Validate-AndFix.ps1`, `Rbac.ps1`, `server.py` | TO DO |
| E3-T3 | IMPL | Keep `chaos_fix_resource_permissions` available only after an explicit consent prompt describing breadth | `skills/setup-scenario/SKILL.md`, `skills/run-scenario/SKILL.md` | TO DO |
| E3-T4 | IMPL | Document/service-test exclusion recipes and configuration-scoped validation limits | `references/chaos/blast-radius.md`, current skill docs | TO DO |
| E3-T5 | TEST | Existing setup replay plus include/exclude precedence, blocker normalization, targeted-first, and consent tests | Pester setup tests, `mcp/tests/test_lifecycle_contract.py` | TO DO |

**Acceptance criteria**
- [ ] Existing setup path remains directly invocable and validates before completion.
- [ ] Exclusions and affected resources are shown before mutation (F8).
- [ ] Broad permission fix never runs without explicit consent.

---

### Epic 4 — Harden current run validation and identity

**Goal:** Make the shipped run path concurrency-safe and evidence-addressable.
**Prerequisites:** Epic 3.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E4-T1 | IMPL | Preserve validate/fix/revalidate gate and frozen configuration summary before execute | `Invoke-RunScenario.ps1`, `Validate-AndFix.ps1` | TO DO |
| E4-T2 | IMPL | Capture `requestSentAt`; resolve only matching runs started afterward with bounded retry and loud ambiguity/failure | `mcp/chaos_mcp/server.py`, `Invoke-RunScenario.ps1` | TO DO |
| E4-T3 | IMPL | Preserve raw run payload and add action identity source/confidence fallback when `actionName` is null | `server.py`, `New-RunReport.ps1` | TO DO |
| E4-T4 | TEST | Empty-start, concurrent-run, null-action, validation failure, cancel-request and resume fixtures | `mcp/tests/test_lifecycle_contract.py`, Pester run tests | TO DO |

**Acceptance criteria**
- [ ] Execute/get/cancel signatures and envelopes are unchanged.
- [ ] Empty start yields one correct run ID or a named error; never a guessed concurrent run (F7).
- [ ] Null action names are preserved and never silently relabeled.

---

### Epic 5 — Monitoring core: the fault-window pack

**Goal:** One call returns the complete pre/during/post evidence bundle, on the correct schema.
**Prerequisites:** Epic 1.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E5-T1 | IMPL | Add half-open/symmetric window helpers and pack composition around the three current monitor helpers | `mcp/chaos_mcp/monitor.py`, wrappers in `server.py` | TO DO |
| E5-T2 | IMPL | `monitor_query_appinsights`: inject subscription and normalize classic lowercase resource-scoped schema; do not implement the falsified `first` escaping theory | `monitor.py`, `server.py` | TO DO |
| E5-T3 | IMPL | `monitor_list_alert_instances` matching current PowerShell `timeRange=custom` + `customTimeRange` and `2023-05-01-preview` → `2018-05-05` fallback; record version used | `monitor.py`, `server.py`, `chaos-impact/scripts/Get-MonitorSignals.ps1` | TO DO |
| E5-T4 | IMPL | `monitor_fault_window_pack` and `monitor_check_work_starvation`; consume metrics/logs/activity/alerts and preserve `null` + caveat | `monitor.py`, `server.py` | TO DO |
| E5-T5 | TEST | App Insights, alert exact-window, pack boundaries, starvation ordering, and current three-tool regressions | `mcp/tests/test_monitor_tools.py`, `chaos-impact/tests/e2e/**` | TO DO |

**Acceptance criteria**
- [ ] A single `monitor_fault_window_pack(runId)` call returns all three buckets (F2).
- [ ] App Insights queries succeed first time on the classic resource-scoped schema (F4).
- [ ] Absent sources return `null` + caveat, never `0` (NFR-3).
- [ ] Existing PowerShell alerts/Service Health and all three current MCP monitor tools remain green.

---

### Epic 6 — Additive scope, inventory, and availability entries

**Goal:** Expose targeted discovery without replacing current setup.
**Prerequisites:** Epics 1–5.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E6-T1 | IMPL | Add `chaos-scope-setup` by composing `create-workspace`, state, RBAC, create/get workspace tools; dry-run by default | new SKILL.md; minimal `azure.py`/`server.py` extensions | TO DO |
| E6-T2 | IMPL | Add `chaos-inventory` by reusing workspace state, impact diagnostic/monitor collection and paged ARM helpers | new SKILL.md; existing collectors plus focused pure inventory code | TO DO |
| E6-T3 | IMPL | Add `chaos-availability` over current refresh/list/create/validate paths; Tier A reports permission unknown, Tier B is explicit disposable validation | new SKILL.md; `server.py`/`azure.py` only where current responses are insufficient | TO DO |
| E6-T4 | TEST | Workspace reuse, inventory provenance/null IDs, service-only scenario names, Tier A unknown, Tier B cleanup | new recorded tests plus current setup replay | TO DO |

**Acceptance criteria**
- [ ] Each skill documents the exact current skills/scripts/tools it composes.
- [ ] No prototype scenario catalog is ported and no scenario is fabricated.
- [ ] Current create/setup/start entry paths remain unchanged.

---

### Epic 7 — Analysis, correlation and the mechanism-class ledger

**Goal:** Hypotheses are grounded, non-repeating, and liveness-aware.
**Prerequisites:** Epics 1–6.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E7-T1 | IMPL | `correlate_iac_to_resources()` — deployment history → tags → naming ladder with recorded method and confidence. **Pure library function, not an MCP tool** (D15) | `mcp/chaos_mcp/analysis.py` | TO DO |
| E7-T2 | IMPL | IaC normalisation adapters: ARM JSON, `bicep build`, `terraform show -json`, `helm template`/`kustomize build`; each optional and degrade-reporting | `mcp/chaos_mcp/analysis.py` | TO DO |
| E7-T3 | IMPL | `check_mechanism_class()` over the durable failed-class ledger (F11). **Pure library function** reading the ledger through `evidence_get` | `mcp/chaos_mcp/analysis.py` | TO DO |
| E7-T4 | IMPL | `chaos-analyze` SKILL.md — deterministic resource rules, model-owned code/IaC reading, mandatory liveness predicate for probe/observability hypotheses (F10), `consumerCoupling` capture (F13) | `skills/chaos-analyze/SKILL.md` | TO DO |
| E7-T5 | TEST | Correlation-ladder fixtures (high/medium/low/unresolvable); `test_mechanism_class_repeat_blocked`; liveness-required schema test | `mcp/tests/test_analysis.py` | TO DO |

**Acceptance criteria**
- [ ] No hypothesis cites an ARM ID that was not resolved by a recorded method.
- [ ] Three different implementations of one mechanism class are blocked as one (F11).
- [ ] A probe hypothesis without a liveness predicate fails schema validation (F10).

---

### Epic 7a — Fault-semantics coverage (the launch-usability epic)

**Goal:** Enough per-fault data-plane knowledge exists that the suite returns useful verdicts at launch rather than a uniform `NOT EXERCISED`.
**Prerequisites:** Epic 2 for the document structure. The documentation-sourced half (T1, T2, T5, T6) can proceed with Epics 6–8. The empirical half (T3, T4) requires Epic 9 execution and Epic 10 proof, and remains post-launch.

**Cost and launch gating.** T3/T4 are the only tasks in this plan that require live Azure spend: a dedicated test subscription with representative resources per fault type, a synthetic workload generator, and operator time per probe run. They **cannot run in CI** and must not be wired into it. Proposed split, to be confirmed with the owning team: **launch is gated on the heuristic tier only** — every fault type reachable by a top-20 scenario has an entry with at least `coverage: heuristic` and a named `dataPlaneProbe`. The `verified` tier (10 fault types) is a **post-launch programme** funded as ongoing chaos-team engineering time, upgrading entries as the harness is run. Users are never misled in the interim because `dataPlaneProbe.coverage` is surfaced at recommendation time, so a `heuristic` probe is visibly weaker evidence than a `documented` one.

**Why this is its own epic.** The safety rule from F6 — a leg is only `CONFIRMED`/`REFUTED` if data-plane disruption is *proven*, and proof requires a per-fault probe from `fault-semantics.md` — is correct and non-negotiable. But it has a consequence that is easy to miss: **at launch, `fault-semantics.md` is seeded from a single engagement, so nearly every fault type has no entry, so nearly every run returns `NOT EXERCISED` regardless of what actually happened.** A tool that is rigorous and uniformly uninformative will not be used, and the rule that made it rigorous will be the first thing removed. Coverage is therefore a launch requirement, not documentation debt.

**Source strategy**, cheapest first:

| Source | What it yields | Confidence it earns |
|---|---|---|
| Chaos Studio fault library documentation | The declared control-plane mutation per fault, and often the intended data-plane effect | `coverage: documented`, `mechanismConfidence: plausible` |
| Azure SDK behaviour notes and source (connection lifecycle, retry, caching) | Why a client might not observe a control-plane mutation — the F6 class of surprise | `mechanismConfidence: plausible`, never `verified` on reading alone |
| **Empirical probe runs** in a test subscription, one per fault type, with a deliberately generated workload | The actual observed effect, with numbers | `coverage: documented`, `mechanismConfidence: verified` |
| Field engagements | Real-world variants and starvation recipes | Appended as occurrences |

Only the third source produces `verified`. The first two are how the file gets broad, shallow coverage quickly; the third is how it gets deep where it matters.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E7a-T1 | IMPL | Define the `fault-semantics.md` entry schema: `faultUrn`, `controlPlaneMutation`, `observedEffect`, `candidateMechanism`, `mechanismConfidence`, `dataPlaneProbe` (the query/signal that proves disruption), `starvationRecipe`, `coverage` | `references/chaos/fault-semantics.md` | TO DO |
| E7a-T2 | IMPL | Populate from the fault library documentation for **every fault type reachable by a top-20 scenario**, at `coverage: heuristic` where the probe is inferred rather than observed | `references/chaos/fault-semantics.md` | TO DO |
| E7a-T3 | IMPL | Build a probe-run harness: for one fault type, drive a synthetic workload, execute at minimum blast radius, and record the observed data-plane signature | `mcp/tests/e2e/probe_harness.py` | TO DO |
| E7a-T4 | IMPL | Run the harness against the top-10 fault types by expected usage; upgrade those entries to `coverage: documented` / `mechanismConfidence: verified` | `references/chaos/fault-semantics.md` | TO DO |
| E7a-T5 | IMPL | **Launch-mode handling for uncovered faults.** When a fault type has no entry, the recommendation still ranks but carries `dataPlaneProbe.coverage: "none"` and a prominent warning: *"a run of this scenario can only return NOT EXERCISED until a data-plane probe exists for this fault."* `DQ-NO-DATAPLANE-PROBE` is **warn-only** until the coverage bar is met, then becomes disqualifying | `mcp/chaos_mcp/scoring.py`, `skills/chaos-recommend/SKILL.md` | TO DO |
| E7a-T6 | TEST | A coverage test asserting the acceptance bar below; a test asserting an uncovered fault produces the warning and not a silent `NOT EXERCISED` at diagnosis time | `mcp/tests/test_fault_semantics.py` | TO DO |

**Acceptance criteria**
- [ ] **Launch gate:** every fault type reachable by a top-20 scenario has a `fault-semantics.md` entry with at least `coverage: heuristic` and a named `dataPlaneProbe`.
- [ ] **Post-launch programme:** at least 10 fault types reach `coverage: documented` with `mechanismConfidence: verified` from an actual probe run. Not a launch gate; funding and ownership confirmed before Epic 9 completes.
- [ ] A user is told **before** executing that an uncovered fault can only yield `NOT EXERCISED` — the limitation is surfaced at recommendation time, not discovered after a run.
- [ ] No entry's `candidateMechanism` can influence a verdict; only `observedEffect` and `dataPlaneProbe` can. The seed entry records the falsified `MaxMessageSize` theory under `rejectedMechanisms` so it is not re-derived.
- [ ] T3/T4 are excluded from CI and documented as requiring a dedicated test subscription.

---

### Epic 8 — Recommendation scoring

**Goal:** Ranking is deterministic, explainable, and cannot fabricate a scenario.
**Prerequisites:** Epics 6–7.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E8-T1 | IMPL | Disqualification rules `DQ-*` as pure functions | `mcp/chaos_mcp/scoring.py` | TO DO |
| E8-T2 | IMPL | Scoring model with `scoreBreakdown` and tie-breaks, including `couplingAdjustment` (F13) | `mcp/chaos_mcp/scoring.py` | TO DO |
| E8-T3 | IMPL | `compute_blast_radius()` producing `resourceTargeting` include/exclude plus starvation recipes (F8). **Pure library function, not an MCP tool** (D15) | `mcp/chaos_mcp/scoring.py` | TO DO |
| E8-T4 | IMPL | `chaos-recommend` SKILL.md, with hard validation that every emitted `scenarioId` exists in `availability.v1.json` | `skills/chaos-recommend/SKILL.md` | TO DO |
| E8-T5 | TEST | Rule-by-rule disqualification tests; `test_coupling_split_penalty`; scenario-fabrication rejection test | `mcp/tests/test_scoring.py` | TO DO |
| E8-T6 | TEST | Golden set (30 cases), scorer, and the nDCG@3 regression gate | `evals/recommendation/**`, `.github/workflows/test.yml` | TO DO |

**Acceptance criteria**
- [ ] Every disqualification code has a dedicated test.
- [ ] A recommendation naming a scenario absent from availability fails artifact validation.
- [ ] nDCG@3 baseline is recorded and CI gates on a ≤0.05 regression.

---

### Epic 9 — Additive targeted run and build attestation

**Goal:** Safe, frozen, recoverable execution with a real run ID.
**Prerequisites:** Epics 4, 6, 8.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E9-T1 | IMPL | `frozenValidation` hash over the seven fields + byte-for-byte drift gate at execute | `mcp/chaos_mcp/server.py` | TO DO |
| E9-T2 | IMPL | Consume the hardened current `chaos_execute_scenario`/get/cancel path; do not add aliases or duplicate execution wrappers | `mcp/chaos_mcp/server.py`, current run skill/script | TO DO |
| E9-T3 | IMPL | `chaos-run` SKILL.md: explicitly composes current setup/run skills, strict validation, approval, dry run, abort/cancel/recovery | `skills/chaos-run/SKILL.md` | TO DO |
| E9-T4 | IMPL | Pre-flight steady-state capture + build attestation persisted into `run-record.v1.json` | `mcp/chaos_mcp/proof.py`, `evidence.py` | TO DO |
| E9-T5 | TEST | `test_run_id_recovered_from_empty_start`; frozen-drift abort test; approval-required test; cancellation path test | `mcp/tests/test_execute.py` | TO DO |

**Acceptance criteria**
- [ ] An empty 2xx start still yields a run ID or a loud, named failure (F7).
- [ ] Any drift between validate and execute aborts with a diff.
- [ ] Execution never proceeds without an approval token.

---

### Epic 10 — Diagnosis

**Goal:** A verdict computed by code from numeric evidence, enterable cold by run ID.
**Prerequisites:** Epics 5, 6, 9.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E10-T1 | IMPL | `chaos_prove_fault_landed`: ARM entity-state/re-poll plus independent per-leg data-plane delta; Activity Log cannot satisfy proof | `mcp/chaos_mcp/proof.py`, wrapper in `server.py` | TO DO |
| E10-T2 | IMPL | Pure verdict/baseline/liveness evaluation; `NOT EXERCISED` never downgraded | `mcp/chaos_mcp/verdict.py` | TO DO |
| E10-T3 | IMPL | `chaos-diagnose` SKILL.md with `explore`/`verify` modes and the verify-mode changed-path rule (F14) | `skills/chaos-diagnose/SKILL.md` | TO DO |
| E10-T4 | IMPL | Cold-start path: `evidence_get(runId)` + `chaos_get_scenario_run`; degraded behaviour with `steadyStateBaseline: null` | `mcp/chaos_mcp/evidence.py` | TO DO |
| E10-T5 | IMPL | Exercise-repair brief generator | `skills/chaos-diagnose/SKILL.md` | TO DO |
| E10-T6 | TEST | Event Hubs control-plane-only, NSG re-poll, liveness, mechanism-class, verdict table, cold entry and verify-mode fixtures | `mcp/tests/test_proof.py`, `test_verdict.py` | TO DO |

**Acceptance criteria**
- [ ] Verify mode without changed-path proof yields `NOT EXERCISED` + a repair brief (F14).
- [ ] `chaos-diagnose --run-id` works with no prior conversational context (F12).
- [ ] Control-plane-only or unproven mechanism liveness yields `NOT EXERCISED` (F6/F10).
- [ ] `candidateMechanism` cannot influence a verdict.

---

### Epic 11 — Evidence export, docs and rollout

**Goal:** The suite is shippable, documented and versioned.
**Prerequisites:** Epics 1–10.

| Task | Type | Description | Files | Status |
|---|---|---|---|---|
| E11-T1 | IMPL | `chaos-evidence` SKILL.md + bundle assembly, redaction, Markdown rendering via `Render.ps1` | `skills/chaos-evidence/SKILL.md` | TO DO |
| E11-T2 | IMPL | *(Removed — the `advisor-candidate.v1.json` reverse-Advisor emission has no known receiving partner. Per Q8 it is a design note, not a work item: no schema, tool or task is scheduled. If a partner appears, the shape is a small additive transform over `diagnosis.v1.json`, so deferring costs nothing.)* | — | N/A |
| E11-T3 | IMPL | Package additive skills through the existing `skills/` directory registration and synchronize 0.4.0 in `plugin.json`, `mcp/pyproject.toml`, and `.github/plugin/marketplace.json`; **no current skill deprecation** | exact three version files | TO DO |
| E11-T4 | IMPL | Complete the **PowerShell half** of the two-harness E2E: `Run-OfflineReplay.ps1` exercises every PowerShell skill script against the shared fixture corpus and validates its outputs against the artifact schemas. It deliberately does **not** drive the Python journey — see §Testing Strategy for why the Pester-drives-Python bridge was rejected | `skills/chaos-impact/tests/e2e/Run-OfflineReplay.ps1` | TO DO |
| E11-T5 | IMPL | User docs + two worked examples | `docs/targeted-chaos-skills.md`, `docs/examples/*.md` | TO DO |
| E11-T6 | IMPL | File CS-1 … CS-10 with the Chaos Studio service team | *(external tracker)* | TO DO |
| E11-T7 | TEST | Both harnesses green on ubuntu/windows/macOS as **separate CI jobs** (Pester for the PowerShell skills, pytest for the Python journey), plus the golden-artifact comparison and the plugin manifest lint | `.github/workflows/test.yml`, `mcp/tests/e2e/test_journey_replay.py` | TO DO |

**Acceptance criteria** *(mirrors the four-part criterion in §Testing Strategy; the single-harness wording is deliberately not used)*
- [ ] (a) `Run-OfflineReplay.ps1` exercises every PowerShell skill script against the shared fixture corpus and validates outputs against the artifact schemas.
- [ ] (b) `test_journey_replay.py` exercises scope → inventory → availability → analyze → recommend → run → diagnose → evidence against the same corpus with zero network access.
- [ ] (c) A golden-artifact set is committed and compared in both harnesses after timestamp normalisation.
- [ ] (d) Both harnesses are wired into `.github/workflows/test.yml` as separate jobs.
- [ ] `plugin.json` 0.4.0 retains the existing `skills/` directory registration, packages all additive entries, and leaves every legacy skill functional.
- [ ] All 15 original tool names/signatures/envelopes and current state/replay compatibility tests remain green.
- [ ] Every product issue CS-1…CS-10 has a filed tracking item with the workaround referenced.
- [ ] Documentation covers the evidence store location, retention and purge.

---

## References

**Repository**

- `copilot-cli-plugin/plugin.json`, `copilot-cli-plugin/README.md`
- `copilot-cli-plugin/skills/{start-chaos,create-workspace,setup-scenario,run-scenario,chaos-impact}/SKILL.md`
- `copilot-cli-plugin/skills/chaos-impact/schema/impact-report.schema.json`, `scripts/Constants.ps1`, `templates/metrics/defaults.json`, `tests/e2e/Run-OfflineReplay.ps1`
- `copilot-cli-plugin/mcp/chaos_mcp/{server.py,azure.py,monitor.py}`
- `.github/workflows/test.yml`
- Branch `renzopretto-microsoft-add-chaos-loop-plugin`: `skills/{chaos-loop,resilience-analysis,chaos-execution,diagnostic,advisory,coding}/SKILL.md`, `references/chaos-loop/{shared-contract.md,scenario-catalog.md,scenario-catalog.v1.json}`, `schemas/{run-state.v1,workspace-plan.v1,external-gate.v1}.schema.json`, `scripts/chaos_loop_state.py`, `docs/chaos-loop.md`

**Azure Chaos Studio**

- Chaos Studio documentation — https://learn.microsoft.com/azure/chaos-studio/
- Chaos Studio REST API reference — https://learn.microsoft.com/rest/api/chaosstudio/
- `az chaos` CLI reference — https://learn.microsoft.com/cli/azure/chaos
- Chaos Studio fault and action library — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-fault-library
- Chaos Studio limitations and known issues — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-limitations
- Chaos Studio permissions and security — https://learn.microsoft.com/azure/chaos-studio/chaos-studio-permissions-security

**Azure platform**

- Azure Resource Graph query language and limits — https://learn.microsoft.com/azure/governance/resource-graph/
- Azure Monitor Metrics Batch API — https://learn.microsoft.com/rest/api/monitor/metrics-batch
- Log Analytics query API — https://learn.microsoft.com/rest/api/loganalytics/
- Application Insights table reference (workspace-based vs classic schema) — https://learn.microsoft.com/azure/azure-monitor/app/convert-classic-resource
- Azure Monitor alerts (`Microsoft.AlertsManagement`) REST API — https://learn.microsoft.com/rest/api/monitor/alertsmanagement/alerts
- Azure Activity Log — https://learn.microsoft.com/azure/azure-monitor/essentials/activity-log
- ARM deployment history — https://learn.microsoft.com/azure/azure-resource-manager/templates/deployment-history
- Azure Advisor reliability recommendations — https://learn.microsoft.com/azure/advisor/advisor-reference-reliability-recommendations

**Methodology and standards**

- Principles of Chaos Engineering — https://principlesofchaos.org/
- Azure Well-Architected Framework, RE:08 (design a reliability testing strategy) — https://learn.microsoft.com/azure/well-architected/reliability/testing-strategy
- Model Context Protocol specification (tools, `outputSchema`, annotations) — https://modelcontextprotocol.io/
- GitHub Copilot CLI plugins and skills — https://docs.github.com/copilot
- Bicep to ARM compilation — https://learn.microsoft.com/azure/azure-resource-manager/bicep/bicep-cli
- `terraform show -json` — https://developer.hashicorp.com/terraform/cli/commands/show
- nDCG and ranking evaluation — Järvelin & Kekäläinen, *Cumulated gain-based evaluation of IR techniques*, ACM TOIS 20(4), 2002

---

## Appendix A: Revision History and Corrections

This plan has been revised through Revision 5. The latest independent review scored Technical 86/100 and Readability 91/100 before the Revision 5 corrections; re-review is pending. Corrections are recorded here rather than silently overwritten. The falsification detail for field observations lives in §Background → *Corrections to the field record*.

| Rev | Change | Why it is recorded rather than silently fixed |
|---|---|---|
| 2 | **`validations/latest` re-scoped.** An earlier draft treated it as a workspace polling artifact alongside `discoveries/latest` and `evaluations/latest`. It is `@parentResource(ScenarioConfiguration)` `@singleton("latest")`, so permission blockers cannot be read without creating a configuration. This produced the Tier A / Tier B split (FR-16), CS-4b and ALT-9. | The mis-scoping had made an advertised read-only skill silently dependent on writes. Recording it prevents the same inference being made again from the API's naming symmetry. |
| 2 | **Event Hubs mechanism falsified.** The `AmqpSender` `MaxMessageSize` caching theory is wrong — `AmqpProducer.CreateLinkAndEnsureProducerStateAsync` refreshes it on every link open. The observation (namespace `Disabled`, sends 60/60) is unaffected. | The theory was about to become the seed entry of a normative behaviour oracle. It is now carried in `rejectedMechanisms` precisely so it is not re-derived by the next reader of the same source. |
| 2 | **`first` is not a KQL reserved token** (it is an Azure CLI/ARG paging parameter). No escaping layer is built; the real third App Insights failure is Q11. | Prevents building a mitigation for a non-problem. |
| 2 | External spec research confirmed `2026-05-01-preview` exists, contradicting a review finding; Revision 4 clarifies that this does not prove runtime operation availability. | Preserves the correction without converting a spec artifact into a service-availability claim. |
| 2 | **`chaos_list_tools` cut**; reconciliation moved to manifest declarations + host-visible `tools/list` + CI lint. | The tool could not detect the failure it existed for. |
| 2 | **`outputSchema` made conditional** on the runtime-capability spike (now E1-T5); **api-version pins** consolidated into `chaos_mcp/apiversions.py` (E1-T7); **`jsonschema`** added to CI. | Each was asserted as already-true and was not. |
| 3 | **`scopeId` / `scopeFingerprint` split** (D16); **`thresholdKind`** added to predicates (D17), replacing an incoherent "CONFIRMED against a null baseline" path; **`approvalToken`** issuance, `k_session` transport and `evidence_get` denylist specified (D18); Tier A disclosed its recommendation-refresh write; **Epic 7a** added with a launch gate on the heuristic tier only. | These are design gaps rather than factual errors, and each changes what an implementer builds. |
| 4 | Reframed as `[MAIN]` v0.3.0 evolution at research SHA `55c74c59a5eb123edecd91374be4d385407be8f0`; added exhaustive inventory, exact 15-tool matrix, source/field gap matrix, compatibility-first phases/files/epics, and `[PR32 PROTOTYPE]` not-ported classification. | Prevents prototype/main conflation and makes backward compatibility measurable. |
| 5 | Restored shipped scenario-tool names, removed the unsupported `/evaluate` assumption, matched the PowerShell alert query/pin fallback, specified all additive MCP contracts, and placed preflight Pester coverage under the current CI scan root. | Resolves the independent technical review blockers without changing the approved field-evidence design. |
