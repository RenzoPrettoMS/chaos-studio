---
name: chaos-study-history
description: "List, inspect, compare, and re-run past Chaos reliability studies from the dated study store. Answers 'did we fix it?' by diffing findings between two comparable studies of the same scope, and prints the exact command to re-run a study as a new one."
---

# chaos-study-history — did the fix actually work?

A single study is a snapshot. Reliability is a trend. This skill reads the dated
study store so a chat weeks later can pick up exactly where the last one left off.

## Principles

**Studies are immutable.** A sealed study is a historical record. Re-testing
creates a **new** study rather than overwriting the old one — otherwise there is
nothing to compare against and no way to show improvement.

**Only compare like with like.** Two studies are comparable only if the scope,
target, action, target type, and normalised predicate match, and each window is
within ±20% of its counterpart. Anything else exits `15` and explains which
attribute diverged. A comparison across different actions is not evidence.

**Findings are matched by key, not by title.** Every finding carries a stable
`findingKey`. Rewording a title does not make a problem look resolved, and a
genuinely different problem never masquerades as the same one.

**Direction is stated plainly.** `improved`, `regressed`, `stable`, or `unknown`
— and `unknown` is used honestly whenever the evidence does not support a call.

**Re-run prints, it does not inject.** The `rerun` action emits the exact scope
command that reproduces a study. You review it and run it. Nothing is injected
from here. Because scoping re-queries the live action list, a rerun of a study
whose action the platform no longer offers fails loudly instead of silently
testing something else.

## Usage

**List studies:**

```powershell
./scripts/Invoke-ChaosStudyHistory.ps1 -Action list
```

Add `-ScopeHash <hash>` to narrow to one target/action pairing, or `-Json` for
machine-readable output.

**Inspect one:**

```powershell
./scripts/Invoke-ChaosStudyHistory.ps1 -Action show -StudyId <studyId>
```

**Compare** — by default the latest study against the most recent comparable one
in the same scope:

```powershell
./scripts/Invoke-ChaosStudyHistory.ps1 -Action compare
./scripts/Invoke-ChaosStudyHistory.ps1 -Action compare -StudyId <candidate> -Against <baseline>
```

**Re-run** — prints the command that reproduces a study as a new one:

```powershell
./scripts/Invoke-ChaosStudyHistory.ps1 -Action rerun -StudyId <studyId>
```

## Reading a comparison

| Field | Means |
| --- | --- |
| **Resolved** | findings present in the baseline, gone in the candidate |
| **Introduced** | findings new in the candidate |
| **Persisted** | present in both — the fix did not land |
| **Verdict changed** | the overall verdict moved between the two studies |
| **Direction** | improved / regressed / stable / unknown |

"Resolved" is the honest answer to *did we fix it?* — provided the two studies
were comparable, which is exactly why comparability is enforced rather than
assumed.

## The study store

Studies live outside the repository so results are never accidentally committed.
The root is resolved in this order:

1. `CHAOS_STUDY_ROOT`
2. `studyRoot` in `.chaos-plugins.yaml`
3. a per-user application-data path

Layout is `<root>/<scopeHash>/<studyId>/`, where `studyId` is
`<UTC timestamp>-<8 hex>`. The scope hash groups every study of the same
subscription / resource group / resource / type / region, which is what makes
comparison meaningful.

States: `EMPTY`, `PLANNED`, `EXECUTED`, `SEALED`, `ABANDONED`. Only `SEALED`
studies carry a report; the index is rebuilt from disk on every read, so a stale
index can never hide a study.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Error |
| `15` | Studies are not comparable — the reason is printed |

## Notes

- Comparison reads only sealed artifacts. It calls no Azure APIs.
- A scope with a single study reports that plainly rather than inventing a
  baseline to diff against.

See `../chaos-study/references/study-method.md` for why studies are stored dated
and immutable.
