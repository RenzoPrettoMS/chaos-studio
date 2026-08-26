# The study method

This is the reasoning the `chaos-study` suite follows. Read it once; it
explains *why* each skill refuses certain things.

## A study is an experiment, not a test run

A test asserts a known answer. A study asks a question whose answer you do not
know, and produces evidence either way. That difference drives everything here:

- We state a **hypothesis** before we inject anything, so we cannot rationalise
  the result afterwards.
- We measure a **steady state** first. Without it, "it looked fine" is an
  opinion.
- We record **what we could not measure** as prominently as what we could.
  A study that hides its blind spots is worse than no study, because it
  manufactures confidence.

## The five phases

### 1. Scope

Decide *what system*, *what fault*, and *what would count as a failure* —
before touching anything.

The output is a **study plan**: target, fault, blast-radius controls, steady
state predicate, abort conditions, and the signals that will be collected.
A plan is a written commitment. If the plan cannot be written, the study does
not happen.

Scoping fails closed. If the fault path is unavailable (capability not
enabled, agent not installed, permission missing), we stop at exit code 14
rather than degrading to a weaker fault that answers a different question.

### 2. Readiness

Verify the plan is executable *and* observable.

Two independent checks:

- **Executable** — can Chaos Studio actually inject this fault at this target
  right now?
- **Observable** — will we be able to tell what happened? If no signal source
  covers the impact, the study can still run, but it will produce a finding
  with `confidence: low` and a mandatory limitation. We say so *before*
  running, not after.

Readiness failure is exit code 10. It is not a warning.

### 3. Execute

Inject the fault inside a bounded window, with the abort path armed.

Rules that do not bend:

- **Dry run is the default.** Execution requires an explicit `-DryRun:$false`
  *and* a typed consent string bound to the frozen config hash. If the plan
  changed after consent was given, the consent is void (exit 12).
- **Non-interactive escape hatches do not apply.** The study suite ignores
  `STARTCHAOS_NONINTERACTIVE`. A human types the consent string or nothing is
  injected.
- **The blast radius is in the plan, not in the operator's head.** Selectors,
  percentages and durations are frozen at consent time.
- **Abort is not cleanup.** Abort conditions are evaluated during the run; if
  one trips, the fault stops and the study records that it was aborted, which
  is itself a finding.

### 4. Observe

Collect three windows: `pre`, `during`, `post`. All windows are half-open
`[start, end)` so a sample can never be counted twice.

The non-negotiable rule: **a missing measurement is `null`, never `0`.**
Zero means "we measured, and it was zero". Null means "we did not measure",
and it must carry a caveat saying why. Every signal collector returns the same
shape so this cannot be fudged.

Control-plane state — "the experiment reported Success" — is **not** proof that
the fault reached the workload. It proves Chaos Studio accepted the request.
Only a data-plane signal can set `mechanismProven: true`.

### 5. Conclude

Turn evidence into findings, then seal.

- **Severity** comes from behaviour, not from the fault's scariness:
  - `critical` — steady state breached and *not* recovered in the post window
  - `high` — breached, recovered, but later than the stated objective
  - `medium` — breached, recovered within the objective
  - `low` — steady state held, but a secondary signal degraded
- **Confidence** comes from `mechanismProven` and signal-source coverage.
  A finding drawn only from control-plane state is capped at `low`.
- **Limitations are mandatory and never empty.** At minimum, L1 (scope) always
  applies: this study tested one fault against one target in one window.

Sealing makes the study immutable. The report is rendered, every file is
hashed, the manifest records the hashes and the api-version pins, and then —
and only then — `SEALED` is written. A sealed study is evidence you can cite
six months later.

## Why the suite is five skills

One skill that did all of this would be unreadable and untestable. Splitting on
the phase boundaries gives each skill one job, one output, and one failure
mode:

| Skill | Owns | Produces |
|---|---|---|
| `chaos-study` | the opinionated end-to-end path | an orchestrated study |
| `chaos-study-scope` | target, fault, readiness | `study-plan.v1.json` |
| `chaos-study-run` | consent, injection, observation | `run-record.v1.json` |
| `chaos-study-report` | interpretation, rendering, sealing | `findings.v1.json`, `report.html` |
| `chaos-study-history` | recall and comparison | listings, diffs, reruns |

Each is usable alone. `chaos-study` is the front door for anyone who does not
want to think about the seams.

## What this suite deliberately does not do

- **No SRE Agent dependency.** The core path is `az chaos`.
- **No required MCP dependency.** MCP may enrich, never gate.
- **No auto-remediation.** A study reports; a human decides.
- **No invented evidence.** If a number is not measured, it is not printed.
