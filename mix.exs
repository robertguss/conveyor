defmodule Conveyor.MixProject do
  use Mix.Project

  @app :conveyor
  @version "0.1.0"

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      preferred_cli_env: [
        "test.all": :test
      ]
    ]
  end

  def application do
    [
      mod: {Conveyor.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.29"},
      {:ash_postgres, "~> 2.10"},
      {:ash_state_machine, "~> 0.2"},
      {:bandit, "~> 1.12"},
      {:dns_cluster, "~> 0.2"},
      {:ecto_sql, "~> 3.14"},
      {:finch, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:oban, "~> 2.23"},
      {:phoenix, "~> 1.8.8"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_live_view, "~> 1.2"},
      {:postgrex, "~> 0.22"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.3"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "test.all": ["format --check-formatted", "test"]
    ]
  end
end
