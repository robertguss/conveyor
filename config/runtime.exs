import Config

if config_env() == :prod do
  socket_options = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      Example: ecto://USER:PASS@HOST/DATABASE
      """

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  live_view_signing_salt =
    System.get_env("PHX_LIVE_VIEW_SIGNING_SALT") ||
      raise """
      environment variable PHX_LIVE_VIEW_SIGNING_SALT is missing.
      Generate one with: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST", "example.com")
  port = String.to_integer(System.get_env("PORT", "4000"))

  config :conveyor, Conveyor.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("ECTO_POOL_SIZE", "10")),
    socket_options: socket_options

  config :conveyor, ConveyorWeb.Endpoint,
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt],
    server: true,
    url: [host: host, port: 443, scheme: "https"]
end
