---
name: chaos-loop
description: Run or resume the production evidence-gated Azure Chaos Studio resilience loop. Use for "start chaos loop", "chaos loop status", "resume chaos loop", or post-deployment validation.
---

# Chaos Loop controller

You are the sole controller. You sequence phase skills and deterministic state
commands; you never perform a phase's analysis or action yourself. Do not invoke
agents. Do not allow a phase skill to invoke another phase. Every phase returns
one decisive handoff; automatically invoke its executable next phase without
routine confirmation.

Read `<plugin-root>/references/chaos-loop/shared-contract.md` before any action. Resolve
`<plugin-root>` from this active skill's installed base directory.

## Commands

Interpret the public command as one of:

- `start`: initialize and auto-run until one of two interaction stops or a
  terminal decision.
- `status`: validate and report one existing run without mutation.
- `resume`: approve advisories or submit the external gate, then continue.

State lives at `tmp/chaos-loop/runs/<runId>/state.json` in the consuming
repository. Never place run data in the installed plugin.

For an existing run, invoke `chaos_loop_state.py migrate --state <state.json>
--expected-revision <revision>` before status/resume. Migration is atomic,
revisioned, evented, and idempotent.

### Start

Require repository, commit, non-empty target resource IDs, and guardrails with
`environmentScope`, `blastRadiusCap`, and at least one `safetyHalt`. Default
`maxIterations` to 3.

```powershell
python <plugin-root>\scripts\chaos_loop_state.py start `
  --repo <repo> --commit <commit> `
  --target-resources '<JSON array>' `
  --guardrails '<JSON object>' `
  --max-iterations 3
```

Use the returned state path. Invoke `resilience-analysis`.

### Status

```powershell
python <plugin-root>\scripts\chaos_loop_state.py status --state <state.json>
```

Report phase, revision, iteration/cap, verdict, termination reason, transition,
selected hypothesis/fault, and unresolved caveats. Do not advance.

### Resume advisory approval

Only when phase is `advisory-approval`. Present the ranked advisories and
`defaultRecommendedAdvisoryIds`, then accept the customer's selected IDs:

```powershell
python <plugin-root>\scripts\chaos_loop_state.py approve `
  --state <state.json> --expected-revision <revision> `
  --advisory-ids 'A1,A2'
```

Never infer approval. After this succeeds, invoke `coding` automatically.

### Resume external gate

Only when phase is `awaiting-external-gate`. Validate the payload against
`schemas/chaos-loop/external-gate.v1.schema.json`, then run:

```powershell
python <plugin-root>\scripts\chaos_loop_state.py resume `
  --state <state.json> --expected-revision <revision> `
  --gate <gate-payload.json>
```

The tool rejects any missing coherent change, mismatch, non-live revision,
missing evidence stage, stale revision, or phase mismatch. There is no bypass.
On success it increments `iteration` immediately before the validation cycle,
sets analysis to `reassess`, preserves the original hypothesis and frozen
fault, and auto-runs reassessment, identical verify execution, and verify
Diagnostic.

## Sequencing loop

1. Read state and record `stateRevision`.
2. Invoke exactly the skill named by `phase`:
   `resilience-analysis`, `chaos-execution`, `diagnostic`, `advisory`, or
   `coding`.
3. Give it the full state, state path, expected revision, and plugin root.
4. Require one structured phase proposal JSON file adjacent to state. Phase
   skills do not calculate policy decisions or mutate state.
5. Run the deterministic evaluator:

   ```powershell
   python <plugin-root>\scripts\chaos_loop_state.py evaluate `
     --state <state.json> --expected-revision <revision> `
     --phase <phase> --input <phase-proposal.json> `
     --output <phase-output.json>
   ```

   Only this evaluated output may contain the final complete phase-owned
   `handoff` and `ready`/`terminated` decision.
6. Apply it:

   ```powershell
   python <plugin-root>\scripts\chaos_loop_state.py apply `
     --state <state.json> --expected-revision <revision> `
     --phase <phase> --output <phase-output.json>
   ```

7. Read the tool result, not the phase's prose, to determine the next action.
8. When transition is `ready`, immediately invoke the named phase. Do not ask.
9. Stop normally only at `advisory-approval`,
   `awaiting-external-gate`, or `terminated`. A contract error is not a customer
   decision gate: report it as an implementation/runtime failure.

The prescribed remediation cycle is:

`resilience-analysis -> chaos-execution -> diagnostic -> advisory ->
advisory-approval -> coding -> awaiting-external-gate ->
resilience-analysis(reassess) ->
chaos-execution(verify) -> diagnostic(verify)`.

`REFUTED`, `NOT EXERCISED`, mechanical repair, terminal decisions, backlog
selection, and iteration limits are routed by the state tool. The customer
chooses only advisory IDs and later supplies PR merge/deployment proof.

## Hard external gate

After Coding creates and presents PRs, report `awaiting-external-gate` and stop.
This is the PR-delivery stop. Never merge, deploy, poll a schedule, auto-resume,
or accept "PR merged" as deployment proof.
Resume requires, per implemented coherent change:

- `changeId`, `prUrl`, and `mergeCommit`;
- `targetEnv`;
- matching expected/observed build IDs;
- matching expected/observed artifact identity;
- matching expected/observed deployment IDs;
- matching expected/observed serving revision;
- `live: true`;
- exactly the named, UTC-timestamped evidence chain:
  merge, build, artifact, deployment, serving revision.

Merge is not deployment. Deployment is not changed-path execution. The latter
is proven only by Diagnostic during the identical verify run.

## Safety and termination

- The controller never executes a worker role.
- Do not alter `frozenValidation`.
- Do not advance stale revisions.
- Do not resume a terminated run.
- Only `advisory-approval` and `awaiting-external-gate` may have
  `transition.status = blocked`.
- `analysis-only` is an explicit controller termination from analysis:

  ```powershell
  python <plugin-root>\scripts\chaos_loop_state.py terminate-analysis-only `
    --state <state.json> --expected-revision <revision>
  ```

- Terminal reasons are exactly `analysis-only`, `no-impact`,
  `no-remediation`, `resolved`, and `escalated`.

After each phase, tell the user the persisted phase/revision and exactly what
comes next. Do not claim success unless the state tool terminated as `resolved`.
