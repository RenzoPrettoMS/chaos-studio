# Blast radius contract

Shared, field-derived rules for **what a scenario will actually touch** and for
**how far a permission remediation reaches**. Two things live here:

1. the `resourceTargeting` include/exclude precedence used to resolve a
   candidate resource set into an affected resource set, and
2. the breadth classification of the permission remediations offered when
   validation reports blockers.

`scripts/Render.ps1` (`Resolve-BlastRadius`, `Write-BlastRadiusCard`) implements
§1–§4; `scripts/Validate-AndFix.ps1` and `scripts/Rbac.ps1`
are the enforcement for §5–§6. This document is the rationale, and it is the
contract that `compute_blast_radius()` and `fault-semantics.md` read later.

## 1. Vocabulary

| Term | Meaning |
|---|---|
| Candidate | A resource discovered in scope, before any filtering |
| Include | `resourceTargeting.include` — an allow-list of ARM ids |
| Exclude | `resourceTargeting.exclude` — a deny-list of ARM ids |
| Affected | What remains after include and exclude are applied |
| Leg | One fault branch of a scenario; a leg with no affected resource is *starved* |

## 2. Precedence

> **`resourceTargeting` is advisory. It is never transmitted to the service.**
> `az chaos scenario config create` accepts no include/exclude argument, so the
> ScenarioConfiguration Azure Chaos Studio creates covers the **full**
> recommendation set no matter what was excluded here. Everything in §1–§4 is a
> *prediction* of what the service is expected to target, used to make the
> affected set reviewable before the first mutation (F8) and to refuse a run
> that would exercise nothing (§4). To actually spare a resource you must
> change what the service sees: remove it from the workspace scope, or disable
> its Chaos target. `Write-BlastRadiusCard` states this on every rendering, and
> `SKILL.md` for both `setup-scenario` and `run-scenario` repeats it — a card
> that implies an exclusion was applied when it was not is strictly worse than
> rendering nothing.

Resolution is deterministic and evaluated per candidate:

1. An **empty or absent include list means every candidate is in scope.** An
   include list is a narrowing filter, never a requirement.
2. A **non-empty include list narrows** the candidate set to its members.
   Candidates outside it are reported as `notIncluded` — they were dropped, but
   not by an exclusion, and the distinction matters when explaining an empty
   result.
3. **Exclude is applied last and always wins over include.** A resource named
   in both lists is excluded. There is no "explicit include beats exclude"
   escape hatch: the deny-list is the safety mechanism, so it cannot be
   overridden by the widening one.
4. ARM ids compare **case-insensitively**, ignoring surrounding whitespace and
   a trailing slash. ARM itself treats ids this way, so a case difference must
   never quietly widen the blast radius.
5. Candidate **order is preserved** and duplicates collapse, so the rendered
   card is stable across runs.

## 3. Filters that matched nothing

`unmatchedInclude` and `unmatchedExclude` list every filter entry that matched
no candidate. They are always rendered. A mistyped exclusion is otherwise
indistinguishable from no exclusion at all, and it silently widens the blast
radius — the exact failure this section exists to prevent.

## 4. Leg starvation (CS-7)

`isStarved` is true when there **were** candidates and the affected set is
empty. `starvedByExclusion` additionally distinguishes the two causes:

| Cause | `isStarved` | `starvedByExclusion` |
|---|---|---|
| Every candidate removed by exclude | true | true |
| Include matched no candidate | true | false |
| Nothing was discovered at all | false | false |

The third row is deliberate. An empty candidate set is an upstream **scope**
problem (the workspace scope contains no applicable resource); reporting it as
starvation would send the user to fix targeting they never wrote. It is still
not rendered as a green status — `Write-BlastRadiusCard` shows
`ℹ️ Nothing discovered in scope`, because "this will touch nothing" is the same
silent no-op class of failure whatever caused it.

CS-7 records that exclusion-based starvation is undiscoverable from the service:
a starved scenario starts, reports success, and exercises nothing. The setup
skill therefore renders the resolved blast radius **before** it creates the
ScenarioConfiguration (F8), and refuses to create one when caller-supplied
targeting starved the set.

### Exclusion recipes

> **These recipes shape the prediction, not the run.** Because the exclusion is
> not transmitted (§2), listing a resource here does **not** stop the service
> from targeting it. Use a recipe to state the intent and to see the resolved
> set before anything is created; then enforce the intent for real by removing
> the resource from the workspace scope or disabling its Chaos target. Never
> tell a user their primary is spared on the strength of an exclusion alone.

Exclusions are expressed as ARM resource ids of the resources to spare. Common
shapes:

