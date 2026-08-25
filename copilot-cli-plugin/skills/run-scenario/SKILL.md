---
name: run-scenario
description: "Execute a ScenarioConfiguration and stream ScenarioRun status with per-action breakdown until terminal state."
requiredTools:
  - chaos_execute_scenario
  - chaos_get_scenario_run
  - chaos_cancel_scenario_run
---

# RunScenario — Scenario Execution & Status Streaming

> ⛔ **ABSOLUTE RULE**: Do NOT improvise, skip, or substitute any step. On ANY error, STOP and wait for the user.

## When to use this skill (vs. the MCP server)

This skill is the **human-interactive** path: it reads run context from `startchaos-state.json`, renders status cards, and persists the run result. Use it when there is a user in the loop.

If you are an **autonomous agent** with no user to prompt, use `chaos_execute_scenario` + `chaos_get_scenario_run` (MCP) for a non-interactive run-and-poll flow. Cancellation: `chaos_cancel_scenario_run`. See `mcp/README.md`.

Both surfaces target `Microsoft.Chaos` `2026-05-01-preview` and use the local `az login` session for auth.

## Tool preflight (before any MCP-backed path)

This skill's frontmatter declares, under `requiredTools`, the MCP tools it
depends on. Before taking the MCP path, compare that declaration against the
tool inventory **the host reports** — the CLI's `tools/list` view of the MCP
servers registered in this session. Never ask the `chaos-studio` server to
describe itself: that reports what the server *registers*, not what this
session can actually call, which is precisely the gap this preflight exists to
catch.

```powershell
. "<plugin-root>/scripts/Preflight.ps1"
$required = Get-SkillRequiredTools -SkillPath "<skill-dir>/SKILL.md"
$result   = Test-RequiredTools -RequiredTools $required -AvailableTools $hostTools
if (-not $result.ok) { throw $result.message }
```

If any declared tool is missing, STOP and render `$result.message` — it names
every missing tool exactly. Do NOT substitute a different tool and do NOT
improvise an `az` / `az rest` equivalent. The PowerShell path documented below
does not use these tools and is unaffected by a preflight failure.

## How It Works

All execution and status-streaming logic lives in `scripts/Invoke-RunScenario.ps1`. The script handles confirmation gating, starting the run via `az chaos scenario run start --skip-validation --no-wait`, ScenarioRun ID resolution (start result + `run list` fallback), per-poll status rendering via `az chaos scenario run show`, terminal-state detection, and the final summary.

The AI orchestrator's **only** job is:

1. Set `$env:STARTCHAOS_STATE_PATH` to `${SESSION_DIR}/startchaos-state.json`.
2. Run the script.
3. Handle exit codes (see below).

The script takes **no parameters**: configuration name, scenario, and workspace are all read from state.

## Prerequisites

- `state.setup.status == "done"` (configuration must exist and be validated)
- `state.setup.configuration.id` populated

## Running the Script

```powershell
$env:STARTCHAOS_STATE_PATH = "<session-dir>/startchaos-state.json"
& "<skill-dir>/scripts/Invoke-RunScenario.ps1"
```

For non-interactive sessions, set `$env:STARTCHAOS_NONINTERACTIVE=1` to skip the confirmation prompt.

## Exit Codes → AI Actions

| Exit | Meaning | AI Action |
|------|---------|-----------|
| **0** | Run reached a terminal state (Succeeded / Failed / Canceled) | Done — final card already rendered by script. Inspect `state.run.status` for terminal classification. |
| **1** | Hard error before/during execution | STOP. Render the error from script output. Wait for user. State has `run.lastError`. |

## Permission blockers and the consent protocol

The pre-execute gate always validates. When validation reports blockers the
shared helper normalizes them, persists them at
`state.setup.configuration.validation.blockers`, and **offers the targeted
grants first** — the exact, minimum-scope `az role assignment create` commands
that would clear them, persisted at
`state.setup.configuration.validation.targetedGrants`.

`chaos_fix_resource_permissions` / `az chaos scenario config fix-permissions`
remains available, but it is a **broad** mutation: it grants whatever roles the
service decides are required to the workspace identity, on every target resource
in the configuration's scope, in a single call. It is not limited to the
reported blockers and the grants cannot be enumerated in advance.

Without consent the script exits 1 with `run.lastError` starting
`broadPermissionFixConsentRequired`. On that error:

1. Render the consent prompt from
   `state.setup.configuration.validation.permissionFix.consentPrompt` — it
   describes exactly this breadth.
2. Show the targeted grants and let the user run those instead if they prefer.
3. Only if the user explicitly consents, set
   `$env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX = '1'` and re-run.

Any value other than the exact string `1` is **not** consent. Never set that
variable on the user's behalf, and never call `chaos_fix_resource_permissions`
over MCP without having shown the same breadth description and received an
explicit answer.

The blast radius predicted at setup time is at `state.setup.blastRadius`. It is
an **advisory prediction**, not a filter the configuration was created with:
`az chaos scenario config create` accepts no include/exclude argument, so
`resourceTargeting` is never transmitted to the service and any resource listed
as excluded there **can still be targeted by this run**. Do not tell the user an
excluded resource is spared. The precedence and starvation rules, and how to
enforce an exclusion for real, are in `references/chaos/blast-radius.md`.

## Cancellation

On `Ctrl+C`, the script invokes `ScenarioRuns_Cancel` (POST `.../runs/{runId}/cancel`) best-effort and persists `state.run.lastError = "user-cancelled"`.

## What the Script Handles (no AI logic needed)

- Confirmation card with scenario, parameters, and scope summary (suppressed when `STARTCHAOS_NONINTERACTIVE=1`)
- Run start via `az chaos scenario run start --skip-validation --no-wait` (validation already gated upstream)
- ScenarioRun ID resolution from the start result, with `az chaos scenario run list` fallback
- Per-poll status via `az chaos scenario run show`: top status, elapsed time, per-action `scenarioRunSummary[]` table, resource count, error counts
- Terminal-state detection (`Succeeded`, `Failed`, `Canceled`) and final summary card
- Atomic state writes with error envelopes
- Cancellation handling

## Related Skills

- `setup-scenario` — must complete before this skill
- `chaos-impact` — post-run Azure Monitor impact synthesis
- `start-chaos` — orchestrator that invokes this skill
