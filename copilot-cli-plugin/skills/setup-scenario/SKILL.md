---
name: setup-scenario
description: "Discover recommended scenarios, build and validate a ScenarioConfiguration, and auto-fix resource permissions."
requiredTools:
  - chaos_refresh_recommendations
  - chaos_list_recommended_scenarios
  - chaos_create_scenario_configuration
  - chaos_validate_scenario_configuration
  - chaos_fix_resource_permissions
---

# SetupScenario — Scenario Discovery, Configuration & Validation

> ⛔ **ABSOLUTE RULE**: Do NOT improvise, skip, or substitute any step. On ANY error, STOP and wait for the user.

## When to use this skill (vs. the MCP server)

This skill is the **human-interactive** path: it shares state with the rest of the pipeline, prompts via exit codes, and renders cards. Use it when there is a user in the loop.

If you are an **autonomous agent** with no user to prompt, use the MCP tools directly: `chaos_refresh_recommendations`, `chaos_list_recommended_scenarios`, `chaos_create_scenario_configuration`, `chaos_validate_scenario_configuration`, `chaos_fix_resource_permissions`. See `mcp/README.md`.

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

All discovery, configuration, validation, and permission-fix logic lives in `scripts/Invoke-SetupScenario.ps1`. The script drives the Chaos Studio operations through the `az chaos` CLI extension — workspace evaluation, recommendation listing, scenario selection routing, parameter resolution, configuration creation, and the validate→fix→re-validate loop.

The AI orchestrator's **only** job is:

1. Set `$env:STARTCHAOS_STATE_PATH` to `${SESSION_DIR}/startchaos-state.json`.
2. Run the script (no parameters needed for the first call).
3. Handle exit codes that require user input (see below).
4. Re-run the script with the user's answers as parameters.

## Prerequisites

- `state.workspace.status == "done"` (workspace must exist; the script refuses otherwise)
- `state.context.subscriptionId` populated

## Running the Script

```powershell
$env:STARTCHAOS_STATE_PATH = "<session-dir>/startchaos-state.json"
& "<skill-dir>/scripts/Invoke-SetupScenario.ps1" @args
```

On resume: re-runs short-circuit when `state.setup.status == "done"`.

## Exit Codes → AI Actions

