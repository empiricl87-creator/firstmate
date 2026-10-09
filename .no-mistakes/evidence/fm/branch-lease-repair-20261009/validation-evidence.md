# Reservation lifecycle validation

Target: `df83cbc5044f156152a2767a64992ea5dc45f726`.
Base: `19fcbbde12c4e916e0d5faa60c399d2fd2845740`.

The tests used disposable, marked FM_HOME directories and private `fm-lab` tmux sockets, with 160×45 terminal grids. No operator fleet was inspected or mutated. Normal Pi login was copied only into temporary worktree-local agent directories; credentials are not included in evidence.

## Live observations

- A real Pi 0.85.1 primary acquired its session lock. Reservations for `xop-mac2` and `recurring-process-audit`, deliberately given old timestamps and the still-live owner PID, refused main claims before activation and were removed by activation. The main actor's independent reservation survived.
- An actual authenticated `gpt-5.6-sol`/medium supervision turn drained the queue, claimed the task, ran bounded holds, reported, acknowledged, released its own task and settled. Main claims were refused both before and after the durable report. A deliberately forgotten second reservation was removed by automatic settlement cleanup, after which main could claim both tasks while the Pi PID remained alive. See `live-reservation-observations.jsonl`, `live-concurrent-claims.jsonl`, and `live-provider-transcript.json`.
- A second real Pi primary used the normal documented local endpoint override. A socket was bound without listening, so the native HTTP transport received connection refusal. The fetch guard only rejected non-local destinations; it forwarded permitted requests to native fetch and never fabricated a response. The actual prompt settled with `stopReason=error` and `fetch failed`. Both in-flight reservations were removed, main claims succeeded, and the unacknowledged wake remained replayable. See `live-failure-observations.jsonl`, `live-failure-provider-transcript.json`, `local-outage-preflight.json`, and `failed-wake-main-replay.txt`.
- Both TUIs retained their unsent editor drafts. The failure lab also preserved its modified tracked file, untracked file, working task metadata/status and concurrent main reservation. See `live-final-terminal.txt`, `live-failure-final-terminal.txt`, `preserved-work.txt`, and `preserved-task-records.txt`.
- Real lease CLI calls rejected an old PID's cleanup after ownership changed, rejected actor spoofing and invalid PID input, and allowed the new owner to release only its matching branch reservations. See `holder-bound-cli.jsonl`.

The fixture driver publishes wakes through the product's public extension event bus; it does not replace Pi, its SDK, the branch extension, or lease commands. Lease records are intentionally seeded or claimed through the real CLI to exercise abandoned and in-flight state. This validates reservation behavior, not production routing or a full fleet deployment.

## Targeted checks and counterfactual

`tests/fm-branch-supervision.test.sh`, `tests/fm-pi-branch-extension.test.sh`, and the opt-in `tests/fm-pi-branch-live-e2e.test.sh` passed. The SDK integration test intercepts provider responses and is supplementary, not live-provider evidence. The portable extension tests cover success, abort, provider error, missing report, queued turns, failed cleanup retry, generation replacement and shutdown waiting for cleanup.

The focused settlement regression failed against the base extension with `success settled turn retained its live-PID lease`, and passed against the target. See `before-fix-regression.log` and `after-fix-regression.log`.

## Setup and attempt accounting

The first hosted-provider turn (`gpt-5.6-terra`/low) returned a provider error before running tools. One permitted retry (`gpt-5.6-sol`/medium) succeeded; automatic agent retries were disabled. The separate failure proof used only the non-listening localhost endpoint, with no external provider request. See `provider-attempt-ledger.json`.

An initial long tmux socket path was shortened inside the worktree. A proposed OS-network-denial setup was abandoned because macOS refused setuid `ps`, preventing the full identity/grant path; no pass relies on that setup or its seeded lock. The successful failure proof acquired the real lock normally and used the endpoint override instead. No packages, applications or user-level configuration were changed.

This change has no visual-layout surface. Terminal captures, actual CLI output, model/tool transcripts, and persisted-state records provide the product evidence.
