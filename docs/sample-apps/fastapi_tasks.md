# FastAPI Tasks Sample Baseline

`sample_apps/fastapi_tasks` is the sterile FastAPI sample repository for
Phase 1 tracer work. It is deliberately isolated from Conveyor core and exists
only as a small, language-specific target for plan, test, and evidence flows.

## Baseline Contract

- Runtime: Python 3.11 or newer.
- Storage: in-memory task store.
- Required endpoints: `GET /healthz`, `GET /tasks`, `POST /tasks`.
- Required behavior: tasks start empty, a created task appears in subsequent
  list responses, and invalid task creation does not mutate state.
- Secrets: no production secrets are required.
- Network: no network egress is required at runtime or during baseline tests
  after dependencies are installed.

## Verification Evidence

The baseline command is:

```bash
cd sample_apps/fastapi_tasks
./scripts/run_baseline.sh
```

It emits a timestamped local evidence directory containing `pytest-junit.xml`,
`pytest.log`, and `baseline-summary.json`.

## RunSpec Input

The machine-readable RunSpec input lives at
`sample_apps/fastapi_tasks/run_specs/baseline.run_spec.json`. The baseline
commit field is filled after the first commit that contains the sample app, so
future Conveyor runs can refer to a stable base.

