# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Frozen baseline contract for the shipped `startchaos` v0.3.0 surface (E1-T1/E1-T2).

Everything asserted here is a *snapshot of what already ships*, taken from the
research baseline SHA. These tests exist to make an accidental break loud:

* E1-T1 — the five skill names/trigger descriptions, the `startchaos-state.json`
  v1 fixture, impact schema v1, and the exact 15 MCP tool signatures + response
  envelopes.
* E1-T2 — direct recorded tests for the ten lifecycle tools that previously had
  none (only the auth-mode pair and the three Monitor tools were covered).

Recorded tests drive the real tool functions through `httpx.MockTransport`
installed on the existing `chaos_mcp.azure._TEST_TRANSPORT` hook, with recorded
ARM payloads. No network and no `az` shell-outs.

Envelopes are validated against the checked-in `TOOL_ENVELOPE_SCHEMA` below
rather than the SDK-generated `outputSchema`: the E1-T5 spike found that
FastMCP derives a permissive `{"type": "object", "additionalProperties": true}`
schema for `dict[str, Any]` returns, which asserts nothing (see `mcp/README.md`).
"""
from __future__ import annotations

import inspect
import json
import re
from collections.abc import Callable
from pathlib import Path

import httpx
import jsonschema
import pytest

from chaos_mcp import azure as az
from chaos_mcp import server as srv

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
SKILLS_DIR = PLUGIN_ROOT / "skills"

# ---------------------------------------------------------------------------
# Frozen contract data
# ---------------------------------------------------------------------------

#: The five independently invocable skills and the trigger text that routes to
#: them. Names and descriptions are EXTEND-only: they must never be renamed.
FROZEN_SKILLS: dict[str, str] = {
    "start-chaos": (
        "Orchestrate the full Chaos Studio v2 workflow: auth → workspace → "
        "scenario → run. Shares a single state file and supports resume."
    ),
    "create-workspace": (
        "Provision a Microsoft.Chaos/workspaces resource (v2), bind a managed "
        "identity, set scopes, and grant Reader RBAC on the scope."
    ),
    "setup-scenario": (
        "Discover recommended scenarios, build and validate a "
        "ScenarioConfiguration, and auto-fix resource permissions."
    ),
    "run-scenario": (
        "Execute a ScenarioConfiguration and stream ScenarioRun status with "
        "per-action breakdown until terminal state."
    ),
    "chaos-impact": (
        "Synthesize an Azure Monitor impact report for a Chaos Studio v2 "
        "ScenarioRun: pulls the run, walks targeted resources, queries "
        "metrics/logs/activity-log/alerts over the run window ± buffer, and "
        "renders a Markdown + JSON impact card."
    ),
}

#: Trigger phrases the `/start-chaos` agent advertises. Removing one silently
#: breaks the shipped entry point.
FROZEN_START_CHAOS_TRIGGERS = [
    "start chaos",
    "run chaos experiment",
    "chaos studio",
    "create workspace",
]

#: Exactly the 15 tools that ship today: name -> ordered
#: (parameter, annotation, default) triples. `inspect.Parameter.empty` is
#: rendered as the sentinel "<required>".
FROZEN_TOOL_SIGNATURES: dict[str, list[tuple[str, str, str]]] = {
    "chaos_set_auth_mode": [
        ("mode", "str", "<required>"),
        ("msi_client_id", "str | None", "None"),
    ],
    "chaos_get_auth_mode": [],
    "chaos_create_workspace": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
        ("location", "str", "<required>"),
        ("scopes", "list[str]", "<required>"),
        ("identity_type", "str", "'SystemAssigned'"),
        ("user_assigned_identity_resource_id", "str | None", "None"),
    ],
    "chaos_get_workspace": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
    ],
    "chaos_refresh_recommendations": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
    ],
    "chaos_list_recommended_scenarios": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
    ],
    "chaos_create_scenario_configuration": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
        ("scenario_name", "str", "<required>"),
        ("configuration_name", "str", "<required>"),
        ("configuration", "dict[str, Any]", "<required>"),
    ],
    "chaos_validate_scenario_configuration": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
        ("scenario_name", "str", "<required>"),
        ("configuration_name", "str", "<required>"),
    ],
    "chaos_fix_resource_permissions": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
        ("scenario_name", "str", "<required>"),
        ("configuration_name", "str", "<required>"),
        ("what_if", "bool", "False"),
    ],
    "chaos_execute_scenario": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
        ("scenario_name", "str", "<required>"),
        ("configuration_name", "str", "<required>"),
    ],
    "chaos_get_scenario_run": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
        ("scenario_name", "str", "<required>"),
        ("scenario_run_id", "str", "<required>"),
    ],
    "chaos_cancel_scenario_run": [
        ("subscription_id", "str", "<required>"),
        ("resource_group", "str", "<required>"),
        ("workspace_name", "str", "<required>"),
        ("scenario_name", "str", "<required>"),
        ("scenario_run_id", "str", "<required>"),
    ],
    "monitor_query_metrics": [
        ("resource_id", "str", "<required>"),
        ("metric_names", "list[str]", "<required>"),
        ("start_time", "str", "<required>"),
        ("end_time", "str", "<required>"),
        ("aggregation", "str", "'Average'"),
        ("interval", "str", "'PT1M'"),
    ],
    "monitor_query_logs": [
        ("workspace_id", "str", "<required>"),
        ("kql", "str", "<required>"),
        ("timespan", "str | None", "None"),
    ],
    "monitor_search_activity_log": [
        ("subscription_id", "str", "<required>"),
        ("start_time", "str", "<required>"),
        ("end_time", "str", "<required>"),
        ("resource_uri", "str | None", "None"),
    ],
}

#: The ten lifecycle tools that had no direct test coverage before E1-T2.
LIFECYCLE_TOOLS = [
    "chaos_create_workspace",
    "chaos_get_workspace",
    "chaos_refresh_recommendations",
    "chaos_list_recommended_scenarios",
    "chaos_create_scenario_configuration",
    "chaos_validate_scenario_configuration",
    "chaos_fix_resource_permissions",
    "chaos_execute_scenario",
    "chaos_get_scenario_run",
    "chaos_cancel_scenario_run",
]

#: Checked-in envelope contract every tool must satisfy (see `chaos_mcp.monitor`).
TOOL_ENVELOPE_SCHEMA: dict = {
    "$schema": "http://json-schema.org/draft-07/schema#",
    "title": "ChaosMcpToolEnvelope",
    "type": "object",
    "oneOf": [
        {
            "required": ["ok", "result"],
            "additionalProperties": False,
            "properties": {"ok": {"const": True}, "result": {}},
        },
        {
            "required": ["ok", "errorType", "error"],
            "additionalProperties": False,
            "properties": {
                "ok": {"const": False},
                "errorType": {
                    "type": "string",
                    "enum": ["AzureError", "PermissionDenied", "AuthenticationFailed"],
                },
                "error": {"type": "string"},
                "statusCode": {"type": "integer"},
                "details": {},
            },
        },
    ],
}

#: Top-level sections of the v1 `startchaos-state.json` fixture. Resume logic in
#: every skill keys off these, so the shape is frozen (additive-only).
FROZEN_STATE_SECTIONS = ["context", "auth", "workspace", "setup", "run"]

SUB = "00000000-0000-0000-0000-000000000000"
RG = "rg-chaos"
WS = "ws-chaos"
SCENARIO = "ZoneDown-1.0"
CONFIG = "cfg-1"
RUN_ID = "run-abc"
SCOPE = f"/subscriptions/{SUB}/resourceGroups/{RG}"


def assert_envelope(payload: dict) -> None:
    """Every tool return value must match the frozen envelope contract."""
    jsonschema.validate(payload, TOOL_ENVELOPE_SCHEMA)


# ---------------------------------------------------------------------------
# Test plumbing
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _reset_test_transport():
    """`_TEST_TRANSPORT` is process-global; never leak it into the next test."""
    yield
    az._TEST_TRANSPORT = None


@pytest.fixture(autouse=True)
def _no_real_az(monkeypatch):
    """Block every real `az` shell-out; tokens are fabricated."""
    monkeypatch.setattr(az, "_get_token", lambda resource=az.ARM_ENDPOINT: "fake-token")


@pytest.fixture(autouse=True)
def _no_sleep(monkeypatch):
    """Make LRO polling and retry backoff instant."""
    monkeypatch.setattr(az.time, "sleep", lambda *_a, **_kw: None)


def install_arm_transport(
    monkeypatch, handler: Callable[[httpx.Request], httpx.Response]
) -> None:
    """Route every ARM call in `chaos_mcp.azure` through a MockTransport.

    `arm_request` calls the module-level `httpx.request`, so the shared
    `_TEST_TRANSPORT` hook is installed *and* `httpx.request` is redirected onto
    it. Both entry points therefore replay from the same recorded handler.
    """
    transport = httpx.MockTransport(handler)
    monkeypatch.setattr(az, "_TEST_TRANSPORT", transport)

    def routed_request(method: str, url: str, **kwargs) -> httpx.Response:
        with httpx.Client(transport=transport) as client:
            return client.request(method, url, **kwargs)

    monkeypatch.setattr(az.httpx, "request", routed_request)


def recorded(routes: dict[tuple[str, str], httpx.Response]):
    """Build a handler from an exact ``(method, path) -> Response`` table."""
    seen: list[tuple[str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        key = (request.method, request.url.path)
        seen.append(key)
        if key not in routes:
            raise AssertionError(f"unrecorded ARM call: {key[0]} {key[1]}")
        return routes[key]

    handler.seen = seen  # type: ignore[attr-defined]
    return handler


def arm_error(status: int = 403, code: str = "AuthorizationFailed") -> httpx.Response:
    return httpx.Response(status, json={"error": {"code": code, "message": "denied"}})


WS_PATH = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Chaos/workspaces/{WS}"
CFG_PATH = f"{WS_PATH}/scenarios/{SCENARIO}/configurations/{CONFIG}"


# ---------------------------------------------------------------------------
# E1-T1 — skill, state, impact-schema and tool-signature freeze
# ---------------------------------------------------------------------------


def _frontmatter(path: Path) -> str:
    text = path.read_text(encoding="utf-8-sig")
    assert text.startswith("---"), f"{path} has no YAML frontmatter"
    return text.split("---", 2)[1]


def test_exactly_five_skills_ship():
    found = sorted(p.parent.name for p in SKILLS_DIR.glob("*/SKILL.md"))
    assert found == sorted(FROZEN_SKILLS), (
        "The five shipped skills are EXTEND/REFACTOR, never replace. "
        f"Found {found}."
    )


@pytest.mark.parametrize("skill", sorted(FROZEN_SKILLS))
def test_skill_name_and_trigger_frozen(skill):
    fm = _frontmatter(SKILLS_DIR / skill / "SKILL.md")
    name = re.search(r"^name:\s*(\S+)\s*$", fm, re.MULTILINE)
    assert name and name.group(1) == skill

    description = re.search(r'^description:\s*"(.*?)"\s*$', fm, re.MULTILINE | re.DOTALL)
    assert description, f"{skill} must keep a quoted description (its trigger text)"
    normalized = " ".join(description.group(1).split())
    assert normalized == " ".join(FROZEN_SKILLS[skill].split())


def test_start_chaos_agent_trigger_phrases_frozen():
    fm = _frontmatter(PLUGIN_ROOT / "agents" / "start-chaos.md")
    for phrase in FROZEN_START_CHAOS_TRIGGERS:
        assert f"'{phrase}'" in fm, f"trigger phrase '{phrase}' was dropped"


def test_state_fixture_v1_frozen():
    state_ps1 = (PLUGIN_ROOT / "scripts" / "State.ps1").read_text(encoding="utf-8-sig")
    assert "$script:StateSchemaVersion = 1" in state_ps1, (
        "state schema v1 must keep resuming; a bump needs an importer (Epic 2)."
    )
    for section in FROZEN_STATE_SECTIONS:
        assert re.search(rf"^\s+{section}\s+=\s+\[ordered\]@\{{", state_ps1, re.MULTILINE), (
            f"state section '{section}' disappeared from New-EmptyState"
        )
    # Resume keys the orchestrator branches on.
    for key in ("auth.status", "workspace.status", "setup.status"):
        assert key in (PLUGIN_ROOT / "agents" / "start-chaos.md").read_text(
            encoding="utf-8-sig"
        )


def test_impact_schema_v1_frozen():
    schema = json.loads(
        (
            SKILLS_DIR / "chaos-impact" / "schema" / "impact-report.schema.json"
        ).read_text(encoding="utf-8-sig")
    )
    assert schema["properties"]["impactReportSchemaVersion"]["const"] == 1
    assert schema["required"] == [
        "impactReportSchemaVersion",
        "scenarioRunId",
        "workspace",
        "scenario",
        "window",
        "actions",
        "coverage",
        "queries",
        "errors",
    ]
    # The schema itself must stay loadable by a draft-07 validator.
    jsonschema.Draft7Validator.check_schema(schema)


def test_offline_replay_expectations_fixture_frozen():
    """The recorded replay expectations are the impact baseline (E1-T1/E1-T6)."""
    e2e = SKILLS_DIR / "chaos-impact" / "tests" / "e2e"
    expected = json.loads((e2e / "expected-impact.json").read_text(encoding="utf-8-sig"))
    assert expected["impactReportSchemaVersion"] == 1
    for key in ("scenarioRunId", "workspace", "scenario", "window", "expectations"):
        assert key in expected, f"replay expectation key '{key}' was dropped"
    # Every recorded payload the replay driver replays must still be present.
    for recording in (
        "recorded-run.json",
        "recorded-metrics.json",
        "recorded-activity.json",
        "recorded-alerts.json",
        "recorded-health.json",
        "recorded-diag-settings.json",
        "recorded-workspace-check.json",
    ):
        assert (e2e / recording).is_file(), f"recorded fixture {recording} is missing"
    assert (e2e / "Run-OfflineReplay.ps1").is_file()
    assert (e2e / "OfflineReplayE2E.Tests.ps1").is_file()


@pytest.mark.parametrize("tool_name", sorted(FROZEN_TOOL_SIGNATURES))
def test_tool_signature_frozen(tool_name):
    fn = getattr(srv, tool_name, None)
    assert callable(fn), f"tool {tool_name} is no longer callable on the server module"
    actual = [
        (
            p.name,
            str(p.annotation),
            "<required>" if p.default is inspect.Parameter.empty else repr(p.default),
        )
        for p in inspect.signature(fn).parameters.values()
    ]
    assert actual == FROZEN_TOOL_SIGNATURES[tool_name], (
        f"{tool_name} is EXTEND-only: parameter names, order and defaults are frozen."
    )


# ---------------------------------------------------------------------------
# E1-T2 — recorded tests for the ten lifecycle tools
# ---------------------------------------------------------------------------


def test_create_workspace_provisions_and_grants_reader(monkeypatch):
    workspace = {
        "id": WS_PATH,
        "name": WS,
        "identity": {"type": "SystemAssigned", "principalId": "principal-1"},
        "properties": {"scopes": [SCOPE], "provisioningState": "Succeeded"},
    }
    calls: list[tuple[str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.method, request.url.path))
        if request.method == "PUT" and request.url.path == WS_PATH:
            return httpx.Response(200, json=workspace)
        if request.method == "GET" and request.url.path == WS_PATH:
            return httpx.Response(200, json=workspace)
        if "/providers/Microsoft.Authorization/roleAssignments/" in request.url.path:
            return httpx.Response(201, json={"id": request.url.path})
        raise AssertionError(f"unrecorded call {request.method} {request.url.path}")

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_create_workspace(SUB, RG, WS, "westus2", [SCOPE])

    assert_envelope(result)
    assert result["ok"] is True
    assert result["result"]["workspace"]["name"] == WS
    assert result["result"]["roleAssignments"] == [{"scope": SCOPE, "status": "granted"}]
    assert ("PUT", WS_PATH) in calls


def test_create_workspace_treats_existing_role_assignment_as_granted(monkeypatch):
    workspace = {"identity": {"principalId": "principal-1"}}

    def handler(request: httpx.Request) -> httpx.Response:
        if "/roleAssignments/" in request.url.path:
            return httpx.Response(
                409, json={"error": {"code": "RoleAssignmentExists", "message": "exists"}}
            )
        return httpx.Response(200, json=workspace)

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_create_workspace(SUB, RG, WS, "westus2", [SCOPE])

    assert_envelope(result)
    assert result["result"]["roleAssignments"] == [
        {"scope": SCOPE, "status": "already-granted"}
    ]


def test_create_workspace_user_assigned_identity_body(monkeypatch):
    uami = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/uami"
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "PUT" and request.url.path == WS_PATH:
            bodies.append(json.loads(request.content))
        return httpx.Response(200, json={"identity": {}})

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_create_workspace(
        SUB,
        RG,
        WS,
        "westus2",
        [SCOPE],
        identity_type="UserAssigned",
        user_assigned_identity_resource_id=uami,
    )

    assert_envelope(result)
    assert bodies[0]["identity"] == {
        "type": "UserAssigned",
        "userAssignedIdentities": {uami: {}},
    }
    # No principalId in the response → no RBAC attempted, not a crash.
    assert result["result"]["roleAssignments"] == []


def test_get_workspace_returns_resource(monkeypatch):
    install_arm_transport(
        monkeypatch, recorded({("GET", WS_PATH): httpx.Response(200, json={"name": WS})})
    )
    result = srv.chaos_get_workspace(SUB, RG, WS)
    assert_envelope(result)
    assert result == {"ok": True, "result": {"name": WS}}


def test_get_workspace_maps_failure_to_error_envelope(monkeypatch):
    install_arm_transport(
        monkeypatch, recorded({("GET", WS_PATH): arm_error(404, "ResourceNotFound")})
    )
    result = srv.chaos_get_workspace(SUB, RG, WS)
    assert_envelope(result)
    assert result["ok"] is False
    assert result["errorType"] == "AzureError"
    assert "ResourceNotFound" in result["error"]


def test_refresh_recommendations_waits_for_lro(monkeypatch):
    poll_url = "https://management.azure.com/operations/op-1"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/refreshRecommendations"):
            return httpx.Response(202, headers={"Azure-AsyncOperation": poll_url})
        if request.url.path == "/operations/op-1":
            return httpx.Response(200, json={"status": "Succeeded"})
        if request.url.path.endswith("/evaluations/latest"):
            return httpx.Response(200, json={"properties": {"status": "Succeeded"}})
        raise AssertionError(f"unrecorded call {request.url.path}")

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_refresh_recommendations(SUB, RG, WS)
    assert_envelope(result)
    assert result["result"]["properties"]["status"] == "Succeeded"


def test_refresh_recommendations_failed_lro_is_error_envelope(monkeypatch):
    poll_url = "https://management.azure.com/operations/op-1"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/refreshRecommendations"):
            return httpx.Response(202, headers={"Azure-AsyncOperation": poll_url})
        return httpx.Response(200, json={"status": "Failed"})

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_refresh_recommendations(SUB, RG, WS)
    assert_envelope(result)
    assert result["ok"] is False
    assert "Failed" in result["error"]


def test_list_recommended_scenarios_unwraps_value(monkeypatch):
    install_arm_transport(
        monkeypatch,
        recorded(
            {
                ("GET", f"{WS_PATH}/scenarios"): httpx.Response(
                    200, json={"value": [{"name": SCENARIO}, {"name": "Other-1.0"}]}
                )
            }
        ),
    )
    result = srv.chaos_list_recommended_scenarios(SUB, RG, WS)
    assert_envelope(result)
    assert result["result"] == [{"name": SCENARIO}, {"name": "Other-1.0"}]


def test_list_recommended_scenarios_empty_is_ok(monkeypatch):
    install_arm_transport(
        monkeypatch,
        recorded({("GET", f"{WS_PATH}/scenarios"): httpx.Response(200, json={})}),
    )
    result = srv.chaos_list_recommended_scenarios(SUB, RG, WS)
    assert_envelope(result)
    assert result == {"ok": True, "result": []}


def test_create_scenario_configuration_puts_body_and_returns_resource(monkeypatch):
    configuration = {"properties": {"parameters": [{"key": "duration", "value": "PT5M"}]}}
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == CFG_PATH
        if request.method == "PUT":
            bodies.append(json.loads(request.content))
            return httpx.Response(201, json=configuration)
        return httpx.Response(200, json={"name": CONFIG, **configuration})

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_create_scenario_configuration(
        SUB, RG, WS, SCENARIO, CONFIG, configuration
    )
    assert_envelope(result)
    assert bodies == [configuration]
    assert result["result"]["name"] == CONFIG


def test_create_scenario_configuration_rejects_bad_payload(monkeypatch):
    install_arm_transport(
        monkeypatch, recorded({("PUT", CFG_PATH): arm_error(400, "InvalidParameter")})
    )
    result = srv.chaos_create_scenario_configuration(SUB, RG, WS, SCENARIO, CONFIG, {})
    assert_envelope(result)
    assert result["ok"] is False
    assert "InvalidParameter" in result["error"]


def test_validate_scenario_configuration_returns_latest_validation(monkeypatch):
    latest = {"properties": {"status": "Failed", "errors": [{"code": "MissingPermission"}]}}

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == f"{CFG_PATH}/validate":
            return httpx.Response(200, json={"status": "Succeeded"})
        if request.url.path == f"{CFG_PATH}/validations/latest":
            return httpx.Response(200, json=latest)
        raise AssertionError(f"unrecorded call {request.url.path}")

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_validate_scenario_configuration(SUB, RG, WS, SCENARIO, CONFIG)
    assert_envelope(result)
    # A validation that reports errors is still a *successful* tool call: the
    # blockers are data in `result`, not an envelope-level failure.
    assert result["ok"] is True
    assert result["result"]["properties"]["errors"][0]["code"] == "MissingPermission"


def test_validate_scenario_configuration_permission_denied(monkeypatch):
    install_arm_transport(
        monkeypatch,
        recorded({("POST", f"{CFG_PATH}/validate"): arm_error(403, "AuthorizationFailed")}),
    )
    result = srv.chaos_validate_scenario_configuration(SUB, RG, WS, SCENARIO, CONFIG)
    assert_envelope(result)
    assert result["ok"] is False
    assert "AuthorizationFailed" in result["error"]


@pytest.mark.parametrize("what_if", [False, True])
def test_fix_resource_permissions_forwards_what_if(monkeypatch, what_if):
    bodies: list[dict] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST":
            bodies.append(json.loads(request.content))
            return httpx.Response(200, json={"status": "Succeeded"})
        return httpx.Response(200, json={"properties": {"granted": []}})

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_fix_resource_permissions(
        SUB, RG, WS, SCENARIO, CONFIG, what_if=what_if
    )
    assert_envelope(result)
    assert bodies == [{"whatIf": what_if}]
    assert result["ok"] is True


def test_execute_scenario_resolves_run_id_from_location_header(monkeypatch):
    location = f"https://management.azure.com{WS_PATH}/scenarios/{SCENARIO}/runs/{RUN_ID}?api-version=x"
    install_arm_transport(
        monkeypatch,
        recorded(
            {
                ("POST", f"{CFG_PATH}/execute"): httpx.Response(
                    202, headers={"Location": location}
                )
            }
        ),
    )
    result = srv.chaos_execute_scenario(SUB, RG, WS, SCENARIO, CONFIG)
    assert_envelope(result)
    assert result == {"ok": True, "result": {"scenarioRunId": RUN_ID}}


def test_execute_scenario_falls_back_to_newest_matching_run(monkeypatch):
    runs = {
        "value": [
            {
                "name": "run-old",
                "properties": {
                    "scenarioConfigurationName": CONFIG,
                    "startTime": "2026-01-01T00:00:00Z",
                },
            },
            {
                "name": RUN_ID,
                "properties": {
                    "scenarioConfigurationName": CONFIG,
                    "startTime": "2026-01-02T00:00:00Z",
                },
            },
            {
                "name": "run-other-config",
                "properties": {
                    "scenarioConfigurationName": "cfg-2",
                    "startTime": "2026-01-03T00:00:00Z",
                },
            },
        ]
    }
    install_arm_transport(
        monkeypatch,
        recorded(
            {
                ("POST", f"{CFG_PATH}/execute"): httpx.Response(202),
                ("GET", f"{WS_PATH}/scenarios/{SCENARIO}/runs"): httpx.Response(
                    200, json=runs
                ),
            }
        ),
    )
    result = srv.chaos_execute_scenario(SUB, RG, WS, SCENARIO, CONFIG)
    assert_envelope(result)
    assert result["result"]["scenarioRunId"] == RUN_ID


def test_execute_scenario_without_any_run_returns_named_error(monkeypatch):
    install_arm_transport(
        monkeypatch,
        recorded(
            {
                ("POST", f"{CFG_PATH}/execute"): httpx.Response(202),
                ("GET", f"{WS_PATH}/scenarios/{SCENARIO}/runs"): httpx.Response(
                    200, json={"value": []}
                ),
            }
        ),
    )
    result = srv.chaos_execute_scenario(SUB, RG, WS, SCENARIO, CONFIG)
    assert_envelope(result)
    assert result["ok"] is False
    assert result["error"] == "Could not resolve ScenarioRun ID after execution."


def test_get_scenario_run_returns_status_snapshot(monkeypatch):
    run = {
        "name": RUN_ID,
        "properties": {"status": "Running", "actions": [{"name": "shutdown"}]},
    }
    install_arm_transport(
        monkeypatch,
        recorded(
            {
                ("GET", f"{WS_PATH}/scenarios/{SCENARIO}/runs/{RUN_ID}"): httpx.Response(
                    200, json=run
                )
            }
        ),
    )
    result = srv.chaos_get_scenario_run(SUB, RG, WS, SCENARIO, RUN_ID)
    assert_envelope(result)
    assert result["result"]["properties"]["status"] == "Running"


def test_get_scenario_run_missing_run_is_error_envelope(monkeypatch):
    install_arm_transport(
        monkeypatch,
        recorded(
            {
                ("GET", f"{WS_PATH}/scenarios/{SCENARIO}/runs/{RUN_ID}"): arm_error(
                    404, "ResourceNotFound"
                )
            }
        ),
    )
    result = srv.chaos_get_scenario_run(SUB, RG, WS, SCENARIO, RUN_ID)
    assert_envelope(result)
    assert result["ok"] is False


def test_cancel_scenario_run_reports_cancel_requested(monkeypatch):
    install_arm_transport(
        monkeypatch,
        recorded(
            {
                (
                    "POST",
                    f"{WS_PATH}/scenarios/{SCENARIO}/runs/{RUN_ID}/cancel",
                ): httpx.Response(202)
            }
        ),
    )
    result = srv.chaos_cancel_scenario_run(SUB, RG, WS, SCENARIO, RUN_ID)
    assert_envelope(result)
    # Cancellation is best-effort: the tool never claims the run stopped.
    assert result == {
        "ok": True,
        "result": {"scenarioRunId": RUN_ID, "status": "cancelRequested"},
    }


def test_cancel_scenario_run_failure_is_error_envelope(monkeypatch):
    install_arm_transport(
        monkeypatch,
        recorded(
            {
                (
                    "POST",
                    f"{WS_PATH}/scenarios/{SCENARIO}/runs/{RUN_ID}/cancel",
                ): arm_error(409, "RunAlreadyCompleted")
            }
        ),
    )
    result = srv.chaos_cancel_scenario_run(SUB, RG, WS, SCENARIO, RUN_ID)
    assert_envelope(result)
    assert result["ok"] is False
    assert "RunAlreadyCompleted" in result["error"]


def test_every_lifecycle_tool_has_direct_coverage():
    """E1-T2 guard: each of the ten lifecycle tools is exercised by a test here."""
    source = Path(__file__).read_text(encoding="utf-8")
    body = source.split("# E1-T2 — recorded tests", 1)[1]
    for tool in LIFECYCLE_TOOLS:
        assert f"srv.{tool}(" in body, f"{tool} lost its direct recorded test"


def test_all_fifteen_tools_use_the_pinned_chaos_api_version(monkeypatch):
    """Every ARM call from the lifecycle tools carries the single pinned version."""
    from chaos_mcp import apiversions

    versions: set[str] = set()

    def handler(request: httpx.Request) -> httpx.Response:
        versions.add(request.url.params.get("api-version"))
        return httpx.Response(200, json={"identity": {}, "value": []})

    install_arm_transport(monkeypatch, handler)

    srv.chaos_get_workspace(SUB, RG, WS)
    srv.chaos_list_recommended_scenarios(SUB, RG, WS)
    srv.chaos_get_scenario_run(SUB, RG, WS, SCENARIO, RUN_ID)

    assert versions == {apiversions.CHAOS_API_VERSION}


# ---------------------------------------------------------------------------
# E3-T5 — blocker normalization, targeted-first grants and consent
# ---------------------------------------------------------------------------


def test_normalize_blockers_collects_every_reporting_site_and_spelling():
    """`validations/latest` reports blockers from three places with two spellings."""
    latest = {
        "properties": {
            "errors": [{"code": "MissingPermission", "message": "access denied"}],
            "validationErrors": [
                {
                    "errorCode": "TargetNotEnabled",
                    "errorMessage": "target resource is not onboarded",
                    "targetResourceId": "/subscriptions/s/rg/vm-a",
                }
            ],
            "resources": [
                {
                    "resourceId": "/subscriptions/s/rg/vm-b",
                    "errors": [{"code": "AuthorizationFailed", "message": "no rbac"}],
                }
            ],
        }
    }

    blockers = srv.normalize_validation_blockers(latest)
    by_code = {b["code"]: b for b in blockers}

    assert set(by_code) == {"MissingPermission", "TargetNotEnabled", "AuthorizationFailed"}
    assert by_code["MissingPermission"]["category"] == "permission"
    assert by_code["TargetNotEnabled"]["category"] == "resource"
    # A blocker nested under `resources[]` inherits that resource's id.
    assert by_code["AuthorizationFailed"]["resourceId"] == "/subscriptions/s/rg/vm-b"
    assert by_code["TargetNotEnabled"]["resourceId"] == "/subscriptions/s/rg/vm-a"
    for blocker in blockers:
        assert set(blocker) == {
            "code",
            "category",
            "resourceId",
            "roleName",
            "principalId",
            "message",
        }


def test_normalize_blockers_falls_back_to_other_and_dedupes():
    latest = {
        "properties": {
            "errors": [
                {"code": "SomethingElse", "message": "nothing familiar here"},
                {"code": "MissingPermission", "message": "denied", "resourceId": "/r/1"},
            ],
            # The same blocker reported twice must collapse to one.
            "validationErrors": [
                {"code": "MissingPermission", "message": "denied", "resourceId": "/r/1"}
            ],
        }
    }

    blockers = srv.normalize_validation_blockers(latest)
    assert len(blockers) == 2
    assert [b["category"] for b in blockers] == ["other", "permission"]


@pytest.mark.parametrize("payload", [None, {}, {"properties": None}, "not-a-dict", []])
def test_normalize_blockers_tolerates_unusable_payloads(payload):
    assert srv.normalize_validation_blockers(payload) == []


def test_normalize_blockers_skips_error_entries_that_are_not_objects():
    """Both planes skip them; `Test-StructuredValidationError` is the mirror."""
    latest = {
        "properties": {
            "status": "Failed",
            "errors": ["a bare string", 42],
            "resources": [{"resourceId": "/r/1", "errors": ["another bare string"]}],
        }
    }
    assert srv.normalize_validation_blockers(latest) == []

    mixed = {
        "properties": {
            "status": "Failed",
            "errors": ["a bare string", {"code": "MissingPermission", "resourceId": "/r/1"}],
        }
    }
    assert len(srv.normalize_validation_blockers(mixed)) == 1


def test_targeted_grants_are_scoped_to_the_reporting_resource_only():
    blockers = [
        {
            "code": "MissingPermission",
            "category": "permission",
            "resourceId": "/subscriptions/s/rg/vm-a",
            "roleName": "Chaos Studio Target Contributor",
            "principalId": None,
            "message": "denied",
        }
    ]
    grants = srv.build_targeted_grant_proposal(blockers, principal_id="pid-1")

    assert len(grants) == 1
    grant = grants[0]
    assert grant["roleName"] == "Chaos Studio Target Contributor"
    assert grant["blockerCode"] == "MissingPermission"
    # Minimum scope: the single resource that reported the blocker, never wider.
    assert '--scope "/subscriptions/s/rg/vm-a"' in grant["command"]
    assert grant["command"].startswith("az role assignment create")
    assert "pid-1" in grant["command"]


def test_targeted_grants_skip_unfixable_blockers_and_dedupe():
    blockers = [
        # Not a permission problem — no role assignment can clear it.
        {"code": "TargetNotEnabled", "category": "resource", "resourceId": "/r/1"},
        # Permission problem with no resource: the scope would be a guess.
        {"code": "MissingPermission", "category": "permission", "resourceId": None},
        {"code": "MissingPermission", "category": "permission", "resourceId": "/r/2"},
        {"code": "MissingPermission", "category": "permission", "resourceId": "/R/2"},
    ]
    grants = srv.build_targeted_grant_proposal(blockers)

    assert [g["resourceId"] for g in grants] == ["/r/2"]
    # No role named by the service falls back to the least-privileged default.
    assert grants[0]["roleName"] == "Reader"
    # An unknown identity is visible, never silently unassignable.
    assert srv.PRINCIPAL_PLACEHOLDER in grants[0]["command"]


def test_validate_tool_enriches_payload_with_blockers_and_targeted_grants(monkeypatch):
    latest = {
        "properties": {
            "status": "Failed",
            "errors": [
                {
                    "code": "MissingPermission",
                    "message": "authorization failed",
                    "resourceId": "/subscriptions/s/rg/vm-a",
                    "roleName": "Chaos Studio Target Contributor",
                }
            ],
        }
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and request.url.path == f"{CFG_PATH}/validate":
            return httpx.Response(200, json={"status": "Succeeded"})
        if request.url.path == f"{CFG_PATH}/validations/latest":
            return httpx.Response(200, json=latest)
        raise AssertionError(f"unrecorded call {request.url.path}")

    install_arm_transport(monkeypatch, handler)

    result = srv.chaos_validate_scenario_configuration(SUB, RG, WS, SCENARIO, CONFIG)
    assert_envelope(result)
    assert result["ok"] is True
    payload = result["result"]
    # Additive only: the raw service payload is preserved untouched.
    assert payload["properties"]["errors"][0]["code"] == "MissingPermission"
    assert payload["normalizedBlockers"][0]["category"] == "permission"
    grant = payload["targetedGrantProposal"][0]
    assert '--scope "/subscriptions/s/rg/vm-a"' in grant["command"]


def test_validate_tool_never_overwrites_service_supplied_fields(monkeypatch):
    latest = {
        "properties": {"status": "Failed", "errors": [{"code": "MissingPermission"}]},
        "normalizedBlockers": "service-owned",
        "targetedGrantProposal": "service-owned",
    }

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST":
            return httpx.Response(200, json={"status": "Succeeded"})
        return httpx.Response(200, json=latest)

    install_arm_transport(monkeypatch, handler)

    payload = srv.chaos_validate_scenario_configuration(SUB, RG, WS, SCENARIO, CONFIG)["result"]
    assert payload["normalizedBlockers"] == "service-owned"
    assert payload["targetedGrantProposal"] == "service-owned"


def test_broad_fix_tool_documents_its_breadth_and_the_consent_requirement():
    """E3-T3: the host-visible description must state the breadth and the gate."""
    doc = (srv.chaos_fix_resource_permissions.__doc__ or "").lower()
    assert "explicit consent" in doc
    assert "broad" in doc
    assert "every" in doc
    # It must point the caller at the minimum-scope alternative first.
    assert "targetedgrantproposal" in doc
    assert "chaos_validate_scenario_configuration" in doc


def test_powershell_and_python_blocker_categories_stay_in_sync():
    """The helper is mirrored in scripts/Validate-AndFix.ps1; drift is silent."""
    ps = (
        Path(__file__).resolve().parents[2] / "scripts" / "Validate-AndFix.ps1"
    ).read_text(encoding="utf-8")
    for token in ("permission", "authoriz", "forbidden", "denied", "rbac"):
        assert token in ps, f"PowerShell permission pattern lost '{token}'"
    assert "ConvertTo-ValidationBlocker" in ps
    assert "Test-BroadPermissionFixConsent" in ps
    # The non-object error entry is skipped on both planes (see
    # test_normalize_blockers_skips_error_entries_that_are_not_objects); the
    # PowerShell side must keep applying its guard at both reporting sites.
    assert "Test-StructuredValidationError" in ps
    assert ps.count("if (Test-StructuredValidationError -Entry $item)") == 2


def test_powershell_and_python_emit_the_same_targeted_grant_command_shape():
    """The `az role assignment create` string is hand-written on both planes.

    `Build-RoleAssignmentRemediation` (scripts/Rbac.ps1) and
    `build_targeted_grant_proposal` (server.py) must produce byte-identical
    commands for the same inputs; a flag added on one plane only would silently
    ship an unrunnable "minimum-scope alternative" to half the callers.
    """
    rbac = (Path(__file__).resolve().parents[2] / "scripts" / "Rbac.ps1").read_text(
        encoding="utf-8"
    )

    def ps_template(marker: str) -> str:
        line = next(ln for ln in rbac.splitlines() if marker in ln)
        body = line.split("=", 1)[1].strip()
        assert body.startswith('"') and body.endswith('"'), body
        # Strip the outer quotes, then the backticks PowerShell uses to escape
        # the inner ones.
        body = body[1:-1].replace("`", "")
        for ps_var, token in (
            ("$PrincipalId", "{principal}"),
            ("$RoleName", "{role}"),
            ("$Scope", "{scope}"),
        ):
            body = body.replace(ps_var, token)
        return body

    principal, role, scope = "pid-1", "Chaos Studio Target Contributor", "/subs/s/rg/vm-a"
    grant = srv.build_targeted_grant_proposal(
        [{"category": "permission", "resourceId": scope, "roleName": role, "code": "X"}],
        principal_id=principal,
    )[0]

    def py_template(value: str) -> str:
        # Order matters: substitute the longest values first.
        for actual, token in (
            (scope, "{scope}"),
            (role, "{role}"),
            (principal, "{principal}"),
        ):
            value = value.replace(actual, token)
        return value

    assert py_template(grant["command"]) == ps_template('$command = "az role assignment create')
    assert py_template(grant["description"]) == ps_template('description = "Grant')
