# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""MCP server exposing Azure Chaos Studio v2 operations as agent-callable tools.

Mirrors the Copilot CLI plugin's PowerShell skills (create-workspace,
setup-scenario, run-scenario) against the same `Microsoft.Chaos`
2026-05-01-preview surface, plus the Azure Monitor tools from
`chaos_mcp.monitor`. Auth comes from the local `az` session (see
`chaos_mcp.azure`); the server itself is stateless.

Every tool returns the structured envelope described in `chaos_mcp.monitor`
so agents can branch on `ok`/`errorType` instead of parsing tracebacks.

The `chaos_evidence_*` tools front the durable evidence store in
`chaos_mcp.evidence`; they are the only cross-session read path and are
confined to `$CHAOS_EVIDENCE_ROOT`.
"""
from __future__ import annotations

import re
import uuid
from typing import Any

from mcp.server.fastmcp import FastMCP

from . import azure as az
from . import evidence as ev
from . import monitor as mon
from .apiversions import ROLE_ASSIGNMENT_API_VERSION

mcp = FastMCP("chaos-studio")

READER_ROLE_DEFINITION_ID = "acdd72a7-3385-48ef-bd42-f606fba81ae7"


def _ws_path(subscription_id: str, resource_group: str, workspace_name: str) -> str:
    return (
        f"/subscriptions/{subscription_id}/resourceGroups/{resource_group}"
        f"/providers/Microsoft.Chaos/workspaces/{workspace_name}"
    )


def _config_path(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
    scenario_name: str,
    configuration_name: str,
) -> str:
    base = _ws_path(subscription_id, resource_group, workspace_name)
    return f"{base}/scenarios/{scenario_name}/configurations/{configuration_name}"


def _ok(result: Any) -> dict[str, Any]:
    return {"ok": True, "result": result}


def _err(e: az.AzureError) -> dict[str, Any]:
    return {"ok": False, "errorType": "AzureError", "error": str(e)}


def _grant_reader(scope: str, principal_id: str) -> dict[str, Any]:
    """Grant the Reader role to a principal on a scope; idempotent."""
    name = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{scope}|{principal_id}|reader"))
    path = f"{scope}/providers/Microsoft.Authorization/roleAssignments/{name}"
    body = {
        "properties": {
            "roleDefinitionId": (
                f"{scope.split('/resourceGroups/')[0]}/providers"
                f"/Microsoft.Authorization/roleDefinitions/{READER_ROLE_DEFINITION_ID}"
            ),
            "principalId": principal_id,
            "principalType": "ServicePrincipal",
        }
    }
    try:
        az.arm_put(path, body, api_version=ROLE_ASSIGNMENT_API_VERSION)
        return {"scope": scope, "status": "granted"}
    except az.AzureError as e:
        # An existing assignment surfaces as 409 RoleAssignmentExists.
        if "RoleAssignmentExists" in str(e) or '"409"' in str(e) or " 409 " in str(e):
            return {"scope": scope, "status": "already-granted"}
        return {"scope": scope, "status": "failed", "error": str(e)}


#: Blocker codes/messages a role assignment could plausibly fix. Mirrors
#: `$script:PermissionBlockerPattern` in scripts/Validate-AndFix.ps1.
_PERMISSION_BLOCKER = re.compile(
    r"permission|authoriz|forbidden|denied|rbac|roleassignment|role assignment",
    re.IGNORECASE,
)

#: Blocker codes/messages describing the target resource itself, not access to
#: it. Mirrors `$script:ResourceBlockerPattern` in scripts/Validate-AndFix.ps1.
_RESOURCE_BLOCKER = re.compile(
    r"resource|target|notfound|not found|unsupported|agent|extension|sku|zone"
    r"|capacity|state",
    re.IGNORECASE,
)

#: Emitted in a targeted grant command when the workspace identity is unknown,
#: so the command is never silently unassignable.
PRINCIPAL_PLACEHOLDER = "<workspace-identity-principal-id>"


def _first(source: dict[str, Any], *keys: str) -> Any:
    """First present, truthy value among `keys`."""
    for key in keys:
        value = source.get(key)
        if value:
            return value
    return None


def normalize_validation_blockers(validation: Any) -> list[dict[str, Any]]:
    """Normalize a `validations/latest` payload into one blocker shape (E3-T2).

    The service reports blockers from several places (`properties.errors`,
    `properties.validationErrors`, `properties.resources[].errors`) using
    several field spellings. Everything downstream reads
    `{code, category, resourceId, roleName, principalId, message}` instead,
    where `category` is one of `permission`, `resource` or `other`. Identical
    blockers reported twice collapse to one.

    Error entries that are not objects (a bare string in `errors[]`) are
    skipped: they carry no code, message or resource id. `Test-StructuredValidationError`
    in scripts/Validate-AndFix.ps1 applies the same rule so both planes produce
    the same blocker count for the same payload.

    See `references/chaos/blast-radius.md` §5.
    """
    if not isinstance(validation, dict):
        return []
    props = validation.get("properties")
    if not isinstance(props, dict):
        return []

    raw: list[tuple[dict[str, Any], str | None]] = []
    for field in ("errors", "validationErrors"):
        for item in props.get(field) or []:
            if isinstance(item, dict):
                raw.append((item, None))
    for resource in props.get("resources") or []:
        if not isinstance(resource, dict):
            continue
        parent = _first(resource, "resourceId", "id")
        for field in ("errors", "validationErrors"):
            for item in resource.get(field) or []:
                if isinstance(item, dict):
                    raw.append((item, parent))

    blockers: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for error, parent in raw:
        code = _first(error, "errorCode", "code") or "Unknown"
        message = _first(error, "errorMessage", "message") or ""
        resource_id = (
            _first(error, "resourceId", "targetResourceId", "target", "id") or parent
        )
        role_name = _first(error, "roleName", "requiredRole", "roleDefinitionName")

        probe = f"{code} {message}"
        if _PERMISSION_BLOCKER.search(probe):
            category = "permission"
        elif _RESOURCE_BLOCKER.search(probe):
            category = "resource"
        else:
            category = "other"

        # Deliberately message-free: one code on one resource for one role is a
        # single actionable blocker however it was worded. Mirrors the dedupe
        # key in ConvertTo-ValidationBlocker (scripts/Validate-AndFix.ps1).
        key = (str(code).lower(), str(resource_id or "").lower(), str(role_name or "").lower())
        if key in seen:
            continue
        seen.add(key)

        blockers.append(
            {
                "code": str(code),
                "category": category,
                "resourceId": str(resource_id) if resource_id else None,
                "roleName": str(role_name) if role_name else None,
                "principalId": str(error["principalId"]) if error.get("principalId") else None,
                "message": str(message),
            }
        )
    return blockers


def build_targeted_grant_proposal(
    blockers: list[dict[str, Any]],
    principal_id: str | None = None,
    default_role_name: str = "Reader",
) -> list[dict[str, Any]]:
    """Exact, minimum-scope grants that would clear the permission blockers.

    Always offered *before* `chaos_fix_resource_permissions`, which is a
    broad-breadth mutation. Blockers no role assignment can fix, and blockers
    with no resource id (the scope would be a guess), are skipped. Duplicate
    (resource, role) pairs collapse.

    Mirrors `Build-TargetedGrantProposal` in scripts/Rbac.ps1.
    """
    principal = principal_id or PRINCIPAL_PLACEHOLDER
    proposal: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for blocker in blockers:
        if blocker.get("category") != "permission":
            continue
        resource_id = blocker.get("resourceId")
        if not resource_id:
            continue
        role_name = blocker.get("roleName") or default_role_name
        key = (resource_id.lower(), role_name.lower())
        if key in seen:
            continue
        seen.add(key)
        proposal.append(
            {
                "resourceId": resource_id,
                "roleName": role_name,
                "blockerCode": blocker.get("code"),
                "command": (
                    f'az role assignment create --assignee-object-id "{principal}" '
                    f'--assignee-principal-type ServicePrincipal '
                    f'--role "{role_name}" --scope "{resource_id}"'
                ),
                "description": (
                    f"Grant '{role_name}' to principal {principal} on scope {resource_id}"
                ),
            }
        )
    return proposal


# ---------------------------------------------------------------------------
# Workspace lifecycle
# ---------------------------------------------------------------------------


@mcp.tool()
def chaos_set_auth_mode(
    mode: str,
    msi_client_id: str | None = None,
) -> dict[str, Any]:
    """Choose how the Chaos Studio tools authenticate to Azure, for the rest of
    this session.

    Call this when the customer wants the tools to act as an Azure **Managed
    Identity** instead of their signed-in **user principal** (the default), or
    to switch back. The choice is applied immediately to every subsequent tool
    call and persists for the life of this MCP session — no config edit or
    server restart needed.

    Args:
        mode: 'cli' to use the local `az login` session (the user principal), or
            'managed-identity' to use an Azure Managed Identity (aliases 'msi',
            'mi' are accepted).
        msi_client_id: Optional client id of a user-assigned managed identity to
            use when mode is 'managed-identity'. Omit to keep any identity pinned
            by CHAOS_MCP_MSI_CLIENT_ID, or to fall back to the system-assigned
            identity when none is pinned. Ignored in 'cli' mode.

    Returns the effective auth configuration ({mode, msiClientId, source}).
    """
    try:
        return _ok(az.set_auth_mode(mode, msi_client_id))
    except az.AzureError as e:
        return _err(e)


@mcp.tool()
def chaos_get_auth_mode() -> dict[str, Any]:
    """Report how the Chaos Studio tools are currently authenticating.

    Returns {mode, msiClientId, source} where `source` is 'override' (set this
    session via chaos_set_auth_mode), 'env' (from CHAOS_MCP_AUTH_MODE), or
    'default' (the built-in `cli` / user-principal default)."""
    return _ok(az.get_auth_config())


@mcp.tool()
def chaos_create_workspace(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
    location: str,
    scopes: list[str],
    identity_type: str = "SystemAssigned",
    user_assigned_identity_resource_id: str | None = None,
) -> dict[str, Any]:
    """Provision a Chaos Studio Workspace with a managed identity and grant
    the identity Reader on each target scope. Blocks until provisioning
    reaches a terminal state."""
    identity: dict[str, Any] = {"type": identity_type}
    if user_assigned_identity_resource_id:
        identity["userAssignedIdentities"] = {user_assigned_identity_resource_id: {}}
    body = {
        "location": location,
        "identity": identity,
        "properties": {"scopes": list(scopes)},
    }
    path = _ws_path(subscription_id, resource_group, workspace_name)
    try:
        resp = az.arm_put(path, body)
        az.wait_for_lro(resp)
        workspace = az.arm_get(path)
    except az.AzureError as e:
        return _err(e)

    principal_id = (workspace.get("identity") or {}).get("principalId")
    rbac = (
        [_grant_reader(scope, principal_id) for scope in scopes]
        if principal_id
        else []
    )
    return _ok({"workspace": workspace, "roleAssignments": rbac})


@mcp.tool()
def chaos_get_workspace(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
) -> dict[str, Any]:
    """Fetch a Chaos Studio Workspace resource."""
    try:
        return _ok(az.arm_get(_ws_path(subscription_id, resource_group, workspace_name)))
    except az.AzureError as e:
        return _err(e)


@mcp.tool()
def chaos_refresh_recommendations(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
) -> dict[str, Any]:
    """Trigger a workspace evaluation (resource discovery + Scenario
    recommendation refresh) and block until the latest evaluation is
    terminal."""
    base = _ws_path(subscription_id, resource_group, workspace_name)
    try:
        resp = az.arm_post(f"{base}/refreshRecommendations")
        az.wait_for_lro(resp)
        evaluation = az.arm_get(f"{base}/evaluations/latest")
    except az.AzureError as e:
        return _err(e)
    return _ok(evaluation)


@mcp.tool()
def chaos_list_recommended_scenarios(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
) -> dict[str, Any]:
    """List the Scenarios recommended for the Workspace's discovered
    resources."""
    base = _ws_path(subscription_id, resource_group, workspace_name)
    try:
        body = az.arm_get(f"{base}/scenarios")
    except az.AzureError as e:
        return _err(e)
    return _ok(body.get("value", []))


# ---------------------------------------------------------------------------
# Scenario configuration
# ---------------------------------------------------------------------------


@mcp.tool()
def chaos_create_scenario_configuration(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
    scenario_name: str,
    configuration_name: str,
    configuration: dict[str, Any],
) -> dict[str, Any]:
    """Create or update a Scenario configuration (the `configuration` body is
    the full resource payload). Blocks on the provisioning LRO and returns
    the final resource."""
    path = _config_path(
        subscription_id, resource_group, workspace_name, scenario_name, configuration_name
    )
    try:
        resp = az.arm_put(path, configuration)
        az.wait_for_lro(resp)
        return _ok(az.arm_get(path))
    except az.AzureError as e:
        return _err(e)


@mcp.tool()
def chaos_validate_scenario_configuration(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
    scenario_name: str,
    configuration_name: str,
) -> dict[str, Any]:
    """Validate a Scenario configuration and return the latest validation
    result (including any per-resource validation errors).

    The returned payload is the raw `validations/latest` resource, additively
    enriched with `normalizedBlockers` (one shape for the several the service
    uses) and `targetedGrantProposal` (the exact, minimum-scope
    `az role assignment create` commands that would clear the permission
    blockers). Offer those grants before ever considering
    `chaos_fix_resource_permissions`. Their `--assignee-object-id` carries the
    `<workspace-identity-principal-id>` placeholder — substitute the workspace
    identity's object ID before running them. See
    `references/chaos/blast-radius.md`.
    """
    path = _config_path(
        subscription_id, resource_group, workspace_name, scenario_name, configuration_name
    )
    try:
        resp = az.arm_post(f"{path}/validate")
        az.wait_for_lro(resp)
        latest = az.arm_get(f"{path}/validations/latest")
        if isinstance(latest, dict):
            blockers = normalize_validation_blockers(latest)
            # Additive only: never overwrite a field the service itself sent.
            latest.setdefault("normalizedBlockers", blockers)
            latest.setdefault(
                "targetedGrantProposal", build_targeted_grant_proposal(blockers)
            )
        return _ok(latest)
    except az.AzureError as e:
        return _err(e)


@mcp.tool()
def chaos_fix_resource_permissions(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
    scenario_name: str,
    configuration_name: str,
    what_if: bool = False,
) -> dict[str, Any]:
    """Auto-grant the roles a Scenario configuration needs on its target
    resources. Set `what_if=True` to preview without granting.

    BROAD MUTATION — REQUIRES EXPLICIT CONSENT. This grants whatever roles the
    service decides are required to the workspace identity, on **every** target
    resource in this configuration's scope, in a single call. It is not limited
    to the reported blockers and the grants cannot be enumerated in advance.

    Before calling this with `what_if=False`: run
    `chaos_validate_scenario_configuration`, show the caller the
    `targetedGrantProposal` it returns (minimum-scope, per-resource
    `az role assignment create` commands), describe the breadth above, and
    obtain an explicit answer. See `references/chaos/blast-radius.md` §6.
    """
    path = _config_path(
        subscription_id, resource_group, workspace_name, scenario_name, configuration_name
    )
    try:
        resp = az.arm_post(f"{path}/fixResourcePermissions", {"whatIf": what_if})
        az.wait_for_lro(resp)
        return _ok(az.arm_get(f"{path}/fixResourcePermissions/latest"))
    except az.AzureError as e:
        return _err(e)


# ---------------------------------------------------------------------------
# Scenario runs
# ---------------------------------------------------------------------------


@mcp.tool()
def chaos_execute_scenario(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
    scenario_name: str,
    configuration_name: str,
) -> dict[str, Any]:
    """Start a Scenario run from a configuration and return its
    `scenarioRunId`. Does not wait for the run to finish — poll with
    `chaos_get_scenario_run`."""
    base = _ws_path(subscription_id, resource_group, workspace_name)
    config = _config_path(
        subscription_id, resource_group, workspace_name, scenario_name, configuration_name
    )
    try:
        resp = az.arm_post(f"{config}/execute")
    except az.AzureError as e:
        return _err(e)

    run_id: str | None = None
    location = resp.headers.get("Location") or resp.headers.get("location")
    if location:
        match = re.search(r"/runs/([^?/]+)", location)
        if match:
            run_id = match.group(1)
    if not run_id:
        # Fallback mirrors the run-scenario skill: newest run for this config.
        try:
            runs = az.arm_get(f"{base}/scenarios/{scenario_name}/runs").get("value", [])
        except az.AzureError as e:
            return _err(e)
        runs = [
            r
            for r in runs
            if r.get("properties", {}).get("scenarioConfigurationName")
            == configuration_name
        ]
        runs.sort(key=lambda r: r.get("properties", {}).get("startTime") or "", reverse=True)
        if not runs:
            return {
                "ok": False,
                "errorType": "AzureError",
                "error": "Could not resolve ScenarioRun ID after execution.",
            }
        run_id = runs[0].get("name")
    return _ok({"scenarioRunId": run_id})


@mcp.tool()
def chaos_get_scenario_run(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
    scenario_name: str,
    scenario_run_id: str,
) -> dict[str, Any]:
    """Fetch a single status snapshot of a Scenario run."""
    base = _ws_path(subscription_id, resource_group, workspace_name)
    try:
        return _ok(az.arm_get(f"{base}/scenarios/{scenario_name}/runs/{scenario_run_id}"))
    except az.AzureError as e:
        return _err(e)


@mcp.tool()
def chaos_cancel_scenario_run(
    subscription_id: str,
    resource_group: str,
    workspace_name: str,
    scenario_name: str,
    scenario_run_id: str,
) -> dict[str, Any]:
    """Request cancellation of a running Scenario run (best-effort — actions
    already in flight may complete)."""
    base = _ws_path(subscription_id, resource_group, workspace_name)
    try:
        az.arm_post(f"{base}/scenarios/{scenario_name}/runs/{scenario_run_id}/cancel")
    except az.AzureError as e:
        return _err(e)
    return _ok({"scenarioRunId": scenario_run_id, "status": "cancelRequested"})


# ---------------------------------------------------------------------------
# Azure Monitor
# ---------------------------------------------------------------------------


@mcp.tool()
def monitor_query_metrics(
    resource_id: str,
    metric_names: list[str],
    start_time: str,
    end_time: str,
    aggregation: str = "Average",
    interval: str = "PT1M",
) -> dict[str, Any]:
    """Query Azure Monitor metrics for a resource over a time window
    (ISO 8601 UTC timestamps)."""
    return mon.monitor_query_metrics(
        resource_id, metric_names, start_time, end_time, aggregation, interval
    )


@mcp.tool()
def monitor_query_logs(
    workspace_id: str,
    kql: str,
    timespan: str | None = None,
) -> dict[str, Any]:
    """Run a KQL query against a Log Analytics workspace (by workspace
    GUID)."""
    return mon.monitor_query_logs(workspace_id, kql, timespan)


@mcp.tool()
def monitor_search_activity_log(
    subscription_id: str,
    start_time: str,
    end_time: str,
    resource_uri: str | None = None,
) -> dict[str, Any]:
    """Search the Azure Activity Log for management events in a time window,
    optionally scoped to one resource."""
    return mon.monitor_search_activity_log(
        subscription_id, start_time, end_time, resource_uri
    )


# ---------------------------------------------------------------------------
# Durable evidence (E2-T3)
#
# Thin wrappers over `chaos_mcp.evidence`. They exist only so evidence written
# by one session is reachable from another; the PowerShell skills remain the
# writers of record. Path canonicalization, the `$CHAOS_KEY_DIR` denylist and
# redaction all live in the module, not here.
# ---------------------------------------------------------------------------


@mcp.tool()
def chaos_evidence_put(
    scope_hash: str,
    run_id: str | None = None,
    name: str = "",
    data: dict[str, Any] | None = None,
    kind: str = "artifacts",
    expected_revision: int | None = None,
    artifact_type: str | None = None,
) -> dict[str, Any]:
    """Write one evidence item to the durable store atomically, bumping its
    revision. Omit run_id for artifacts keyed by scope that must outlive a run.
    artifact_type is an alias for name — the same string evidence_list filters
    on. Pass expected_revision (0 = must not exist) to guard against a lost
    update. Secret-bearing keys and secret-shaped values are redacted before
    the bytes reach disk; the paths redacted are reported in `redactions`."""
    return ev.evidence_put(
        scope_hash,
        run_id,
        name,
        data,
        kind,
        expected_revision=expected_revision,
        artifact_type=artifact_type,
    )


@mcp.tool()
def chaos_evidence_get(
    scope_hash: str,
    run_id: str | None = None,
    name: str = "",
    kind: str = "artifacts",
    artifact_type: str | None = None,
) -> dict[str, Any]:
    """Read one evidence item from the durable store, for cross-session
    recovery of a previous run. Omit run_id for scope-keyed artifacts.
    artifact_type is an alias for name. The payload is returned as `artifact`
    (`data` is a deprecated alias for the same object). Results are redacted
    and confined to $CHAOS_EVIDENCE_ROOT."""
    return ev.evidence_get(scope_hash, run_id, name, kind, artifact_type=artifact_type)


@mcp.tool()
def chaos_evidence_list(
    scope_hash: str | None = None,
    run_id: str | None = None,
    artifact_type: str | None = None,
    max_items: int | None = None,
    continuation_token: str | None = None,
) -> dict[str, Any]:
    """List evidence scopes, the runs of a scope, or the items of a run.
    Returns metadata only, never item contents. artifact_type filters on the
    item's exact name as passed to chaos_evidence_put. Item listings are paged;
    pass back `continuationToken` to fetch the next page."""
    return ev.evidence_list(scope_hash, run_id, artifact_type, max_items, continuation_token)


def main() -> None:
    """Console entry point (`chaos-mcp`): serve MCP over stdio."""
    mcp.run()


if __name__ == "__main__":
    main()
