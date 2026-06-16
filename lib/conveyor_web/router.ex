defmodule ConveyorWeb.Router do
  use ConveyorWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: false
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ConveyorWeb do
    pipe_through :api

    get "/", PageController, :home
  end
end
