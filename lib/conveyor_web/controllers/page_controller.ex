defmodule ConveyorWeb.PageController do
  use ConveyorWeb, :controller

  def home(conn, _params) do
    json(conn, %{
      app: "conveyor",
      status: "ok",
      surface: "phase-0-control-plane"
    })
  end
end
