import Config

config :conveyor,
  ash_domains: [Conveyor.Domain],
  ecto_repos: [Conveyor.Repo],
  generators: [timestamp_type: :utc_datetime_usec],
  session_signing_salt: System.fetch_env!("CONVEYOR_SESSION_SIGNING_SALT")

config :conveyor, :runtime_assumptions,
  elixir: "~> 1.17",
  otp: "27 or 28",
  postgres_major: 16,
  phoenix: "~> 1.8.8",
  ash: "~> 3.29",
  oban: "~> 2.23"

config :conveyor, Conveyor.Repo, migration_timestamps: [type: :utc_datetime_usec]

config :conveyor, Conveyor.Oban,
  repo: Conveyor.Repo,
  queues: [default: 10],
  plugins: [Oban.Plugins.Pruner]

config :conveyor, ConveyorWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ConveyorWeb.ErrorHTML, json: ConveyorWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Conveyor.PubSub

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
