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
mix deps.get
mix ecto.create
mix ecto.migrate
mix conveyor.version_probe --output tmp/conveyor_version_probe.json --boot-log tmp/conveyor_boot.log
mix test
mix format --check-formatted
```

`mix conveyor.version_probe` starts the Conveyor application, verifies the Repo,
Oban facade, PubSub, and LiveView endpoint processes, queries Postgres for
`select version()`, and writes structured JSON plus a plain boot log. The
application boot path still expects a configured database because Repo and Oban
are supervised children. Use `--skip-db` only when the application is already
bootable but the caller wants to skip the explicit `select version()` query.

The baseline CI bead should map these checks into the Phase 0/1 verification
matrix entry for the control-plane boot station.
