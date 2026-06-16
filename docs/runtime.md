# Runtime Scaffold

This scaffold is the Phase 0 Conveyor control-plane application. It is a single
OTP app using Phoenix 1.8, LiveView, Ash, AshPostgres, Oban, and Postgres.

## Runtime Assumptions

- Elixir: `~> 1.17`
- OTP: `27` or `28`
- Phoenix: `~> 1.8.8`
- LiveView: `~> 1.2`
- Ash: `~> 3.29`
- AshPostgres: `~> 2.10`
- Oban: `~> 2.23`
- Postgres: major version `16`

All environments require `CONVEYOR_SESSION_SIGNING_SALT` for signed session
cookies. Postgres connection settings are read from `POSTGRES_USER`,
`POSTGRES_PASSWORD`, `POSTGRES_HOST`, `POSTGRES_PORT`, and `POSTGRES_DB` in
dev/test. Dev/test endpoint configuration also requires `PHX_SECRET_KEY_BASE`
and `PHX_LIVE_VIEW_SIGNING_SALT`. Production reads `DATABASE_URL`,
`SECRET_KEY_BASE`, `PHX_LIVE_VIEW_SIGNING_SALT`, `PHX_HOST`, `PORT`, and
`ECTO_POOL_SIZE`.

## Verification

The baseline scaffold checks are:

```bash
export CONVEYOR_SESSION_SIGNING_SALT=<session-signing-salt>
export PHX_SECRET_KEY_BASE=<dev-or-test-secret-key-base>
export PHX_LIVE_VIEW_SIGNING_SALT=<live-view-signing-salt>
mix deps.get
mix conveyor.doctor --output tmp/conveyor_doctor.json --transcript tmp/conveyor_doctor.log
mix ecto.create
mix ecto.migrate
mix conveyor.config_probe --config .conveyor/config.toml --output tmp/conveyor_config_probe.json
mix conveyor.version_probe --output tmp/conveyor_version_probe.json --boot-log tmp/conveyor_boot.log
mix test
mix format --check-formatted
```

The canonical local/CI entrypoint is:

```bash
bash scripts/ci_control_plane.sh
```

It writes `tmp/ci/control-plane/summary.json`,
`tmp/ci/control-plane/stations.jsonl`, per-station logs, and the
`conveyor.config_probe` and `conveyor.version_probe` JSON/log artifacts. Credo
and Dialyzer stations are recorded as skipped unless their Mix tasks are
configured.

`mix conveyor.doctor` checks local runtime prerequisites without starting the
Phoenix application. Blocking failures use stable categories, NextAction
guidance, and exit code `4`; optional provider and CodeScent adapters warn
unless configured as gate-blocking. The report records runtime versions and
writes `conveyor.doctor.report@1` JSON plus a transcript.

`mix conveyor.config_probe` loads `.conveyor/config.toml`, normalizes command
specs for PlanAudit, AGENTS.md generation, policy checks, and verification,
and writes `conveyor.config.resolution@1` JSON mapped to
`conveyor-quality-ci-evals-vmr.13`. When a locked RunSpec is supplied, project
config must match the locked `project_config_digest` and cannot provide
mid-run profile or command overrides.

`mix conveyor.version_probe` starts the Conveyor application, verifies the Repo,
Oban facade, PubSub, and LiveView endpoint processes, queries Postgres for
`select version()`, and writes structured JSON plus a plain boot log. The
application boot path still expects a configured database because Repo and Oban
are supervised children. Use `--skip-db` only when the application is already
bootable but the caller wants to skip the explicit `select version()` query.

The baseline CI bead should map these checks into the Phase 0/1 verification
matrix entry for the control-plane boot station.
