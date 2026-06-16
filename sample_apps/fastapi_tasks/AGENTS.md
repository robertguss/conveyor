# AGENTS.md - FastAPI Tasks Sample

## Overview

The FastAPI Tasks sample is a sterile Conveyor Phase 1 fixture for tracer runs.
It exists to produce PR-quality evidence for one bounded task-completion Slice
without production secrets, deployment, or external service access.

## Architecture Map

- `src/fastapi_tasks/app.py` defines `fastapi_tasks.app`, `TaskCreate`,
  `Task`, `TaskStore`, `create_app`, and the ASGI `app` object.
- `TaskStore` is in-memory and per-process; do not add database, auth, queue, or
  deployment dependencies for the current Slice.
- `tests/baseline_regression` protects existing create/list behavior before any
  acceptance-locked suite runs.
- `plans/complete_tasks.md` is the human plan fixture consumed by
  `scripts/plan_audit.py`.
- Conveyor integration is through command config and artifacts, not imports from
  `Conveyor.ProjectConfig`, `Conveyor.Domain`, `Conveyor.Repo`,
  `Conveyor.Oban`, or `ConveyorWeb.Endpoint`.

## Commands

- `agents_md`: `python3 ../../scripts/agents_md_contract.py --config .conveyor/config.toml --policy ../../docs/policy/profiles.json --target AGENTS.md --lint-target --self-test --output artifacts/agents_md_lint.json`
- `build`: `uv run --extra test python -m compileall src`
- `install`: `uv sync --frozen --extra test`
- `lint`: `uv run --extra test python -m pytest --collect-only -q tests`
- `plan_audit`: `uv run --extra test python scripts/plan_audit.py plans/complete_tasks.md`
- `run_app`: `uv run --extra test python -m uvicorn fastapi_tasks.app:app --host 127.0.0.1 --port 8000`
- `test`: `./scripts/run_baseline.sh`
- `typecheck`: `uv run --extra test python -m compileall src tests scripts`

## Coding Rules

- No Script-Based Changes for source rewrites; revise existing code files in place.
- Keep the sample small and language-local. Do not introduce Conveyor core
  dependencies into the FastAPI package.
- Preserve the current in-memory storage model unless the active Slice
  explicitly changes it.
- Do not broaden the sample into auth, pagination, bulk update, un-complete, or
  deployment behavior.

## Testing and Verification

- Run UBS on changed sample files before closing work.
- Run `uv run --extra test python -m pytest --collect-only -q tests` after test
  layout changes.
- Run `./scripts/run_baseline.sh` when app behavior or baseline tests change.
- Run `uv run --extra test python scripts/plan_audit.py plans/complete_tasks.md`
  when the plan or AGENTS command mapping changes.

## Security Rules

- No production credentials are required. Do not read credentials from `.env`,
  shell environments, cloud CLIs, or password managers.
- `network` policy is disabled for Phase 1 verification commands unless a human
  explicitly grants a narrower exception.
- Treat the sample workspace as the sandbox boundary; do not modify files
  outside declared command roots for this sample.
- `human approval` is required before any destructive cleanup, external state
  change, deploy, release, or publish action.

## Git and Task Rules

- Work on `main`.
- Track status in Beads and use Agent Mail for coordination when other agents
  may touch the same sample files.
- Use the Bead id as the Agent Mail thread id and command evidence reference.

## Done Criteria

- Done means the relevant tests pass, structured artifacts are written under
  `artifacts/`, Beads are updated with `br sync --flush-only`, and the final
  work can be pushed according to the repository push policy.
- If verification cannot run, record the blocker, finding, and next action in
  the Bead and Agent Mail thread.

## Forbidden Actions

- `DATABASE_URL=postgres://prod`
- `apt install`
- `aws configure`
- `brew install`
- `cat .env`
- `chmod /`
- `chmod -R`
- `chown /`
- `chown -R`
- `curl https://`
- `curl install`
- `curl | bash`
- `curl | sh`
- `doas`
- `docker push`
- `find -delete`
- `fly deploy`
- `gcloud auth`
- `git checkout --`
- `git clean`
- `git clean -fd`
- `git push --force`
- `git push -f`
- `git push --mirror`
- `git reset --hard`
- `git restore --source`
- `kubectl apply`
- `mix hex.publish`
- `npm install -g`
- `npm publish`
- `op read`
- `pip install`
- `printenv`
- `prod-db`
- `production database`
- `rm -rf`
- `scp `
- `shred`
- `ssh `
- `su -`
- `sudo`
- `truncate`
- `wget https://`
- `wget | bash`
- `wget | sh`
- `| bash`
- `| sh`

## Conveyor Evidence

- Baseline evidence must include the `baseline-summary.json`, `pytest.log`, and
  `pytest-junit.xml` artifacts from `./scripts/run_baseline.sh`.
- RunSpec-linked evidence should carry `run_spec_sha256`, structured findings,
  command transcripts, and artifact paths when Conveyor stations consume this
  sample.
- Plan and AGENTS checks emit structured JSON evidence for downstream gates.

## CodeScent Context

- CodeScent is optional for this sample and must not be required for the default
  local path.
- The configured local quality profile is advisory and credential-free; any
  CodeScent credential must come from an explicit higher-authority lease.

## Blocker Reporting

- Report a blocker with the failing command, structured finding, artifact path,
  and concrete NextAction.
- Keep baseline failures separate from acceptance-locked failures so Conveyor can
  tell whether the base app was already broken.
