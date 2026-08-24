# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

"""Durable evidence store tests (E2-T5).

Covers the three Epic 2 acceptance criteria:

* an existing `startchaos-state.json` resumes unchanged and is *mirrored*,
  never relocated (the PowerShell half is in
  `skills/start-chaos/tests/State.Tests.ps1`; the shape compatibility of what
  it writes is pinned here);
* evidence survives deletion of repo/session temporary content (F12) —
  `test_evidence_survives_tmp_wipe`;
* no secret or approval key is reachable through the evidence tools —
  `test_evidence_get_cannot_reach_key_material`. If that test fails the
  approval boundary is void and CI must block the build.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import threading
from pathlib import Path

import pytest

from chaos_mcp import evidence as ev
from chaos_mcp import server as srv

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = PLUGIN_ROOT / "schemas"
REFERENCE_DIR = PLUGIN_ROOT / "references" / "chaos"
STATE_PS1 = PLUGIN_ROOT / "scripts" / "State.ps1"

#: 64 hex characters — the shape `k_session` actually has on disk.
FAKE_KEY = "a3f1" * 16

SCOPE = "scope0123abcd"
RUN = "run-000000000001"


@pytest.fixture()
def store(tmp_path, monkeypatch):
    """An isolated evidence root plus a key directory outside it."""
    root = tmp_path / "evidence-root"
    keys = tmp_path / "key-dir"
    root.mkdir()
    keys.mkdir()
    (keys / "session.key").write_text(FAKE_KEY, encoding="utf-8")
    monkeypatch.setenv(ev.EVIDENCE_ROOT_ENV, str(root))
    monkeypatch.setenv(ev.KEY_DIR_ENV, str(keys))
    return root


# ---------------------------------------------------------------------------
# E2-T1 — focused artifact schemas
# ---------------------------------------------------------------------------

EXPECTED_SCHEMAS = [
    "availability",
    "diagnosis",
    "evidence-bundle",
    "hypotheses",
    "inventory",
    "mechanism-ledger",
    "recommendations",
    "run-record",
    "scope-setup",
]


def _schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / f"{name}.v1.schema.json").read_text(encoding="utf-8"))


def test_the_focused_artifact_family_exists():
    found = sorted(p.name[: -len(".v1.schema.json")] for p in SCHEMA_DIR.glob("*.v1.schema.json"))
    assert found == EXPECTED_SCHEMAS


def test_impact_schema_v1_is_untouched():
    """Epic 2 adds artifacts; it does not replace the shipped impact schema."""
    impact = json.loads(
        (PLUGIN_ROOT / "skills" / "chaos-impact" / "schema" / "impact-report.schema.json").read_text(
            encoding="utf-8"
        )
    )
    assert impact["properties"]["impactReportSchemaVersion"]["const"] == 1


@pytest.mark.parametrize("name", EXPECTED_SCHEMAS)
def test_every_artifact_encodes_the_provenance_contract(name):
    schema = _schema(name)
    provenance = schema["definitions"]["provenance"]

    # Provenance is mandatory: an item without it is invalid.
    assert set(provenance["required"]) == {
        "source",
        "collectedAt",
        "confidence",
        "maxAgeMinutes",
        "stale",
    }
    # Confidence is a closed enum assigned by code, not free text.
    assert provenance["properties"]["confidence"]["enum"] == ["high", "medium", "low"]
    # Freshness is computed, not asserted.
    assert provenance["properties"]["stale"]["type"] == "boolean"
    # Source carries tool + api version + query.
    assert set(schema["definitions"]["source"]["required"]) == {"tool", "apiVersion", "query"}

    assert schema["properties"]["artifactSchemaVersion"]["const"] == 1
    assert schema["properties"]["artifactType"]["const"] == name
    for field in ("scopeId", "runId", "generatedAt", "provenance", "warnings"):
        assert field in schema["required"]


@pytest.mark.parametrize("name", EXPECTED_SCHEMAS)
def test_missing_data_is_null_plus_caveat_never_absent(name):
    """NFR-3 — `citedNumber` cannot express a value without its caveat."""
    schema = _schema(name)
    cited = schema["definitions"]["citedNumber"]
    assert set(cited["required"]) == {"value", "caveat", "provenance"}
    assert cited["properties"]["value"]["type"] == ["number", "null"]
    assert cited["properties"]["caveat"]["type"] == ["string", "null"]


def test_mechanism_ledger_accumulates_occurrences():
    schema = _schema("mechanism-ledger")
    mechanism = schema["properties"]["mechanisms"]["items"]
    assert "occurrenceCount" in mechanism["required"]
    assert mechanism["properties"]["occurrences"]["minItems"] == 1
    occurrence = mechanism["properties"]["occurrences"]["items"]
    assert occurrence["properties"]["verdict"]["enum"] == [
        "CONFIRMED",
        "REFUTED",
        "NOT EXERCISED",
    ]


def test_prototype_schemas_are_not_ported():
    """`run-state` / `external-gate` / `workspace-plan` must not reappear."""
    for forbidden in ("run-state", "external-gate", "workspace-plan"):
        assert not list(SCHEMA_DIR.glob(f"**/{forbidden}*")), (
            f"{forbidden} is a PR32 prototype schema and must not be ported"
        )
    assert not (PLUGIN_ROOT / "scripts" / "chaos_loop_state.py").exists()


def _valid_diagnosis() -> dict:
    provenance = {
        "source": {"tool": "monitor_query_metrics", "apiVersion": "x", "query": None},
        "collectedAt": "2020-01-01T00:00:00Z",
        "confidence": "high",
        "maxAgeMinutes": 30,
        "stale": False,
        "caveat": None,
    }
    cited = {"value": 0, "caveat": None, "provenance": provenance}
    return {
        "artifactSchemaVersion": 1,
        "artifactType": "diagnosis",
        "scopeId": "s",
        "runId": "r",
        "generatedAt": "2020-01-01T00:00:00Z",
        "provenance": provenance,
        "warnings": [],
        "verdict": "NOT EXERCISED",
        "legs": [
            {
                "legId": "leg-1",
                "duringWindow": cited,
                "outsideWindow": {
                    "value": None,
                    "caveat": "log analytics query failed",
                    "provenance": provenance,
                },
                "result": "indeterminate",
                "caveat": "outside-window control unavailable",
            }
        ],
        "mechanismLiveness": {"live": None, "evidence": [], "caveat": "not observed"},
        "failureMechanismClass": None,
    }


def test_valid_artifact_validates_and_provenanceless_one_does_not():
    jsonschema = pytest.importorskip("jsonschema")
    schema = _schema("diagnosis")

    jsonschema.validate(_valid_diagnosis(), schema)

    without_provenance = _valid_diagnosis()
    del without_provenance["legs"][0]["duringWindow"]["provenance"]
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(without_provenance, schema)

    # A missing value must still carry its caveat key; dropping it is a
    # contract violation, not a shortcut.
    without_caveat = _valid_diagnosis()
    del without_caveat["legs"][0]["outsideWindow"]["caveat"]
    with pytest.raises(jsonschema.ValidationError):
        jsonschema.validate(without_caveat, schema)


# ---------------------------------------------------------------------------
# E2-T2 — durable location and F12 survival
# ---------------------------------------------------------------------------


def test_default_root_is_per_user_app_data_not_a_repo_or_tmp_path(monkeypatch):
    monkeypatch.delenv(ev.EVIDENCE_ROOT_ENV, raising=False)
    root = ev.evidence_root()
    parts = [p.lower() for p in root.parts]
    assert "chaos-studio" in parts and root.name == "evidence"
    assert "tmp" not in parts, "F12: the store must not live under any tmp/ path"
    assert PLUGIN_ROOT.resolve() not in root.resolve().parents


def test_key_dir_default_is_outside_the_evidence_root(monkeypatch):
    monkeypatch.delenv(ev.EVIDENCE_ROOT_ENV, raising=False)
    monkeypatch.delenv(ev.KEY_DIR_ENV, raising=False)
    root = ev.evidence_root().resolve()
    keys = ev.key_dir().resolve()
    assert keys != root and root not in keys.parents


def test_evidence_survives_tmp_wipe(tmp_path, monkeypatch):
    """F12 — artifacts resolve from $CHAOS_EVIDENCE_ROOT with tmp/ deleted."""
    repo = tmp_path / "repo"
    session_tmp = repo / "tmp"
    session_tmp.mkdir(parents=True)
    (session_tmp / "startchaos-state.json").write_text("{}", encoding="utf-8")

    durable_root = tmp_path / "appdata" / "chaos-studio" / "evidence"
    monkeypatch.setenv(ev.EVIDENCE_ROOT_ENV, str(durable_root))
    monkeypatch.setenv(ev.KEY_DIR_ENV, str(tmp_path / "appdata" / "chaos-studio" / "keys"))

    assert ev.evidence_put(SCOPE, RUN, "run-record.json", {"scenarioRunId": "abc"})["ok"]

    # The second F12 wipe took the whole repo tmp/ tree with it.
    shutil.rmtree(session_tmp)
    assert not session_tmp.exists()

    got = ev.evidence_get(SCOPE, RUN, "run-record.json")
    assert got["ok"] is True
    assert got["result"]["data"]["scenarioRunId"] == "abc"


def test_put_get_round_trip_and_revision_counter(store):
    first = ev.evidence_put(SCOPE, RUN, "state.json", {"run": {"status": "pending"}})
    second = ev.evidence_put(SCOPE, RUN, "state.json", {"run": {"status": "done"}})
    assert first["result"]["revision"] == 1
    assert second["result"]["revision"] == 2

    got = ev.evidence_get(SCOPE, RUN, "state.json")
    assert got["result"]["revision"] == 2
    assert got["result"]["data"]["run"]["status"] == "done"
    assert got["result"]["evidenceSchemaVersion"] == 1


def test_put_result_carries_the_final_contract_fields(store):
    """§API Contracts: `evidence_put` → `{path, revision, digest, redactions[]}`."""
    result = ev.evidence_put(SCOPE, RUN, "state.json", {"a": 1})["result"]
    assert set(result) >= {"path", "revision", "digest", "redactions"}
    assert result["revision"] == 1
    assert result["redactions"] == []
    assert Path(result["path"]).is_file()
    assert len(result["digest"]) == 64


def test_get_result_carries_the_final_contract_fields(store):
    """§API Contracts: `evidence_get` → `{artifact, revision, digest, path}`."""
    put = ev.evidence_put(SCOPE, RUN, "state.json", {"a": 1})["result"]
    got = ev.evidence_get(SCOPE, RUN, "state.json")["result"]
    assert set(got) >= {"artifact", "revision", "digest", "path"}
    assert got["artifact"] == {"a": 1}
    # `artifact` is the redacted payload, i.e. exactly what `data` already held.
    assert got["artifact"] == got["data"]
    assert got["digest"] == put["digest"]
    assert got["path"] == put["path"]


def test_put_reports_the_paths_it_redacted_without_echoing_the_secret(store):
    result = ev.evidence_put(
        SCOPE,
        RUN,
        "state.json",
        {"config": {"clientSecret": "plaintext"}, "notes": [FAKE_KEY], "keep": "fine"},
    )["result"]
    assert set(result["redactions"]) == {"/config/clientSecret", "/notes/0"}
    assert not any(FAKE_KEY in pointer or "plaintext" in pointer for pointer in result["redactions"])


def test_expected_revision_guards_a_lost_update(store):
    """`expected_revision` is the optimistic-concurrency guard (§API Contracts)."""
    # 0 asserts "this item does not exist yet".
    created = ev.evidence_put(SCOPE, RUN, "state.json", {"n": 1}, expected_revision=0)
    assert created["result"]["revision"] == 1

    stale = ev.evidence_put(SCOPE, RUN, "state.json", {"n": 2}, expected_revision=0)
    assert stale["ok"] is False
    assert stale["errorType"] == "EvidenceRevisionMismatch"
    assert stale["expectedRevision"] == 0
    assert stale["actualRevision"] == 1

    fresh = ev.evidence_put(SCOPE, RUN, "state.json", {"n": 2}, expected_revision=1)
    assert fresh["result"]["revision"] == 2
    # The rejected write never landed.
    assert ev.evidence_get(SCOPE, RUN, "state.json")["result"]["artifact"] == {"n": 2}


@pytest.mark.parametrize(
    "bad", ["abc", "1.5", "", "-1", "\u00b2", "\u0967", True, False, 2.0, [], {}]
)
def test_a_non_integer_expected_revision_stays_inside_the_envelope(store, bad):
    """Bad caller input must be a named error, never an escaping exception.

    `expected_revision` is on a model-callable tool and JSON arguments are not
    type-enforced end to end. `True`/`False` are covered explicitly because
    `bool` subclasses `int` and would otherwise coerce to 1/0. The non-ASCII
    digits pin the accepted alphabet to ASCII: `str.isdigit()` is True for
    both, but `int()` rejects the superscript `\u00b2` (which would escape as
    a `ValueError`) and silently accepts the Devanagari `\u0967` as 1.
    """
    result = ev.evidence_put(SCOPE, RUN, "state.json", {"n": 1}, expected_revision=bad)
    assert result["ok"] is False
    assert result["errorType"] == "EvidenceBadRevision"
    # The refused write never landed.
    assert ev.evidence_get(SCOPE, RUN, "state.json")["errorType"] == "EvidenceNotFound"


def test_a_numeric_string_expected_revision_is_accepted(store):
    ev.evidence_put(SCOPE, RUN, "state.json", {"n": 1})
    assert ev.evidence_put(SCOPE, RUN, "state.json", {"n": 2}, expected_revision="1")["ok"]


def test_a_boolean_max_items_does_not_become_a_page_of_one(store):
    for index in range(3):
        ev.evidence_put(SCOPE, RUN, f"item-{index}.json", {"i": index})
    result = ev.evidence_list(SCOPE, RUN, max_items=True)["result"]
    assert len(result["items"]) == 3


def test_artifact_type_is_one_vocabulary_across_put_get_and_list(store):
    """The same string identifies an item on put, get and the list filter."""
    ev.evidence_put(SCOPE, RUN, artifact_type="inventory.v1.json", data={"a": 1})
    assert ev.evidence_get(SCOPE, RUN, "inventory.v1.json")["result"]["artifact"] == {"a": 1}
    assert ev.evidence_get(SCOPE, RUN, artifact_type="inventory.v1.json")["ok"] is True

    listed = ev.evidence_list(SCOPE, RUN, artifact_type="inventory.v1.json")["result"]
    assert [item["name"] for item in listed["items"]] == ["inventory.v1.json"]
    # The filter is exact match on the name, documented in §10 of the contract.
    assert ev.evidence_list(SCOPE, RUN, artifact_type="inventory.v1")["result"]["items"] == []


def test_name_and_artifact_type_disagreeing_is_a_named_error(store):
    clash = ev.evidence_put(SCOPE, RUN, "a.json", {"x": 1}, artifact_type="b.json")
    assert clash["ok"] is False
    assert clash["errorType"] == "EvidenceBadArgument"


def test_scope_items_are_paged_like_run_items(store):
    """The ledger accumulates across every run, so its listing must be bounded."""
    for index in range(5):
        ev.evidence_put(SCOPE, None, f"ledger-{index}.json", {"i": index})

    first = ev.evidence_list(SCOPE, max_items=2)["result"]
    assert [item["name"] for item in first["scopeItems"]] == ["ledger-0.json", "ledger-1.json"]
    assert first["continuationToken"]

    second = ev.evidence_list(SCOPE, max_items=2, continuation_token=first["continuationToken"])
    assert [i["name"] for i in second["result"]["scopeItems"]] == [
        "ledger-2.json",
        "ledger-3.json",
    ]

    last = ev.evidence_list(
        SCOPE, max_items=2, continuation_token=second["result"]["continuationToken"]
    )["result"]
    assert [item["name"] for item in last["scopeItems"]] == ["ledger-4.json"]
    assert last["continuationToken"] is None


def test_scope_scoped_artifacts_outlive_any_run(store):
    """The mechanism-class ledger is keyed by `scopeId`, not `runId` (§Ledger)."""
    ledger = {"entries": [{"mechanismClass": "aks-zone-down", "occurrences": 3}]}
    put = ev.evidence_put(SCOPE, None, "mechanism-ledger.json", ledger)["result"]
    assert put["runId"] is None

    got = ev.evidence_get(SCOPE, None, "mechanism-ledger.json")
    assert got["result"]["artifact"] == ledger

    # It is reachable without knowing any run id, and is not mistaken for a run.
    listed = ev.evidence_list(SCOPE)["result"]
    assert listed["runIds"] == []
    assert [item["name"] for item in listed["scopeItems"]] == ["mechanism-ledger.json"]

    ev.evidence_put(SCOPE, RUN, "state.json", {"a": 1})
    assert ev.evidence_list(SCOPE)["result"]["runIds"] == [RUN]


def test_the_scope_sentinel_is_not_addressable_as_a_run_id(store):
    denied = ev.evidence_put(SCOPE, ev.SCOPE_SCOPED_DIR, "state.json", {"a": 1})
    assert denied["errorType"] == "EvidencePathDenied"


def test_list_filters_by_artifact_type_and_pages(store):
    for index in range(5):
        ev.evidence_put(SCOPE, RUN, f"item-{index}.json", {"i": index})

    first = ev.evidence_list(SCOPE, RUN, max_items=2)["result"]
    assert [item["name"] for item in first["items"]] == ["item-0.json", "item-1.json"]
    assert first["continuationToken"]

    second = ev.evidence_list(
        SCOPE, RUN, max_items=2, continuation_token=first["continuationToken"]
    )["result"]
    assert [item["name"] for item in second["items"]] == ["item-2.json", "item-3.json"]

    last = ev.evidence_list(
        SCOPE, RUN, max_items=2, continuation_token=second["continuationToken"]
    )["result"]
    assert [item["name"] for item in last["items"]] == ["item-4.json"]
    assert last.get("continuationToken") is None

    filtered = ev.evidence_list(SCOPE, RUN, artifact_type="item-3.json")["result"]
    assert [item["name"] for item in filtered["items"]] == ["item-3.json"]


@pytest.mark.parametrize("bad", ["../../etc", "\u00b2", "\u0967"])
def test_a_forged_continuation_token_is_refused(store, bad):
    """Only ASCII-digit tokens issued by `evidence_list` are honoured.

    The non-ASCII digits are `str.isdigit()` but are not tokens this module
    ever issues: `\u00b2` would escape `int()` as a `ValueError` and `\u0967`
    would silently decode as offset 1.
    """
    ev.evidence_put(SCOPE, RUN, "state.json", {"a": 1})
    refused = ev.evidence_list(SCOPE, RUN, continuation_token=bad)
    assert refused["ok"] is False
    assert refused["errorType"] == "EvidenceBadToken"


def test_get_missing_item_is_a_named_error(store):
    result = ev.evidence_get(SCOPE, RUN, "nope.json")
    assert result["ok"] is False
    assert result["errorType"] == "EvidenceNotFound"


def test_list_walks_scopes_runs_and_items_without_contents(store):
    ev.evidence_put(SCOPE, RUN, "state.json", {"secretless": True})
    ev.evidence_put(SCOPE, RUN, "metrics.json", {"a": 1}, kind="raw")

    assert ev.evidence_list()["result"]["scopeHashes"] == [SCOPE]
    assert ev.evidence_list(SCOPE)["result"]["runIds"] == [RUN]

    items = ev.evidence_list(SCOPE, RUN)["result"]["items"]
    assert {(i["name"], i["kind"]) for i in items} == {
        ("state.json", "artifacts"),
        ("metrics.json", "raw"),
    }
    assert all("data" not in item for item in items)


def test_concurrent_puts_serialize_into_a_monotonic_revision(store):
    writers = 12
    errors: list[dict] = []

    def write(index: int) -> None:
        result = ev.evidence_put(SCOPE, RUN, "state.json", {"writer": index})
        if not result["ok"]:
            errors.append(result)

    threads = [threading.Thread(target=write, args=(i,)) for i in range(writers)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert not errors, errors
    final = ev.evidence_get(SCOPE, RUN, "state.json")
    assert final["ok"] is True
    # Every writer's read-modify-write ran under the lock, so no revision was lost.
    assert final["result"]["revision"] == writers
    # And no partial write ever reached the file.
    raw = (store / SCOPE / RUN / "artifacts" / "state.json").read_text(encoding="utf-8")
    json.loads(raw)


def test_no_lock_or_temp_files_are_left_behind(store):
    ev.evidence_put(SCOPE, RUN, "state.json", {"a": 1})
    leftovers = [
        p.name
        for p in (store / SCOPE / RUN / "artifacts").iterdir()
        if p.name.endswith(".lock") or ".tmp." in p.name
    ]
    assert leftovers == []


def test_powershell_written_envelope_is_readable(store):
    """Cross-session access is the only reason this module exists.

    `scripts/State.ps1` writes the same envelope shape; a run mirrored by the
    PowerShell half must be readable by the MCP half without conversion.
    """
    target = store / SCOPE / RUN / "artifacts"
    target.mkdir(parents=True)
    (target / "state.json").write_text(
        json.dumps(
            {
                "evidenceSchemaVersion": 1,
                "scopeHash": SCOPE,
                "runId": RUN,
                "kind": "artifacts",
                "name": "state.json",
                "revision": 7,
                "writtenAt": "2020-01-01T00:00:00.0000000Z",
                "redacted": True,
                "data": {"run": {"status": "done"}},
            }
        ),
        encoding="utf-8",
    )

    got = ev.evidence_get(SCOPE, RUN, "state.json")
    assert got["result"]["revision"] == 7
    # A subsequent MCP write continues the PowerShell revision series.
    assert ev.evidence_put(SCOPE, RUN, "state.json", {"run": {}})["result"]["revision"] == 8


def test_corrupt_item_is_reported_not_silently_swallowed(store):
    target = store / SCOPE / RUN / "artifacts"
    target.mkdir(parents=True)
    (target / "state.json").write_text("{not json", encoding="utf-8")
    result = ev.evidence_get(SCOPE, RUN, "state.json")
    assert result["ok"] is False
    assert result["errorType"] == "EvidenceCorrupt"


# ---------------------------------------------------------------------------
# E2-T3 — redaction
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "key",
    [
        "key",
        "secret",
        "clientSecret",
        "accessToken",
        "connectionString",
        "k_session",
        "approvalKey",
        "Authorization",
        "sharedAccessKey",
    ],
)
def test_secret_bearing_keys_are_redacted(store, key):
    ev.evidence_put(SCOPE, RUN, "state.json", {key: "plaintext-value", "keep": "fine"})
    data = ev.evidence_get(SCOPE, RUN, "state.json")["result"]["data"]
    assert data[key] == ev.REDACTED
    assert data["keep"] == "fine"


def test_secret_shaped_values_are_redacted_under_innocuous_keys(store):
    ev.evidence_put(
        SCOPE,
        RUN,
        "state.json",
        {
            "note": FAKE_KEY,
            "header": "Bearer abcdefghijklmnopqrstuvwxyz0123456789",
            "nested": [{"deep": FAKE_KEY}],
        },
    )
    data = ev.evidence_get(SCOPE, RUN, "state.json")["result"]["data"]
    assert data["note"] == ev.REDACTED
    assert data["header"] == ev.REDACTED
    assert data["nested"][0]["deep"] == ev.REDACTED


def test_redaction_happens_on_write_so_disk_is_clean(store):
    ev.evidence_put(SCOPE, RUN, "state.json", {"note": FAKE_KEY})
    raw = (store / SCOPE / RUN / "artifacts" / "state.json").read_text(encoding="utf-8")
    assert FAKE_KEY not in raw


def test_redaction_does_not_mangle_ordinary_azure_values(store):
    resource_id = (
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-chaos"
        "/providers/Microsoft.Chaos/workspaces/ws-chaos"
    )
    ev.evidence_put(
        SCOPE,
        RUN,
        "state.json",
        {
            "resourceId": resource_id,
            "principalId": "11111111-2222-3333-4444-555555555555",
            "collectedAt": "2020-01-01T00:00:00Z",
            "count": 0,
        },
    )
    data = ev.evidence_get(SCOPE, RUN, "state.json")["result"]["data"]
    assert data["resourceId"] == resource_id
    assert data["principalId"] == "11111111-2222-3333-4444-555555555555"
    assert data["collectedAt"] == "2020-01-01T00:00:00Z"
    # A measured zero survives redaction untouched (NFR-3).
    assert data["count"] == 0


# ---------------------------------------------------------------------------
# E2-T3 — path canonicalization and the key denylist
# ---------------------------------------------------------------------------


def _flatten(value) -> str:
    return json.dumps(value, default=str)


def test_evidence_get_cannot_reach_key_material(store, tmp_path):
    """The approval boundary. If this fails, CI must block the build.

    Asserts denial for a direct path, a traversal, a symlink and an absolute
    path — and that no `evidence_*` result ever contains the key bytes.
    """
    key_file = Path(os.environ[ev.KEY_DIR_ENV]) / "session.key"
    assert key_file.read_text(encoding="utf-8") == FAKE_KEY

    denied = []
    other = []

    # 1. Direct path — the key file name inside the store resolves to nothing;
    #    it must never fall through to the key directory.
    other.append(ev.evidence_get(SCOPE, RUN, "session.key"))
    denied.append(ev.evidence_list("..", None))

    # 2. Traversal out of the root.
    for traversal in ("../key-dir/session.key", "..\\key-dir\\session.key", "a/../../session.key"):
        denied.append(ev.evidence_get(SCOPE, RUN, traversal))
        denied.append(ev.evidence_put(SCOPE, RUN, traversal, {"x": 1}))
    denied.append(ev.evidence_get(SCOPE, "..", "session.key"))

    # 3. Absolute path.
    denied.append(ev.evidence_get(SCOPE, RUN, str(key_file)))
    denied.append(ev.evidence_put(SCOPE, RUN, str(key_file), {"x": 1}))

    # 4. Symlink planted *inside* the root pointing at the key directory.
    link_parent = store / SCOPE / RUN / "artifacts"
    link_parent.mkdir(parents=True, exist_ok=True)
    link = link_parent / "leak.json"
    try:
        link.symlink_to(key_file)
    except (OSError, NotImplementedError):
        link = None
    if link is not None:
        denied.append(ev.evidence_get(SCOPE, RUN, "leak.json"))
        denied.append(ev.evidence_put(SCOPE, RUN, "leak.json", {"x": 1}))

    for result in denied:
        assert result["ok"] is False, f"unexpectedly permitted: {result}"
        assert result["errorType"] == "EvidencePathDenied", result
    for result in other:
        assert result["ok"] is False, f"unexpectedly permitted: {result}"

    # And nothing anywhere ever echoed the key bytes back.
    for result in denied + other:
        assert FAKE_KEY not in _flatten(result)
    assert FAKE_KEY not in _flatten(ev.evidence_list())
    assert FAKE_KEY not in _flatten(ev.evidence_list(SCOPE, RUN))
    assert key_file.read_text(encoding="utf-8") == FAKE_KEY, "key file was modified"


def test_symlinked_directory_escape_is_denied(store, tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "loot.json").write_text('{"revision": 1, "data": {"k": "v"}}', encoding="utf-8")
    link = store / SCOPE
    link.parent.mkdir(parents=True, exist_ok=True)
    try:
        link.symlink_to(outside, target_is_directory=True)
    except (OSError, NotImplementedError):  # pragma: no cover - unprivileged Windows
        pytest.skip("symlink creation is not permitted in this environment")

    result = ev.evidence_get(SCOPE, RUN, "loot.json")
    assert result["ok"] is False
    assert result["errorType"] == "EvidencePathDenied"


@pytest.mark.parametrize("segment", ["..", ".", "a/b", "a\\b", "", "-lead", "x" * 200])
def test_structural_segments_are_strictly_validated(store, segment):
    assert ev.evidence_get(segment, RUN, "state.json")["errorType"] == "EvidencePathDenied"
    assert ev.evidence_get(SCOPE, segment, "state.json")["errorType"] == "EvidencePathDenied"


def test_unknown_kind_is_rejected(store):
    result = ev.evidence_put(SCOPE, RUN, "state.json", {}, kind="../../etc")
    assert result["errorType"] == "EvidencePathDenied"


@pytest.mark.skipif(sys.platform != "win32", reason="drive-qualified paths are Windows-only")
def test_drive_qualified_and_unc_paths_are_denied(store):
    assert ev.evidence_get(SCOPE, RUN, "C:/Windows/win.ini")["errorType"] == "EvidencePathDenied"
    for candidate in ("C:/Windows/win.ini", "//server/share/secret.txt", "\\\\server\\share\\x"):
        with pytest.raises(ev.EvidenceError):
            ev.resolve_within_root(candidate)


def test_retention_default_is_ninety_days_and_prune_is_bounded(store, monkeypatch):
    monkeypatch.delenv(ev.RETENTION_DAYS_ENV, raising=False)
    assert ev.retention_days() == 90

    ev.evidence_put(SCOPE, RUN, "state.json", {"a": 1})
    kept = ev.evidence_prune()
    assert kept["result"]["removed"] == []
    assert ev.evidence_get(SCOPE, RUN, "state.json")["ok"] is True

    # A non-positive or unparseable override falls back to the documented default
    # rather than pruning everything.
    monkeypatch.setenv(ev.RETENTION_DAYS_ENV, "-1")
    assert ev.retention_days() == 90
    monkeypatch.setenv(ev.RETENTION_DAYS_ENV, "not-a-number")
    assert ev.retention_days() == 90


# ---------------------------------------------------------------------------
# E2-T3 — MCP surface
# ---------------------------------------------------------------------------


def test_server_exposes_exactly_three_evidence_tools():
    from test_tool_manifest import EVIDENCE_TOOLS, ORIGINAL_FIFTEEN_TOOLS

    assert EVIDENCE_TOOLS == {
        "chaos_evidence_put",
        "chaos_evidence_get",
        "chaos_evidence_list",
    }
    assert not (EVIDENCE_TOOLS & ORIGINAL_FIFTEEN_TOOLS)
    for name in EVIDENCE_TOOLS:
        assert callable(getattr(srv, name))


def test_server_wrappers_delegate_to_the_module(store):
    assert srv.chaos_evidence_put(SCOPE, RUN, "state.json", {"a": 1})["ok"] is True
    assert srv.chaos_evidence_get(SCOPE, RUN, "state.json")["result"]["data"]["a"] == 1
    assert srv.chaos_evidence_list(SCOPE, RUN)["result"]["items"][0]["name"] == "state.json"
    denied = srv.chaos_evidence_get(SCOPE, RUN, "../session.key")
    assert denied["errorType"] == "EvidencePathDenied"


def test_server_wrappers_expose_the_final_contract_parameters():
    import inspect

    put = inspect.signature(srv.chaos_evidence_put).parameters
    assert "expected_revision" in put
    assert "artifact_type" in put
    assert put["run_id"].default is None

    get = inspect.signature(srv.chaos_evidence_get).parameters
    assert "artifact_type" in get
    assert get["run_id"].default is None

    listed = inspect.signature(srv.chaos_evidence_list).parameters
    assert {"artifact_type", "max_items", "continuation_token"} <= set(listed)


# ---------------------------------------------------------------------------
# E2-T4 — shared contracts
# ---------------------------------------------------------------------------


def test_reference_contracts_exist_and_state_the_invariants():
    contract = (REFERENCE_DIR / "evidence-contract.md").read_text(encoding="utf-8")
    matrix = (REFERENCE_DIR / "verdict-matrix.md").read_text(encoding="utf-8")

    for phrase in (
        "$CHAOS_EVIDENCE_ROOT",
        "$CHAOS_KEY_DIR",
        "k_session",
        "symlink",
        "mirrored, never relocated",
        "revision",
        # §10 must remove the silent-empty-filter trap: exact match on the name.
        "match on that same name",
        "deprecated alias",
    ):
        assert phrase in contract, f"evidence-contract.md does not state: {phrase}"

    for verdict in ("CONFIRMED", "REFUTED", "NOT EXERCISED"):
        assert verdict in matrix
    assert "two-sided" in matrix
    assert "Mechanism liveness" in matrix
    # Stale evidence can never produce CONFIRMED.
    assert "never" in matrix and "stale" in matrix.lower()


def test_prototype_state_engine_is_not_copied():
    contract = (REFERENCE_DIR / "evidence-contract.md").read_text(encoding="utf-8")
    assert "chaos_loop_state.py" in contract, (
        "the do-not-port constraint must be stated where implementers read it"
    )


# ---------------------------------------------------------------------------
# E2-T1/E2-T2 — the PowerShell half's contract, pinned from the Python matrix
# ---------------------------------------------------------------------------


def test_state_ps1_mirrors_and_never_relocates():
    state_ps1 = STATE_PS1.read_text(encoding="utf-8-sig")
    assert "$script:StateSchemaVersion = 1" in state_ps1, "state schema v1 must keep resuming"
    assert "function Import-State" in state_ps1
    assert "function Write-EvidenceArtifact" in state_ps1
    assert "function Get-EvidenceRoot" in state_ps1
    assert "CHAOS_EVIDENCE_ROOT" in state_ps1
    # The state path is still read from the same environment variable.
    assert "$env:STARTCHAOS_STATE_PATH" in state_ps1


def test_state_ps1_and_python_redact_the_same_key_names():
    state_ps1 = STATE_PS1.read_text(encoding="utf-8-sig")
    for hint in ("clientsecret", "connectionstring", "k_session", "approval_key", "bearer"):
        assert hint in state_ps1, (
            f"State.ps1 does not redact '{hint}' but chaos_mcp.evidence does; the two "
            "surfaces write into the same store and must not drift"
        )
