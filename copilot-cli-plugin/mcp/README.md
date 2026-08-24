# chaos-mcp

MCP server exposing Azure Chaos Studio v2 operations as agent-callable tools.

The server relies on the user's local `az` CLI session for authentication
rather than managing tokens itself, keeping the server stateless. It can also
be pointed at an Azure Managed Identity for unattended runs — see
[Authentication](#authentication). See the
[copilot-cli-plugin README](../README.md) for the full tool table and how
this package fits into the Chaos Studio Copilot CLI plugin.

## Authentication

By default every tool borrows the operator's local `az login` session — the
**user principal** — via `az account get-access-token`.

### Choose the mode during a session (no config change)

The customer can switch between the user principal and a **Managed Identity**
mid-conversation by asking the agent to call the `chaos_set_auth_mode` tool —
no config edit or server restart needed. The choice applies to every subsequent
tool call for the life of the session.

| Tool | Purpose |
|---|---|
| `chaos_set_auth_mode(mode, msi_client_id?)` | `mode` = `cli` (user principal) or `managed-identity` (aliases `msi`/`mi`); `msi_client_id` optionally pins a user-assigned identity. |
| `chaos_get_auth_mode()` | Report the effective `{mode, msiClientId, source}`. |

> **Attribution & approval.** In managed-identity mode every ARM action — including the Reader role assignments made during workspace creation — is recorded in the Azure activity log as the **identity**, not the human operator. Review your audit/attribution requirements before switching. Because `chaos_set_auth_mode` is agent-callable, your MCP client's tool-approval prompt is the control that stops a session from being silently flipped onto a privileged host identity — do **not** blanket-auto-approve this tool.

### Startup default (optional env vars)

For unattended hosts (CI, containers, AKS, VMs) you can also set the initial
mode via env vars so no interactive `az login` is required. A runtime
`chaos_set_auth_mode` call always takes precedence over these.

| Env var | Values | Effect |
|---|---|---|
| `CHAOS_MCP_AUTH_MODE` | `cli` (default), `managed-identity` (aliases: `msi`, `mi`) | Selects the token source. |
| `CHAOS_MCP_MSI_CLIENT_ID` | client id (optional) | Pins a **user-assigned** identity; omit to use the **system-assigned** identity. |

In `managed-identity` mode the server acquires tokens from the Azure identity
endpoint — the App Service / Container Apps / Functions endpoint
(`IDENTITY_ENDPOINT` + `IDENTITY_HEADER`) when present, otherwise IMDS
(`169.254.169.254`) for VMs / VMSS / AKS. Grant the identity the same ARM roles
you would grant the user (managing `Microsoft.Chaos` workspaces and querying
Azure Monitor).

## Install

```bash
pip install chaos-mcp        # from PyPI (once published)
pip install -e .             # from source
```

## Client configuration

Register the server in your MCP client config (see
[`mcp-config.example.json`](mcp-config.example.json)):

```json
{ "mcpServers": { "chaos-studio": { "command": "chaos-mcp" } } }
```

- **Claude Desktop**: add the block above to `claude_desktop_config.json`.
- **Claude Code**: `claude mcp add chaos-studio -- chaos-mcp`
- **Cursor**: add the block above to `.cursor/mcp.json`.

The server requires an active `az login` session (or a managed identity — see
[Authentication](#authentication)); tools return a structured
`{"ok": false, "errorType": ...}` envelope (rather than raising) when auth or
permissions are missing, so agents can remediate and retry.

## Development

```bash
pip install -e .
pip install -e ".[test]"     # adds pytest, pytest-cov, httpx, jsonschema
pip install ruff
python -m pytest
ruff check chaos_mcp tests
```

`jsonschema` is required, not optional: `tests/test_lifecycle_contract.py`
validates every tool envelope and impact schema v1 against JSON Schema. Without
it those tests are collected and skipped, which is worse than not having them.

## Runtime verification (E1-T5 spike)

Recorded against the environment named below. Anything not verified is listed
as an unknown rather than inferred from source — repository workflows and
configuration show *intent*, not deployed state.

| Question | Verified? | Evidence |
|---|---|---|
| MCP Python SDK version resolved by `mcp>=1.2.0,<2` | ✅ Yes | `mcp` **1.29.0** installed on CPython 3.13 (Windows). |
| SDK exposes `outputSchema` on `tools/list` | ✅ Yes | `Tool` model carries `outputSchema`; all 15 tools return one. |
| `outputSchema` is *useful* for envelope contract tests | ❌ No | FastMCP derives `{"type": "object", "additionalProperties": true}` from the `dict[str, Any]` return annotation — it asserts nothing about `ok`/`errorType`. Contract tests therefore validate against the checked-in `TOOL_ENVELOPE_SCHEMA` in `tests/test_lifecycle_contract.py`. Revisit only if the tools gain typed return models. |
| Registry still advertises the frozen 15 tools | ✅ Yes | `tests/test_tool_manifest.py::test_server_registers_the_frozen_fifteen_plus_declared_additions`. |
| `chaos-mcp` published on PyPI | ❓ Unknown | Not verified from a target environment. `pip install chaos-mcp` below remains marked "once published"; install from source until a real install is recorded. (Q13) |
| `Microsoft.Chaos` `2026-05-01-preview` preview operations available in a target subscription | ❓ Unknown | No live tenant was exercised. All lifecycle coverage is replayed from recorded ARM payloads. Per Q6 the pin **stays** at `2026-05-01-preview`; moving to `2026-08-01-preview` requires recorded fixtures plus compatibility evidence. |
| ScenarioRun retention / cancel semantics of the target service | ❓ Unknown | `chaos_cancel_scenario_run` is asserted only to report `cancelRequested` (best-effort). Actual cancellation behaviour is unverified. (Q13) |
| Host MCP tool exposure (`tools/list`) in the Copilot CLI | ❓ Unknown | The preflight in `scripts/Preflight.ps1` therefore takes the inventory as an argument and never self-introspects (F5). |

All api-version pins used by this package live in
[`chaos_mcp/apiversions.py`](chaos_mcp/apiversions.py); the PowerShell
chaos-impact skill keeps its own pins in
`skills/chaos-impact/scripts/Constants.ps1`.
