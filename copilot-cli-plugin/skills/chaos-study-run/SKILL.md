---
name: chaos-study-run
description: "Execute a frozen Chaos study plan against Azure: verify plan integrity, require an explicit typed consent phrase, collect baseline evidence, inject the fault, collect during and post-recovery evidence, and always clean up the experiment. Dry-run by default."
---

# chaos-study-run — the only phase that changes production

Everything before this is analysis. This skill injects a real fault into a real
cluster, so it is deliberately the most conservative script in the suite.

## Principles

**Dry run is the default.** `-DryRun` defaults to `$true`. A dry run walks the
entire sequence — plan verification, consent rendering, the exact request body —
and injects nothing. Read it before arming anything.

**Consent is typed, not flagged.** Arming requires `-DryRun:$false` **and**
`-Consent` matching the phrase the plan prints, exactly. A wrong phrase exits
`11`. There is no `-Yes`, no `-Force` that bypasses it, and no environment
variable that pre-approves it.

**The plan is verified, not trusted.** The plan hash is recomputed before
injection. Any drift since scoping exits `12`. If the blast radius changed after
you approved it, this refuses rather than injecting something you did not review.

**Evidence is collected around the fault, not just during it.** Baseline, during,
and post windows are all collected. Without baseline there is no "normal" to
compare to; without post there is no way to tell degradation from damage.

**Missing evidence stays missing.** A collector that fails records `null` and a
reason. Nothing is interpolated, averaged, or inferred to fill a gap — the report
would rather say *not measured* than mislead.

**Cleanup is unconditional.** The experiment is deleted in a `finally` block, so
a crash, a Ctrl-C, or a failed collection still tears the fault down. Use
`-KeepExperiment` only when you intend to inspect it afterwards.

**Sealed studies are immutable.** Re-running a sealed study exits `13`. Re-test
by scoping a new one, so history stays comparable.

## Usage

**Preview** (this is the default, and injects nothing):

```powershell
./scripts/Invoke-ChaosStudyRun.ps1 -StudyId latest
```

**Arm it**, using the phrase the preview printed:

```powershell
./scripts/Invoke-ChaosStudyRun.ps1 -StudyId latest -DryRun:$false `
    -Consent 'INJECT aks-prod payments'
```

Switches worth knowing:

- `-SignalSource` — add evidence sources beyond the plan's defaults
- `-Location` — where the experiment resource is created
- `-PollSeconds` — experiment status poll interval
- `-KeepExperiment` — leave the experiment for inspection (it stays stopped)

## What actually happens

1. Load the plan and re-verify its hash
2. Re-verify the fault path is still open
3. Render the consent phrase and require it back verbatim
4. Collect the **baseline** window
5. Create and start the experiment; poll until it completes
6. Collect the **during** window while the fault is live
7. Wait out recovery, then collect the **post** window
8. Delete the experiment (always), write `run-record.v1.json` and evidence

## Implementation note

Injection uses the `Microsoft.Chaos/experiments` resource surface via ARM, not
the `az chaos` extension. The extension targets the newer workspace/scenario
model; experiments are the surface that supports the direct fault injection this
study method needs. Api-versions are pinned centrally so a service-side default
change cannot silently alter behaviour.

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success (including a completed dry run) |
| `1` | Error |
| `11` | Consent declined or phrase mismatch |
| `12` | Plan changed after it was frozen |
| `13` | Study already sealed |
| `14` | Fault path no longer available |

## If it fails partway

The study state on disk reflects exactly how far it got, and whatever evidence
was collected is kept. Because reporting is a pure read of that evidence, a
partial run can still be reported — the report will simply carry the gaps as
explicit limitations rather than hiding them.

## Next

```powershell
chaos-study-report -StudyId <studyId>
```

See `../chaos-study/references/study-method.md` for how the windows are chosen
and `../chaos-study/references/faults/<name>.md` for per-fault blast radius.
