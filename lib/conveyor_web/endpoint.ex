defmodule ConveyorWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :conveyor

  @session_options [
    store: :cookie,
    key: "_conveyor_key",
    signing_salt: Application.compile_env!(:conveyor, :session_signing_salt),
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug ConveyorWeb.Router
end