| Exit | Meaning | AI Action |
|------|---------|-----------|
| **0** | Configuration created and validated | Done — summary already rendered by script. |
| **1** | Hard error | STOP. Render the error from script output. Wait for user. State has `setup.lastError`. |
| **2** | Scenario selection needed | Read `state.setup.recommendedScenarios` (or the script's rendered list). `ask_user` for one name. Re-run with `-ScenarioName <chosen>`. |
| **3** | Parameter mode needed | Show the parameter table from the script output. `ask_user` which parameters they want to override (or accept defaults). Re-run with `-ParameterMode autofill` and `-ParameterValues @{ key = 'value' }` for any overrides. |
| **4** | Consent needed for the broad permission fix | STOP. The configuration exists and validation blockers are recorded. Follow the consent protocol below. |

### Important: Manual mode does NOT work

`-ParameterMode manual` uses `Read-Host` prompts that do not render in a non-interactive AI session. **Always use `-ParameterMode autofill`** combined with `-ParameterValues` for any overrides the user requests.

### Important: Exit 2 → 3 chaining

When exit 2 is followed by exit 3 on re-run, combine both answers in the next invocation:
```powershell
& Invoke-SetupScenario.ps1 -ScenarioName "ZoneDown-1.0" -ParameterMode "autofill" -ParameterValues @{ duration = 'PT5M' }
```

## Blast radius is shown before the configuration is created (F8)

Before it calls `az chaos scenario config create`, the script resolves the
candidate resources from the service recommendation (falling back to the
workspace scopes) against any `-ResourceTargeting` the caller supplied, and
renders a **Blast Radius (Predicted)** card listing the predicted affected
resources, the exclusions, any filter that matched nothing, and a starvation
warning.

> **`-ResourceTargeting` is advisory. It is not enforced by the service.**
> `az chaos scenario config create` accepts no include/exclude argument, so the
> ScenarioConfiguration covers the **full** recommendation set regardless of
> what was excluded. The targeting shapes the preview and the starvation
> refusal only. **Never tell the user an excluded resource is spared.** To
> actually spare a resource, remove it from the workspace scope or disable its
> Chaos target, then re-run `create-workspace`/setup.

```powershell
& Invoke-SetupScenario.ps1 -ScenarioName "ZoneDown-1.0" -ParameterMode autofill `
    -ResourceTargeting @{ exclude = @('/subscriptions/.../virtualMachines/vm-primary') }
```

Precedence: an empty `include` means everything is in scope, a non-empty
`include` narrows, and `exclude` always wins over `include`. If caller-supplied
targeting leaves nothing in scope the script refuses to create a configuration
that would exercise nothing (CS-7) and exits 1. The full contract — including
the per-fault exclusion recipes and how to enforce them for real — is
`references/chaos/blast-radius.md`.

The resolved object is persisted at `state.setup.blastRadius`. It records what
was *predicted*, not what the configuration was filtered to.

## Permission blockers and the consent protocol (exit 4)

Validation always runs. When it reports blockers the script:

1. **normalizes** them to `{ code, category, resourceId, roleName, principalId, message }`
   and persists them at `state.setup.configuration.validation.blockers`;
2. **offers the targeted grants first** — the exact, minimum-scope
   `az role assignment create` commands that would clear the permission
   blockers, persisted at `state.setup.configuration.validation.targetedGrants`;
3. **stops and exits 4** rather than running the broad fix.

`chaos_fix_resource_permissions` / `az chaos scenario config fix-permissions`
remains available, but it is a **broad** mutation: it grants whatever roles the
service decides are required to the workspace identity, on every target resource
in the configuration's scope, in a single call. It is not limited to the
reported blockers and the grants cannot be enumerated in advance.

On exit 4:

1. Render the consent prompt from the script output (also at
   `state.setup.configuration.validation.permissionFix.consentPrompt`) — it
   describes exactly this breadth.
2. Show the targeted grants and let the user run those instead if they prefer.
3. Only if the user explicitly consents, re-run with
   `-ConsentToBroadPermissionFix` (or set
   `$env:STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX = '1'`).

Any value other than the exact string `1` is **not** consent. Never set that
variable on the user's behalf, and never call `chaos_fix_resource_permissions`
over MCP without having shown the same breadth description and received an
explicit answer.

## Script Parameters

| Parameter | Description |
|-----------|-------------|
| `-ScenarioName` | Selected scenario (e.g. `ZoneDown-1.0`). Bypasses the selection prompt. Equivalent to `$env:STARTCHAOS_SCENARIO`. |
| `-ParameterMode` | `autofill` (always use this — `manual` does not work in AI sessions). |
| `-ParameterValues` | Hashtable of parameter overrides applied on top of defaults, e.g. `@{ duration = 'PT5M' }`. |
| `-ResourceTargeting` | Hashtable of `include`/`exclude` ARM id arrays, e.g. `@{ exclude = @('<armId>') }`. `exclude` wins over `include`. **Advisory only** — it shapes the predicted blast radius and the starvation refusal; it is not transmitted to the service and does not stop a resource from being targeted. |
| `-ConsentToBroadPermissionFix` | Explicit consent to run the broad `fix-permissions` mutation. Only pass after the user has answered the exit-4 consent prompt. |

## What the Script Handles (no AI logic needed)

- Workspace evaluation via `az chaos workspace refresh-recommendation` (CLI awaits the LRO) + `show-evaluation` summary
- Scenario list (`az chaos scenario list`) filtered to `recommendation.recommendationStatus == "Recommended"`
- Auto-select when exactly one scenario is recommended; pause-and-emit-exit-2 otherwise
- ScenarioConfiguration create (`az chaos scenario config create`, `--scenario-id` auto-derived) with parameter merge (defaults + overrides)
- Validate (`az chaos scenario config validate`) → normalize blockers → offer targeted `az role assignment create` grants → `az chaos scenario config fix-permissions` **only with explicit consent** → re-validate
- Blast-radius **prediction** and rendering before configuration creation (`resourceTargeting` include/exclude, exclude wins; advisory — not transmitted to the service)
- RBAC propagation retry loop (up to 5 minutes, 20s interval) gated to permission-related errors only
- Atomic state writes with error envelopes
- Idempotent re-runs

## Related Skills

- `create-workspace` — must complete before this skill
- `run-scenario` — next phase after setup
