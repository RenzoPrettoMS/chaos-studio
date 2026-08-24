# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Tool-manifest and preflight lints (E1-T4, E1-T7).

Three invariants are enforced here:

1. The server registers **exactly** the original 15 tools, and every one of
   them is still callable with its decorator intact. Tools are EXTEND-only.
2. Every `requiredTools` entry declared by a skill resolves to one of those
   registered tools, and a declared tool that the *host* does not expose
   produces a **named** preflight failure rather than a substitution (F5).
3. No api-version string literal survives outside `chaos_mcp/apiversions.py`
   (NFR-9).

The preflight itself lives in `copilot-cli-plugin/scripts/Preflight.ps1` and is
exercised end-to-end by `skills/start-chaos/tests/Preflight.Tests.ps1`. The
Python mirror below exists so the same regression is covered on the pytest
matrix; `test_preflight_failure_prefix_matches_powershell` pins the two
together so they cannot drift.
"""
from __future__ import annotations

import ast
import asyncio
import re
from pathlib import Path

import pytest

from chaos_mcp import apiversions
from chaos_mcp import server as srv

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
SKILLS_DIR = PLUGIN_ROOT / "skills"
PACKAGE_DIR = Path(srv.__file__).resolve().parent
PREFLIGHT_PS1 = PLUGIN_ROOT / "scripts" / "Preflight.ps1"

#: Mirrors `Get-PreflightFailurePrefix` in scripts/Preflight.ps1.
PREFLIGHT_FAILURE_PREFIX = "Preflight failed: the MCP host does not expose required tool(s):"

#: The 15 tools that shipped in v0.3.0. Adding a semantically distinct tool is
#: allowed by the plan, but it must be added here deliberately — never by
#: accident, and never by removing one of these.
ORIGINAL_FIFTEEN_TOOLS = frozenset(
    {
        "chaos_set_auth_mode",
        "chaos_get_auth_mode",
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
        "monitor_query_metrics",
        "monitor_query_logs",
        "monitor_search_activity_log",
    }
)

#: Any quoted `YYYY-MM-DD` / `YYYY-MM-DD-preview` literal is an api-version pin.
API_VERSION_LITERAL = re.compile(r"""(['"])(\d{4}-\d{2}-\d{2}(?:-preview)?)\1""")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def decorated_tool_names() -> set[str]:
    """Names of every function carrying an `@mcp.tool()` decorator in server.py."""
    tree = ast.parse(Path(srv.__file__).read_text(encoding="utf-8"))
    names: set[str] = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.FunctionDef):
            continue
        for decorator in node.decorator_list:
            target = decorator.func if isinstance(decorator, ast.Call) else decorator
            if (
                isinstance(target, ast.Attribute)
                and target.attr == "tool"
                and isinstance(target.value, ast.Name)
                and target.value.id == "mcp"
            ):
                names.add(node.name)
    return names


def registered_tool_names() -> set[str]:
    """Names the MCP registry would advertise over `tools/list`."""
    return {tool.name for tool in asyncio.run(srv.mcp.list_tools())}


def skill_required_tools(skill_md: Path) -> list[str]:
    """Python mirror of `Get-SkillRequiredTools` in scripts/Preflight.ps1."""
    lines = skill_md.read_text(encoding="utf-8-sig").splitlines()
    assert lines and lines[0].strip() == "---", f"{skill_md} has no YAML frontmatter"
    tools: list[str] = []
    in_block = False
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if re.fullmatch(r"requiredTools:\s*", line):
            in_block = True
            continue
        if in_block:
            item = re.fullmatch(r"\s+-\s*(\S+)\s*(?:#.*)?", line)
            if item:
                tools.append(item.group(1))
                continue
            in_block = False
    return tools


def preflight(required: list[str], available: list[str]) -> dict:
    """Python mirror of `Test-RequiredTools` in scripts/Preflight.ps1."""
    missing = [tool for tool in required if tool not in set(available)]
    if not missing:
        return {"ok": True, "missing": [], "message": "Preflight passed"}
    return {
        "ok": False,
        "missing": missing,
        "message": f"{PREFLIGHT_FAILURE_PREFIX} {', '.join(sorted(missing))}.",
    }


SKILL_FILES = sorted(SKILLS_DIR.glob("*/SKILL.md"))


# ---------------------------------------------------------------------------
# 1. The 15-tool freeze
# ---------------------------------------------------------------------------


def test_server_registers_exactly_the_original_fifteen_tools():
    registered = registered_tool_names()
    assert registered == set(ORIGINAL_FIFTEEN_TOOLS), (
        "All 15 MCP tools are EXTEND-only. Removed: "
        f"{sorted(ORIGINAL_FIFTEEN_TOOLS - registered)}; "
        f"added without updating this manifest: {sorted(registered - ORIGINAL_FIFTEEN_TOOLS)}."
    )
    assert len(registered) == 15


def test_every_registered_tool_has_a_decorator_and_is_callable():
    decorated = decorated_tool_names()
    assert decorated == set(ORIGINAL_FIFTEEN_TOOLS)
    for name in ORIGINAL_FIFTEEN_TOOLS:
        assert callable(getattr(srv, name, None)), f"{name} is not callable"


def test_every_registered_tool_is_documented():
    """A tool with no docstring reaches the agent with no description."""
    for tool in asyncio.run(srv.mcp.list_tools()):
        assert tool.description and tool.description.strip(), (
            f"{tool.name} has no description; agents cannot route to it."
        )


# ---------------------------------------------------------------------------
# 2. requiredTools / preflight lints (F5)
# ---------------------------------------------------------------------------


def test_all_five_skills_declare_required_tools():
    assert len(SKILL_FILES) == 5
    for skill_md in SKILL_FILES:
        assert skill_required_tools(skill_md), (
            f"{skill_md.parent.name} declares no requiredTools; the host-visible "
            "preflight has nothing to check."
        )


@pytest.mark.parametrize("skill_md", SKILL_FILES, ids=lambda p: p.parent.name)
def test_declared_required_tools_exist_on_the_server(skill_md):
    declared = skill_required_tools(skill_md)
    unknown = sorted(set(declared) - set(ORIGINAL_FIFTEEN_TOOLS))
    assert not unknown, (
        f"{skill_md.parent.name}/SKILL.md declares tool(s) the server does not "
        f"register: {unknown}"
    )
    assert len(declared) == len(set(declared)), "duplicate requiredTools entry"


def test_required_tools_preflight_fails_named():
    """F5 — a required tool absent from the host inventory is named, not substituted.

    Registration on the server says nothing about runtime availability: the host
    may expose a subset (or none) of the registered tools. When that happens the
    preflight must fail loudly, naming the exact missing tool.
    """
    declared = skill_required_tools(SKILLS_DIR / "run-scenario" / "SKILL.md")
    host_inventory = [t for t in declared if t != "chaos_cancel_scenario_run"]

    result = preflight(declared, host_inventory)

    assert result["ok"] is False
    assert result["missing"] == ["chaos_cancel_scenario_run"]
    assert "chaos_cancel_scenario_run" in result["message"]
    # A named failure, never a silent substitution onto a sibling tool.
    for sibling in host_inventory:
        assert sibling not in result["message"]


def test_preflight_passes_when_host_exposes_everything():
    for skill_md in SKILL_FILES:
        declared = skill_required_tools(skill_md)
        assert preflight(declared, sorted(ORIGINAL_FIFTEEN_TOOLS))["ok"] is True


def test_preflight_with_no_mcp_server_names_every_required_tool():
    declared = skill_required_tools(SKILLS_DIR / "chaos-impact" / "SKILL.md")
    result = preflight(declared, [])
    assert result["missing"] == declared
    for tool in declared:
        assert tool in result["message"]


def test_preflight_failure_prefix_matches_powershell():
    """The PowerShell preflight and this Python mirror must not drift."""
    ps1 = PREFLIGHT_PS1.read_text(encoding="utf-8-sig")
    assert PREFLIGHT_FAILURE_PREFIX in ps1


def test_preflight_never_introspects_the_server():
    """Explicit prohibition: the inventory must come from the host `tools/list`."""
    ps1 = PREFLIGHT_PS1.read_text(encoding="utf-8-sig")
    for forbidden in ("chaos_mcp", "chaos-mcp", "list_tools", "Import-Module chaos"):
        assert forbidden not in ps1, (
            f"Preflight.ps1 references '{forbidden}' — the tool inventory must be "
            "supplied by the host, never obtained by server self-introspection."
        )
    assert "AvailableTools" in ps1


# ---------------------------------------------------------------------------
# 3. api-version consolidation (NFR-9 / E1-T7)
# ---------------------------------------------------------------------------


def test_api_versions_centralised():
    offenders: list[str] = []
    for module in sorted(PACKAGE_DIR.glob("*.py")):
        if module.name == "apiversions.py":
            continue
        for lineno, line in enumerate(
            module.read_text(encoding="utf-8").splitlines(), start=1
        ):
            match = API_VERSION_LITERAL.search(line)
            if match:
                offenders.append(f"{module.name}:{lineno}: {match.group(2)}")
    assert not offenders, (
        "api-version literals must live only in chaos_mcp/apiversions.py: "
        f"{offenders}"
    )


def test_pinned_versions_are_the_shipped_ones():
    """Q6 — stay on the current preview pin until Phase 0 evidence says otherwise."""
    assert apiversions.CHAOS_API_VERSION == "2026-05-01-preview"
    assert apiversions.API_VERSIONS["chaos"] == apiversions.CHAOS_API_VERSION
    assert set(apiversions.API_VERSIONS) == {
        "chaos",
        "roleAssignment",
        "metrics",
        "activityLog",
        "imds",
        "appServiceIdentity",
        "logAnalyticsQuery",
    }


def test_no_pin_is_dead():
    """Every exported pin must actually be consumed by a module in the package.

    Guards the module docstring's 'single source of truth' claim: a constant
    nobody imports asserts a consolidation that never happened.
    """
    consumers = "\n".join(
        module.read_text(encoding="utf-8")
        for module in sorted(PACKAGE_DIR.glob("*.py"))
        if module.name != "apiversions.py"
    )
    unused = [
        name
        for name in dir(apiversions)
        if name.isupper() and name != "API_VERSIONS" and name not in consumers
    ]
    assert not unused, (
        "these apiversions pins are declared but never imported by any module: "
        f"{unused}"
    )


def test_modules_reexport_the_shared_pins():
    """Back-compat: existing call sites keep their module-level names."""
    from chaos_mcp import azure as az
    from chaos_mcp import monitor as mon

    assert az.DEFAULT_API_VERSION == apiversions.CHAOS_API_VERSION
    assert az.IMDS_API_VERSION == apiversions.IMDS_API_VERSION
    assert az.APP_SERVICE_IDENTITY_API_VERSION == apiversions.APP_SERVICE_IDENTITY_API_VERSION
    assert mon.METRICS_API_VERSION == apiversions.METRICS_API_VERSION
    assert mon.ACTIVITY_LOG_API_VERSION == apiversions.ACTIVITY_LOG_API_VERSION
    assert srv.ROLE_ASSIGNMENT_API_VERSION == apiversions.ROLE_ASSIGNMENT_API_VERSION


def test_powershell_impact_pins_stay_in_constants_ps1():
    """E1-T7 keeps the PowerShell impact pins where they are — not merged here."""
    constants = (
        SKILLS_DIR / "chaos-impact" / "scripts" / "Constants.ps1"
    ).read_text(encoding="utf-8-sig")
    assert "$script:ChaosImpactApi_ChaosStudio = '2026-05-01-preview'" in constants
    assert "Get-ChaosImpactConstants" in constants
