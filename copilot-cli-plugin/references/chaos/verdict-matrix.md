# Verdict matrix

How `diagnosis.v1` reaches `CONFIRMED`, `REFUTED` or `NOT EXERCISED`. The
matrix is evaluated by **deterministic code**. The model owns the narrative
around a verdict; it never owns the verdict itself.

## 1. Inputs

Every verdict needs three independent inputs, each of which is a first-class
field in `diagnosis.v1.schema.json`:

1. **Per-leg two-sided proof.** Each hypothesis leg contributes a
   `duringWindow` and an `outsideWindow` `citedNumber`. One side alone is not
   proof: a signal that is elevated during the fault window *and* elevated
   outside it did not measure the fault.
2. **Mechanism liveness.** Did the fault mechanism actually run? A scenario
   that reported `Succeeded` while its action never reached a target is
   `NOT EXERCISED`, not `REFUTED`.
3. **Failure-mechanism class.** What kind of failure the run exercised, or
   `null` when the run exercised nothing classifiable.

## 2. Per-leg result

| `duringWindow.value` | `outsideWindow.value` | Separation | `result` |
|---|---|---|---|
| non-null | non-null | expected direction, outside window is the control | `proved` |
| non-null | non-null | no separation, or separation in the wrong direction | `disproved` |
| `null` | any | — | `indeterminate` (caveat required) |
| any | `null` | — | `indeterminate` (caveat required) |

`0` is a measurement and participates normally. `null` never does: it produces
`indeterminate` and a caveat naming why the value is missing. Treating `null`
as `0` here would manufacture a `proved` leg out of a failed query, which is
exactly the failure NFR-3 exists to prevent.

## 3. Verdict

| Mechanism liveness | Legs | Any leg stale | Verdict |
|---|---|---|---|
| `live == false` | any | any | `NOT EXERCISED` |
| `live == null` | any | any | `NOT EXERCISED` (caveat: liveness unknown) |
| `live == true` | all legs `proved` | no | `CONFIRMED` |
| `live == true` | all legs `proved` | **yes** | `NOT EXERCISED` (caveat: stale evidence) |
| `live == true` | any leg `disproved`, none `indeterminate` | any | `REFUTED` |
| `live == true` | any leg `indeterminate` | any | `NOT EXERCISED` |

Rules that follow from the table and are worth stating outright:

- **`CONFIRMED` requires every leg proved, on fresh evidence, with a live
  mechanism.** Anything weaker is `NOT EXERCISED` or `REFUTED`.
- **Stale evidence can never produce `CONFIRMED`.** It downgrades to
  `NOT EXERCISED` with an explicit warning; it does not silently pass.
- **`REFUTED` is a real result and requires real measurements.** A run whose
  legs are `indeterminate` did not refute anything — it failed to measure.
- **`NOT EXERCISED` is the safe default.** Whenever the matrix cannot justify
  `CONFIRMED` or `REFUTED`, the verdict is `NOT EXERCISED` plus a caveat.

## 4. Ledger effect

Every verdict appends one occurrence to `mechanism-ledger.v1` for the scope,
keyed by `mechanismId`, carrying `runId`, `observedAt`, the verdict and its
provenance. Occurrences accumulate; `chaos-diagnose` appends and never
rewrites, and `chaos-analyze` reads the accumulation to weight future
hypotheses (FR-17).
