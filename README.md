# AgentProof

Harness for detecting false completion claims by coding agents: run a task, extract the agent's claims, and check them against the actual repo state.

| Folder | Contents |
|---|---|
| `scripts/` | Harness: `run_batch.sh` (driver), `run_trial.sh`, `extract_claims.js`, `compare_claims.js`, `aggregate_results.js`, `pull_contradicted_trials.sh` |
| `tasks/` | Task-set JSON files fed to `run_batch.sh` |
| `specs/` | Task spec write-ups (batches 1-4) |
| `docs/` | Project context |
| `logs/` | Batch run logs |
| `results/` | `trial_logs_archive/` (per-trial evidence and verdicts), `contradicted_for_tagging/` |

Run from `scripts/`, e.g. `REPEATS=5 ./run_batch.sh ../tasks/tasks_16to20.json` (needs `ANTHROPIC_API_KEY`).
