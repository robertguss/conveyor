defmodule Conveyor.VersionProbe do
  @moduledoc """
  Captures boot status and runtime/library versions for RunSpec evidence.
  """

  @packages [
    ash: :ash,
    ash_postgres: :ash_postgres,
    ash_state_machine: :ash_state_machine,
    bandit: :bandit,
    ecto_sql: :ecto_sql,
    oban: :oban,
    phoenix: :phoenix,
    phoenix_ecto: :phoenix_ecto,
    phoenix_live_view: :phoenix_live_view,
    postgrex: :postgrex
  ]

  def run(opts \\ []) do
    started_at = DateTime.utc_now()
    started_monotonic = System.monotonic_time()
    boot_log = ["starting conveyor application"]

    {status, payload, boot_log} =
      case ensure_started() do
        {:ok, started_apps} ->
          services = service_statuses()
          postgres = postgres_status(Keyword.get(opts, :database_probe?, true))

          status =
            if all_started?(services) and postgres[:status] in ["ok", "skipped"],
              do: "ok",
              else: "error"

          payload = %{
            status: status,
            started_apps: Enum.map(started_apps, &Atom.to_string/1),
            services: services,
            postgres: postgres,
            versions: versions()
          }

          boot_log =
            boot_log ++
              ["application start returned #{inspect(started_apps)}", "status=#{status}"]

          {status, payload, boot_log}

        {:error, message} ->
          boot_log = boot_log ++ ["failed to boot conveyor application", message]

          {"error",
           %{
             status: "error",
             error: message,
             started_apps: [],
             services: [],
             postgres: nil,
             versions: versions()
           }, boot_log}
      end

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_monotonic, :native, :millisecond)

    Map.merge(payload, %{
      status: status,
      started_at: DateTime.to_iso8601(started_at),
      finished_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      duration_ms: duration_ms,
      boot_log: boot_log
    })
  end

  defp ensure_started do
    case Application.ensure_all_started(:conveyor) do
      {:ok, apps} ->
        {:ok, apps}

      {:error, {app, reason}} ->
        {:error, "failed to start #{inspect(app)}: #{inspect(reason)}"}
    end
  end

  defp service_statuses do
    [
      service_status(:repo, Conveyor.Repo),
      service_status(:endpoint, ConveyorWeb.Endpoint),
      supervisor_child_status(:oban, Conveyor.Oban),
      service_status(:pubsub, Conveyor.PubSub)
    ]
  end

  defp service_status(name, process_name) do
    case Process.whereis(process_name) do
      pid when is_pid(pid) ->
        %{
          name: Atom.to_string(name),
          process: inspect(process_name),
          status: "started",
          pid: inspect(pid)
        }

      nil ->
        %{name: Atom.to_string(name), process: inspect(process_name), status: "missing", pid: nil}
    end
  end

  defp supervisor_child_status(name, child_id) do
    case Supervisor.which_children(Conveyor.Supervisor) |> List.keyfind(child_id, 0) do
      {^child_id, pid, _type, _modules} when is_pid(pid) ->
        %{
          name: Atom.to_string(name),
          process: inspect(child_id),
          status: "started",
          pid: inspect(pid)
        }

      _missing ->
        %{name: Atom.to_string(name), process: inspect(child_id), status: "missing", pid: nil}
    end
  end

  defp all_started?(services) do
    Enum.all?(services, &(&1.status == "started"))
  end

  defp postgres_status(false) do
    assumptions = Application.get_env(:conveyor, :runtime_assumptions, [])

    %{
      status: "skipped",
      required_major: Keyword.fetch!(assumptions, :postgres_major),
      server_version: nil
    }
  end

  defp postgres_status(true) do
    assumptions = Application.get_env(:conveyor, :runtime_assumptions, [])

    case Conveyor.Repo.query("select version()", [], log: false) do
      {:ok, %{rows: [[server_version]]}} ->
        %{
          status: "ok",
          required_major: Keyword.fetch!(assumptions, :postgres_major),
          server_version: server_version
        }

      {:error, error} ->
        %{
          status: "error",
          required_major: Keyword.fetch!(assumptions, :postgres_major),
          server_version: nil,
          error: Exception.message(error)
        }
    end
  end

  defp versions do
    package_versions =
      Map.new(@packages, fn {label, app} ->
        {label, app_version(app)}
      end)

    Map.merge(package_versions, %{
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> to_string()
    })
  end

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      version -> to_string(version)
    end
  end
end
