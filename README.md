# Conveyor

Conveyor is an agentic coding control-plane scaffold. The Phase 0 application is
an Elixir/Phoenix service with LiveView endpoint plumbing, Ash and AshPostgres
for domain state, Oban for durable background work, and Postgres 16 as the
assumed datastore.

## Current Scaffold

- OTP application: `:conveyor`
- Web endpoint: `ConveyorWeb.Endpoint`
- Repository: `Conveyor.Repo`
- Ash domain root: `Conveyor.Domain`
- Oban facade: `Conveyor.Oban`
- Project config loader: `Conveyor.ProjectConfig`
- Project config evidence task: `mix conveyor.config_probe`
- Boot/version evidence task: `mix conveyor.version_probe`

## Local Checks

```bash
export CONVEYOR_SESSION_SIGNING_SALT=<session-signing-salt>
export PHX_SECRET_KEY_BASE=<dev-or-test-secret-key-base>
export PHX_LIVE_VIEW_SIGNING_SALT=<live-view-signing-salt>
bash scripts/ci_control_plane.sh
```

The script runs the baseline Mix checks and writes structured logs under
`tmp/ci/control-plane`.

Manual equivalent:

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
mix conveyor.config_probe --config .conveyor/config.toml --output tmp/conveyor_config_probe.json
mix conveyor.version_probe --output tmp/conveyor_version_probe.json --boot-log tmp/conveyor_boot.log
mix test
mix format --check-formatted
```

See `docs/runtime.md` for runtime assumptions and evidence artifacts.
