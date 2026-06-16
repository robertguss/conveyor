# FastAPI Tasks Sample

This is the sterile Phase 1 sample service used by Conveyor tracer runs. It is
intentionally small, isolated from Conveyor core, and requires no production
secrets or external service credentials.

## Endpoints

- `GET /healthz` returns readiness for local tests.
- `GET /tasks` lists tasks from the in-memory store.
- `POST /tasks` creates a task with a required non-empty `title` and optional
  `completed` flag.

## Baseline Verification

Install the test dependencies in a local virtual environment, then run:

```bash
./scripts/run_baseline.sh
```

The runner writes a timestamped directory under `artifacts/` containing:

- `pytest-junit.xml`
- `pytest.log`
- `baseline-summary.json`

The artifact directory is local evidence output and is intentionally ignored by
git.

