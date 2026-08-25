# Evidence contract

Shared, field-derived rules for everything the plugin records. Every artifact
under `copilot-cli-plugin/schemas/*.v1.schema.json` encodes these rules; the
schemas are the enforcement, this document is the rationale.

This contract **re-expresses** the invariants that the never-merged PR #32
prototype arrived at (atomic locked writes, monotonic revisions, evaluate-then-
commit proposals). It does **not** port that prototype's state engine, its
`chaos_loop_state.py`, or its `run-state` / `external-gate` / `workspace-plan`
schemas. The focused artifacts here cover the retained concepts and nothing
else.

## 1. Storage

| | |
|---|---|
| Source of truth | `$STARTCHAOS_STATE_PATH` (default `./startchaos-state.json`) |
| Durable mirror | `$CHAOS_EVIDENCE_ROOT/<scopeHash>/<runId>/{artifacts,raw,rendered}` |
| Scope-keyed artifacts | `$CHAOS_EVIDENCE_ROOT/<scopeHash>/_scope/{artifacts,raw,rendered}` |
| Default root | Windows `%LOCALAPPDATA%\chaos-studio\evidence`; macOS `~/Library/Application Support/chaos-studio/evidence`; Linux `${XDG_DATA_HOME:-~/.local/share}/chaos-studio/evidence` |
| Retention | 90 days (`$CHAOS_EVIDENCE_RETENTION_DAYS`), pruned by `evidence_prune` |
| Expected size | low single-digit MB per run |

The state file is **mirrored, never relocated**. A state file written by an
earlier version imports forward through `Import-State`: missing sections are
filled from defaults, existing keys — including keys this version does not
recognise — are preserved verbatim, and the schema version is not bumped.

The evidence root is deliberately outside the repository and outside any
session `tmp/`. Field evidence F12 recorded two `tmp/` wipes; the second also
took `memories/sessionInsights/`, costing two runs and forcing manual mode.
Recovery entry points are `chaos-diagnose --run-id` and `chaos-evidence
--run-id`, both of which read the mirror, not the repository.

## 2. Atomicity and revisions

Every evidence write is:

1. serialized on an exclusive lock file scoped to the item, so the
   read-revision / write-revision pair cannot interleave;
2. written to a temporary file in the same directory and moved into place, so
   a reader never observes a partial artifact;
3. stamped with a monotonically increasing `revision`, starting at 1.

A caller that has already read an item passes `expected_revision` on the next
write — or `0` to assert the item does not yet exist. If the item has moved on,
the write is refused with `EvidenceRevisionMismatch` carrying both revisions,
so a lost update is reported rather than silently applied.

A corrupt prior revision is reported and superseded; it never blocks the
current write.

## 3. Provenance — mandatory

Every evidence item carries:

- `source.tool` — which tool produced it;
- `source.apiVersion` — the pinned REST version, or `null` when the source is
  not a versioned REST surface;
- `source.query` — the KQL / OData / ARM path it was read from, or `null`;
- `collectedAt` — ISO 8601 UTC.

**An item without provenance is invalid and is rejected by schema
validation.** There is no "unknown provenance" state.

## 4. Confidence

`high` | `medium` | `low`. Assigned **by code**, from the collection method —
never chosen by the model. A direct authoritative query is `high`; a derived
or joined value is `medium`; an inferred or partial value is `low`.

## 5. Freshness

`collectedAt` + `maxAgeMinutes` yields a computed `stale` boolean. A stale
artifact is usable **only with an explicit warning** and **never** for a
`CONFIRMED` verdict.

## 6. Missing data — `null` plus a caveat

Missing data is represented as `null` **plus** a `caveat` string naming why.
Omitting the field entirely is a contract violation, because a reader cannot
distinguish an omitted field from a field that was never part of the shape.

## 7. Null vs zero (NFR-3)

- A cited `0` means **"measured zero from a successful query"**.
- Absence, query failure, or an unqueryable source is **`null`**, with a
  caveat.

Substituting `0` for `null` fabricates a measurement and is the single most
damaging failure mode in this codebase. `citedNumber` exists so the two cases
cannot be conflated: it requires `value`, `caveat` and `provenance` together.

## 8. Security boundary

The evidence store is fronted by the model-callable `chaos_evidence_get`
tool. Anything reachable through that tool is reachable by the model.
Therefore:

- The approval key `k_session` is **never** stored in the evidence store. It
  is delivered to the server process out of band — an OS keyring entry
  (`chaos-approval-<sessionId>`), else `$CHAOS_KEY_DIR/session.key` with a
  user-only ACL, else an environment variable on the server process. It never
  appears in a tool argument, a tool result, an artifact, or a log line.
- `$CHAOS_KEY_DIR` lives **outside** `$CHAOS_EVIDENCE_ROOT` and is on an
  explicit `evidence_*` path denylist.
