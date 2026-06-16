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

## Quality Adapter Evidence

The default demo uses the `sample_noop` quality profile. It emits advisory
quality references for ContextPack and gate artifacts without requiring
CodeScent, live provider credentials, or optional commercial tooling.

The `sample_local_python` profile is available for advisory local checks when
`python3` is installed. Blocking profiles, such as an advanced CodeScent
configuration, must explicitly declare both required tools and required
credential environment variables before a gate can depend on them.

## RunSpec Input

The machine-readable RunSpec input lives at
`sample_apps/fastapi_tasks/run_specs/baseline.run_spec.json`.

Baseline commit:
`16482bf29cc866c81c8619e65c417eafc684adc8`
