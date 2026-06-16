import Config

config :conveyor, Conveyor.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: System.get_env("POSTGRES_DB", "conveyor_test#{System.get_env("MIX_TEST_PARTITION")}"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: String.to_integer(System.get_env("ECTO_POOL_SIZE", "10"))

config :conveyor, Conveyor.Oban,
  repo: Conveyor.Repo,
  engine: Oban.Engines.Inline,
  notifier: Oban.Notifiers.PG,
  peer: false,
  testing: :inline,
  queues: false,
  plugins: false

config :conveyor, ConveyorWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: System.fetch_env!("PHX_SECRET_KEY_BASE"),
  live_view: [signing_salt: System.fetch_env!("PHX_LIVE_VIEW_SIGNING_SALT")],
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