- `chaos_evidence_get` / `chaos_evidence_put` / `chaos_evidence_list` resolve
  every requested path against `$CHAOS_EVIDENCE_ROOT` **after symlink
  resolution** and reject anything outside it. Absolute paths, drive-qualified
  paths, UNC paths and `..` traversal are rejected before resolution.
- Redaction runs on **write and on read**, by key name and by value shape, so
  key material that reached an artifact by accident still cannot leave through
  a tool result. `evidence_put` reports the JSON Pointers it redacted in
  `redactions[]` — locations only, never the suppressed values.

`test_evidence_get_cannot_reach_key_material` asserts all of this for a direct
path, a traversal, a symlink and an absolute path, and asserts that no
`evidence_*` result ever contains the key bytes. If that test fails the
approval boundary is void and CI blocks the build.

## 9. Artifact family

Focused artifacts, one concern each — there is no monolithic state
replacement:

| Artifact | Written by | Read by |
|---|---|---|
| `scope-setup.v1` | `chaos-scope-setup` | everything downstream |
| `inventory.v1` | `chaos-inventory` | `chaos-analyze`, `chaos-recommend` |
| `availability.v1` | `chaos-availability` | `chaos-analyze` |
| `hypotheses.v1` | `chaos-analyze` | `chaos-run`, `chaos-diagnose` |
| `recommendations.v1` | `chaos-recommend` | operator, `chaos-run` |
| `run-record.v1` | `chaos-run` | `chaos-diagnose` |
| `diagnosis.v1` | `chaos-diagnose` | `chaos-evidence` |
| `evidence-bundle.v1` | `chaos-evidence` | operator |
| `mechanism-ledger.v1` | `chaos-diagnose` (append only) | `chaos-analyze` |

`mechanism-ledger.v1` is keyed on `scopeId` and **accumulates** occurrences.
Rewriting it in place, or replacing occurrences rather than appending, loses
the cross-run signal it exists to provide (FR-17). Because it must outlive any
single run it is written with `run_id` omitted, landing under `_scope/`, which
`evidence_prune` never removes. `_scope` cannot collide with a real run id:
structural segments must start with an alphanumeric character.

## 10. Listing, naming and paging

An evidence item's identity is its **name** — the file name it is written
under. `evidence_put` and `evidence_get` accept it as either `name` or
`artifact_type`; the two spellings are interchangeable aliases for the same
string, and passing both with different values is refused with
`EvidenceBadArgument`. `evidence_list`'s `artifact_type` filter is an **exact
string match on that same name**, not a prefix or a stem: an item written as
`inventory.v1.json` matches `artifact_type: "inventory.v1.json"` and does not
match `"inventory.v1"`. A filter that matches nothing returns an empty page,
not an error, so the filter string must be the name exactly as written.

`evidence_list` returns metadata only, never item contents. With no arguments
it lists scopes; with a scope it lists that scope's `runIds` plus its
`scopeItems`; with a scope and a run it lists `items[]`. Both item listings —
run `items[]` and scope `scopeItems[]`, the latter accumulating across every
run in the scope — are paged: `continuationToken` is present only while more
items remain, and a token not issued by `evidence_list` is refused with
`EvidenceBadToken`.

`evidence_get` returns the stored payload as **`artifact`**, which is the
contract name. `data` is a deprecated alias carrying the same object, retained
only because it is the envelope field the PowerShell mirror writes; a later
epic may drop it, and no reader should depend on it. `evidence_put` likewise
returns the one SHA-256 of the stored bytes under both `digest` (the contract
name) and the deprecated alias `sha256`; the two are always equal.

`expected_revision` must be a non-negative integer, written either as an
integer or as a string of ASCII digits. A non-numeric value — including a
non-ASCII digit character such as a superscript or a Devanagari digit, which
Python reports as a digit but which is not a revision this store ever issued —
is refused with `EvidenceBadRevision` rather than raising, so every failure
mode of every evidence tool stays inside the `{ok, errorType, error}`
envelope. `continuation_token` is constrained the same way and is refused with
`EvidenceBadToken`.

## 11. The study store boundary

The **evidence store** and the **study store** are two different things with
two different lifetimes, and conflating them is the mistake this section
exists to prevent.

| | Evidence store | Study store |
|---|---|---|
| Root | `$CHAOS_EVIDENCE_ROOT` | `$CHAOS_STUDY_ROOT` |
| Default | `…/chaos-studio/evidence` | `…/chaos-studio/studies` |
| Unit | a run's working artifacts | a dated, sealed, reportable **study** |
| Mutability | revisioned; the newest revision wins | append-then-**seal**; a sealed study is terminal |
| Lifetime | 90 days (`$CHAOS_EVIDENCE_RETENTION_DAYS`) | 365 days (`$CHAOS_STUDY_RETENTION_DAYS`) |
| Written by | `Save-State`, `evidence_put` | `Study.ps1` |
| Purpose | resumability and diagnosis | comparison, review and reproduction |

