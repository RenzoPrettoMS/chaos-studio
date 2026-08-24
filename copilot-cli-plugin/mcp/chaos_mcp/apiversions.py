# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Single source of truth for every Azure REST version this server pins.

Covers ARM `api-version` query parameters plus the Log Analytics query
endpoint's path version. `azure.py`, `monitor.py` and `server.py` import from
here rather than declaring their own literals, so a version bump is a one-line
change and `tests/test_tool_manifest.py` can assert both that no api-version
literal appears anywhere else in the package and that no pin here is dead.

The PowerShell chaos-impact skill keeps its own pins in
`skills/chaos-impact/scripts/Constants.ps1` — the two surfaces are
independent by design and are not merged here.
"""
from __future__ import annotations

# Microsoft.Chaos control plane (workspaces, scenarios, configurations, runs).
# Q6: stay on this preview pin until a target environment has exercised the
# required preview operations with recorded fixtures.
CHAOS_API_VERSION = "2026-05-01-preview"

# Microsoft.Authorization/roleAssignments (Reader grants on workspace scopes).
ROLE_ASSIGNMENT_API_VERSION = "2022-04-01"

# Microsoft.Insights/metrics.
METRICS_API_VERSION = "2024-02-01"

# Microsoft.Insights/eventtypes/management/values (Activity Log).
ACTIVITY_LOG_API_VERSION = "2015-04-01"

# IMDS token endpoint (VMs, VMSS, AKS).
IMDS_API_VERSION = "2018-02-01"

# App Service / Container Apps / Functions identity endpoint.
APP_SERVICE_IDENTITY_API_VERSION = "2019-08-01"

# Log Analytics query endpoint path segment (not an ARM api-version).
LOG_ANALYTICS_QUERY_VERSION = "v1"

#: Every pin, keyed by the surface it belongs to. Emitted by tests and useful
#: for provenance when reporting which versions a run was made against.
API_VERSIONS: dict[str, str] = {
    "chaos": CHAOS_API_VERSION,
    "roleAssignment": ROLE_ASSIGNMENT_API_VERSION,
    "metrics": METRICS_API_VERSION,
    "activityLog": ACTIVITY_LOG_API_VERSION,
    "imds": IMDS_API_VERSION,
    "appServiceIdentity": APP_SERVICE_IDENTITY_API_VERSION,
    "logAnalyticsQuery": LOG_ANALYTICS_QUERY_VERSION,
}
