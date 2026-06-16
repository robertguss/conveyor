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

Sample command metadata lives in `.conveyor/config.toml`, and the scoped agent
instructions live in `AGENTS.md`. The configured commands cover dependency sync,
import-level build checks, baseline tests, pytest collection, app launch, plan
audit, and AGENTS.md linting.

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

## Quality Adapter Defaults

The default demo records a `sample_noop` quality reference for ContextPack and
gate inputs, so the tracer can run without CodeScent or any other proprietary
tooling. A `sample_local_python` profile is available for advisory local Python
checks when `python3` is present. CodeScent remains an advanced blocking adapter
profile only when its required tool and credential are configured explicitly.
