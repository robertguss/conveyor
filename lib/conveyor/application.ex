defmodule Conveyor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: Conveyor.Supervisor)
  end

  def children do
    [
      ConveyorWeb.Telemetry,
      Conveyor.Repo,
      {DNSCluster, query: Application.get_env(:conveyor, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Conveyor.PubSub},
      {Finch, name: Conveyor.Finch},
      ConveyorWeb.Endpoint,
      Conveyor.Oban
    ]
  end

  @impl true
  def config_change(changed, _new, removed) do
    ConveyorWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