| Goal | `resourceTargeting.exclude` | Enforce it by |
|---|---|---|
| Spare the primary of a pair | the primary's ARM id | narrowing the workspace scope to the secondary |
| Spare one VM in a scale set-backed leg | that VM instance's ARM id | disabling that instance's Chaos target |
| Spare a shared dependency (e.g. the logging account) | that account's ARM id | removing it from the workspace scope |
| Keep a control resource for comparison | the control resource's ARM id | keeping it outside the workspace scope |

Per-fault recipes — which exclusion is meaningful for which fault, and which
faults have no safe exclusion because they operate on a whole resource — belong
in `fault-semantics.md`, which reads this contract for its precedence rules.

## 5. Validation is configuration-scoped (CS-6)

`config validate` answers one question: *can this configuration run against its
targets right now?* It does not answer whether a scenario is a good idea, and
it says nothing about resources outside the configuration.

CS-6 records that `config validate` was unreachable from the agent write
allow-list during the field engagement, which forced `--skip-validation` and
forfeited the permission-blocker data entirely. The blockers are the only
authoritative statement of what is missing, so the validation call must always
be reachable. `chaos_validate_scenario_configuration` is allow-listed in the run
phase for exactly this reason (design decision D12).

### Normalized blockers

The service reports blockers from several places (`properties.errors`,
`properties.validationErrors`, `properties.resources[].errors`) with several
field spellings (`errorCode`/`code`, `errorMessage`/`message`,
`resourceId`/`targetResourceId`/`target`/`id`). Everything downstream reads one
normalized shape instead:

```
{ code, category, resourceId, roleName, principalId, message }
```

`category` is one of:

| Category | Meaning | Fixable by a role assignment |
|---|---|---|
| `permission` | The workspace identity lacks access | yes |
| `resource` | The target resource itself is unsuitable (no agent, wrong state, unsupported SKU) | no |
| `other` | Anything else | no |

Entries in `errors[]` that are not objects (a bare string) carry no code,
message or resource id and are skipped on both planes — `ConvertTo-ValidationBlocker`
(`Test-StructuredValidationError`) and `normalize_validation_blockers` — so the
PowerShell and MCP planes always report the same blocker count for one payload.
Blockers de-duplicate on `(code, resourceId, roleName)`: one code on one
resource for one role is a single actionable blocker however it was worded.

## 6. Remediation breadth

Two remediations exist, and they are always offered in this order.

| | Targeted grant | `fixResourcePermissions` |
|---|---|---|
| Scope | One resource, one role, per blocker | Every target resource in the configuration |
| Built from | Normalized blockers + `Rbac.ps1` | The service's own decision |
| Enumerable in advance | Yes — the exact `az role assignment create` commands are printed | No |
| Runs automatically | Never; the commands are printed for the operator | Only with explicit consent |

The printed grant commands are complete except for `--assignee-object-id`, which
carries the literal `<workspace-identity-principal-id>` placeholder whenever the
caller did not supply the workspace identity. `Invoke-SetupScenario.ps1` and
`Invoke-RunScenario.ps1` both pass `-PrincipalId $state.workspace.identity.principalId`,
so on the PowerShell plane the commands are runnable as printed. The MCP tool
`chaos_validate_scenario_configuration` has no workspace identity in hand, so
its `targetedGrantProposal` always carries the placeholder and **the caller must
substitute the workspace identity's object ID before running the command**
(`az chaos workspace show ... --query identity.principalId -o tsv`).

**Targeted-first is mandatory.** The exact per-resource grants are rendered and
persisted (`<base>.validation.targetedGrants`) before the broad fix is even
offered, because they are minimum-scope and reviewable.

**The broad fix never runs without explicit consent.** `Invoke-ValidateAndFix`
persists the consent prompt, renders it, and throws
`broadPermissionFixConsentRequired: ...` unless consent was given by
`-ConsentToBroadPermissionFix` or by `STARTCHAOS_CONSENT_BROAD_PERMISSION_FIX=1`.
Any value other than the exact string `1` is **not** consent — a broad mutation
must never turn on because an environment variable happened to be set. Agents
calling the MCP tool `chaos_fix_resource_permissions` directly are under the
same obligation: the consent prompt describing this breadth must be shown and
answered first.

## 7. State keys

| Key | Written by | Contents |
|---|---|---|
| `setup.blastRadius` | `Invoke-SetupScenario.ps1` | The resolved `Resolve-BlastRadius` object — a prediction (§2), not what the configuration was filtered to |
| `<base>.validation.blockers` | `Invoke-ValidateAndFix` | Normalized blockers (§5) |
| `<base>.validation.targetedGrants` | `Invoke-ValidateAndFix` | Targeted grant proposal (§6) |
| `<base>.validation.permissionFix.consent` | `Invoke-ValidateAndFix` | `required` or `granted` |
| `<base>.validation.permissionFix.consentPrompt` | `Invoke-ValidateAndFix` | The exact breadth description shown |

All five are additive; nothing in the frozen v1 state shape moved.