Neither root is overloaded onto the other, and the `[E2]` variables
(`CHAOS_EVIDENCE_ROOT`, `CHAOS_KEY_DIR`, `CHAOS_EVIDENCE_RETENTION_DAYS`,
`CHAOS_EVIDENCE_DISABLED`) keep exactly their existing meaning. The study store
introduces three of its own: `CHAOS_STUDY_ROOT`, `CHAOS_STUDY_RETENTION_DAYS`
and `CHAOS_STUDY_ABANDON_HOURS`.

### 11.1 Layout and location

```
$CHAOS_STUDY_ROOT/
  <scopeHash>/
    index.json                  rebuildable cache; one record per sealed study
    20260824T184213Z-9f2c1ab4/
      manifest.json             SHA-256 over every file below, excluding
                                itself and SEALED
      study-plan.v1.json
      run-record.v1.json
      findings.v1.json
      report.html
      commands.jsonl            redacted command trail
      evidence/{pre,during,post}/*.json
      SEALED                    presence = immutable
```

`studyId = <UTC yyyyMMdd'T'HHmmss'Z'>-<8 hex of scopeHash‖plan digest‖nonce>` —
sortable, human-dated and collision-resistant, so a rerun over an identical
plan is always a distinct study.

The root resolves in this order: `$env:CHAOS_STUDY_ROOT`, then `studyRoot` in
the nearest `.chaos-plugins.yaml`, then per-user application data
(`%LOCALAPPDATA%\chaos-studio\studies`,
`~/Library/Application Support/chaos-studio/studies`,
`${XDG_DATA_HOME:-~/.local/share}/chaos-studio/studies`). It is **never** the
repository, never `$env:TEMP`, and never next to `startchaos-state.json` — the
same F12 lesson that placed the evidence store outside `tmp/`, applied to
results that are meant to outlive the conversation entirely. The root is
created by the first study; nothing reads it before then.

### 11.2 Lifecycle is the directory, not a status field

| State | Determined by | Transitions |
|---|---|---|
| `PLANNED` | `study-plan.v1.json` present, `SEALED` absent | → `EXECUTED`, → `SEALED` |
| `EXECUTED` | `run-record.v1.json` present, `SEALED` absent | → `SEALED` |
| `SEALED` | `SEALED` marker **and** `manifest.json` present | terminal |
| `ABANDONED` | `PLANNED` older than `$CHAOS_STUDY_ABANDON_HOURS` (default 72) with no run record | → `SEALED` with `outcome: abandoned` |

`Get-Study` derives the state from the files on disk and never reads a status
field, so a study cannot claim to be something the directory contradicts. A
study that crashed mid-execution is `PLANNED` with a partial `evidence/` tree.
An `ABANDONED` study is *reported*, never deleted.

### 11.3 Sealing is a three-step commit

In this exact order, so that a crash at any point leaves a detectably
incomplete study rather than a lying one:

1. render `report.html` into a temp file and rename it into place;
2. hash every file except `manifest.json` and `SEALED` — neither exists yet —
   and write `manifest.json` atomically;
3. create the `SEALED` marker, then append one record to
   `<scopeHash>/index.json`.

Once `SEALED` exists, `Save-StudyArtifact` refuses every write with
`StudyAlreadySealed` (exit code 13). **There is no force flag**, by design: a
mutable result cannot be compared and cannot be trusted, so a rerun creates a
new study rather than editing an old one.

`index.json` is a **rebuildable cache, not a source of truth**.
`Get-StudyIndex` answers from a directory scan when the index is missing or
corrupt, and `-Rebuild` reconstructs and rewrites it. A lost index costs a
scan, never a study.

### 11.4 Same safety code, not a copy

The study store is built **on** the primitives above, not beside them: the same
exclusive lock (`Invoke-WithEvidenceLock`), the same temp-file + rename commit
(`Write-EvidenceFileAtomic`), the same scope hash (`Get-EvidenceScopeHash`) and
the same redaction vocabulary (`Get-EvidenceRedactionList`). Redaction runs on
every study write, by key name, by value shape, and — because a token pasted
into an error message or an `az` argv is neither a secret key nor a secret
value in its entirety — by **embedded substring** as well. `$CHAOS_KEY_DIR`
remains outside every store and on the path denylist.

`manifest.json` is written without the embedded-substring scrub, because every
value in it is computed by the sealer and a SHA-256 is itself 64 hex
characters, which the secret-value shapes would otherwise redact.

### 11.5 Portability

`manifest.json` is self-describing: `schemaVersions`, `apiVersions`,
`toolSubstitutions`, the scope descriptor, `faultPath` and `derivedFrom` all
travel with the study. A zipped study unzipped on another machine, under
another root, with no credentials and no network, is read back by
`Get-Study -Path` and verified against its own manifest.
