defmodule Conveyor.Jobs.RunSlice do
  @moduledoc """
  Oban worker and direct runner for the linear Phase 1 station plan.

  Station state is stored in StationRun rows before each worker runs. A later
  invocation can therefore resume from the durable station table after a process
  stop, completing only missing or in-progress stations.
  """

  use Oban.Worker, queue: :default, max_attempts: 20

  alias Conveyor.Domain.{PayloadHelpers, StationEffect, StationRun}
  alias Conveyor.{Ledger, Repo}
  alias Conveyor.Stations.Phase1

  @schema_version "conveyor.run_slice@1"
  @finding_schema_version "conveyor.run_slice_finding@1"
  @timeline_schema_version "conveyor.station_timeline@1"
  @timeline_channels ["timeline", "stations"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    case run(args) do
      {:ok, %{status: "completed"}} -> :ok
      {:ok, summary} -> {:error, {:station_plan_not_completed, summary}}
      {:error, reason} -> {:error, reason}
    end
  end

  def enqueue(args, opts \\ []) when is_map(args) do
    args
    |> normalize_args()
    |> __MODULE__.new(opts)
    |> Oban.insert()
  end

  def station_plan(args) when is_map(args), do: args |> normalize_args() |> Phase1.station_plan()

  def run(args, opts \\ []) when is_map(args) and is_list(opts) do
    args = normalize_args(args)

    case ensure_one_active_attempt_per_slice(args) do
      :ok ->
        run_station_plan(args, opts)

      {:error, failure} ->
        {:error, preflight_failure_summary(args, failure)}
    end
  end

  defp run_station_plan(args, opts) do
    plan = Phase1.station_plan(args)

    initial_summary = initial_summary(args, plan)

    plan
    |> Enum.reduce_while(initial_summary, fn station, summary ->
      case run_station(args, station, opts) do
        {:ok, station_summary} ->
          summary = append_station_summary(summary, station_summary)

          if stop_after?(summary, opts) do
            {:halt, pause_summary(summary, station, "stop_after")}
          else
            {:cont, summary}
          end

        {:paused, station_summary, reason} ->
          summary =
            summary
            |> append_station_summary(station_summary)
            |> pause_summary(station, reason)

          {:halt, summary}

        {:error, failure} ->
          {:halt, {:error, failure_summary(summary, failure)}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      summary -> {:ok, summary}
    end
  end

  defp initial_summary(args, plan) do
    %{
      schema_version: @schema_version,
      run_attempt_id: PayloadHelpers.fetch_required!(args, :run_attempt_id),
      slice_id: PayloadHelpers.fetch_required!(args, :slice_id),
      status: "completed",
      station_count: length(plan),
      processed_station_count: 0,
      resumed_station_count: 0,
      stations: []
    }
  end

  def station_runs_for(run_attempt_id) when is_binary(run_attempt_id) do
    Repo.query!(
      """
      SELECT payload
      FROM station_runs
      WHERE payload->>'run_attempt_id' = $1
         OR external_id LIKE $2
      ORDER BY (payload->>'attempt_number')::integer, payload->>'station_key'
      """,
      [run_attempt_id, "#{run_attempt_id}:%"],
      log: false
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [payload] -> decode_payload(payload) end)
    |> Enum.sort_by(&station_sort_key/1)
  end

  def worker_logs_for(run_attempt_id) when is_binary(run_attempt_id) do
    Repo.query!(
      """
      SELECT payload
      FROM station_effects
      WHERE external_id LIKE $1
      ORDER BY payload->>'station_run_id', payload->>'effect_id'
      """,
      ["#{run_attempt_id}:%:worker-log:%"],
      log: false
    )
    |> Map.fetch!(:rows)
    |> Enum.map(fn [payload] -> decode_payload(payload) end)
  end

  defp run_station(args, station, opts) do
    station_run_id = Phase1.station_run_id(args, station)

    case fetch_resource("station_runs", station_run_id) do
      {:ok, %{payload: %{"station_status" => "completed"}} = record} ->
        {:ok, station_summary(station, record, "resumed")}

      {:ok, %{payload: %{"station_status" => "failed"}} = record} ->
        {:error, station_failure(station, record, "station_already_failed")}

      {:ok, record} ->
        complete_started_station(args, station, record, opts)

      :error ->
        start_station(args, station, opts)
    end
  end

  defp start_station(args, station, opts) do
    station_run_id = Phase1.station_run_id(args, station)

    attrs =
      StationRun.create_attrs!(%{
        station_run_id: station_run_id,
        run_attempt_id: PayloadHelpers.fetch_required!(args, :run_attempt_id),
        station_key: station.station_key,
        station_spec_sha256: station.station_spec_sha256,
        attempt_number: station.position,
        input_sha256: station.input_sha256,
        station_status: "planned",
        metadata: %{
          worker_key: station.worker_key,
          worker_log_ref: station.worker_log_ref,
          durable: true
        }
      })

    record = insert_resource!("station_runs", attrs)

    with :ok <- append_timeline(args, station, record, "station.enqueued", "running") do
      running_record =
        record
        |> merge_payload(%{
          "station_status" => "running",
          "enqueued_at" => timestamp()
        })
        |> update_payload!("station_runs")

      if halt_after_enqueue?(station, opts) do
        {:paused, station_summary(station, running_record, "started"), "halt_after_enqueue"}
      else
        complete_started_station(args, station, running_record, opts)
      end
    else
      {:error, reason} -> {:error, station_failure(station, record, reason)}
    end
  end

  defp complete_started_station(args, station, record, opts) do
    if fail_station?(station, opts) do
      worker_log =
        Phase1.worker_log(
          station,
          args,
          "failure",
          "Phase 1 #{station.station_key} worker failed before completion."
        )

      failed_record =
        record
        |> persist_worker_log!(args, station, worker_log, "failure")
        |> merge_payload(%{
          "station_status" => "failed",
          "output_sha256" => worker_log.output_sha256,
          "failure_category" => "station_worker_failed",
          "completed_at" => timestamp()
        })
        |> update_payload!("station_runs")

      case append_timeline(args, station, failed_record, "station.dequeued", "failed") do
        :ok -> {:error, station_failure(station, failed_record, "station_worker_failed")}
        {:error, reason} -> {:error, station_failure(station, failed_record, reason)}
      end
    else
      worker_log =
        Phase1.worker_log(
          station,
          args,
          "success",
          "Phase 1 #{station.station_key} worker completed."
        )

      completed_record =
        record
        |> persist_worker_log!(args, station, worker_log, "success")
        |> merge_payload(%{
          "station_status" => "completed",
          "output_sha256" => worker_log.output_sha256,
          "completed_at" => timestamp()
        })
        |> update_payload!("station_runs")

      case append_timeline(args, station, completed_record, "station.dequeued", "completed") do
        :ok -> {:ok, station_summary(station, completed_record, "executed")}
        {:error, reason} -> {:error, station_failure(station, completed_record, reason)}
      end
    end
  end

  defp persist_worker_log!(record, args, station, worker_log, result) do
    station_run_id = Phase1.station_run_id(args, station)
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    attrs =
      StationEffect.create_attrs!(%{
        effect_id: "#{station_run_id}:worker-log:#{result}",
        run_attempt_id: PayloadHelpers.fetch_required!(args, :run_attempt_id),
        station_run_id: station_run_id,
        effect_type: "worker_log",
        effect_status: "declared",
        external_ref: station.worker_log_ref,
        output_sha256: worker_log.output_sha256,
        declared_at: now,
        metadata: worker_log
      })

    _effect_record = insert_resource!("station_effects", attrs)
    record
  end

  defp append_timeline(args, station, record, event_type, station_status) do
    station_run_id = Phase1.station_run_id(args, station)
    payload = record.payload

    event = %{
      idempotency_key: "run-slice:#{station_run_id}:#{event_type}",
      trace_id: "run-slice:#{PayloadHelpers.fetch_required!(args, :run_attempt_id)}",
      span_id: "station:#{station.station_key}",
      stream_id: PayloadHelpers.fetch_required!(args, :run_attempt_id),
      event_type: event_type,
      summary: "#{event_type} #{station.station_key}",
      payload: %{
        "schema_version" => @timeline_schema_version,
        "category" => "station_timeline",
        "run_attempt_id" => PayloadHelpers.fetch_required!(args, :run_attempt_id),
        "station_run_id" => station_run_id,
        "station_key" => station.station_key,
        "station_status" => station_status,
        "worker_key" => station.worker_key,
        "station_spec_sha256" => station.station_spec_sha256,
        "input_sha256" => station.input_sha256,
        "output_sha256" => payload["output_sha256"]
      },
      metadata: %{"worker_log_ref" => station.worker_log_ref}
    }

    case Ledger.append_event(event, channels: @timeline_channels) do
      {:ok, _event, _outbox_entries} ->
        :ok

      {:error, %{category: "ledger_duplicate_key"}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_station_summary(summary, station_summary) do
    %{
      summary
      | processed_station_count: summary.processed_station_count + 1,
        resumed_station_count: summary.resumed_station_count + resumed_count(station_summary),
        stations: summary.stations ++ [station_summary]
    }
  end

  defp pause_summary(summary, station, reason) do
    Map.merge(summary, %{
      status: "paused",
      pause_reason: reason,
      next_station_key: next_station_key(station.position)
    })
  end

  defp failure_summary(summary, failure) do
    Map.merge(summary, %{
      status: "failed",
      failure: failure
    })
  end

  defp preflight_failure_summary(args, failure) do
    %{
      schema_version: @schema_version,
      run_attempt_id: PayloadHelpers.fetch_required!(args, :run_attempt_id),
      slice_id: PayloadHelpers.fetch_required!(args, :slice_id),
      status: "failed",
      station_count: Phase1.station_count(),
      processed_station_count: 0,
      resumed_station_count: 0,
      stations: [],
      failure: failure
    }
  end

  defp station_summary(station, record, source) do
    %{
      station_key: station.station_key,
      station_run_id: record.external_id,
      station_status: record.payload["station_status"],
      output_sha256: record.payload["output_sha256"],
      source: source,
      durable: true
    }
  end

  defp station_failure(station, record, reason) do
    failure_category = to_string(reason)

    %{
      schema_version: @schema_version,
      category: "station_worker_failure",
      station_key: station.station_key,
      station_run_id: record.external_id,
      station_status: record.payload["station_status"],
      failure_category: failure_category,
      findings: [
        run_slice_finding(
          failure_category,
          "Phase 1 station #{station.station_key} stopped before completing the station plan.",
          %{
            "station_key" => station.station_key,
            "station_run_id" => record.external_id,
            "station_status" => record.payload["station_status"]
          }
        )
      ]
    }
  end

  defp active_attempt_failure(args, active_attempt) do
    slice_id = PayloadHelpers.fetch_required!(args, :slice_id)
    run_attempt_id = PayloadHelpers.fetch_required!(args, :run_attempt_id)
    active_run_attempt_id = active_attempt.payload["run_attempt_id"] || active_attempt.external_id

    %{
      schema_version: @schema_version,
      category: "run_slice_preflight_failure",
      failure_category: "one_active_attempt_per_slice",
      slice_id: slice_id,
      run_attempt_id: run_attempt_id,
      active_run_attempt_id: active_run_attempt_id,
      findings: [
        run_slice_finding(
          "one_active_attempt_per_slice",
          "RunSlice requires exactly one active RunAttempt per Slice before station execution.",
          %{
            "slice_id" => slice_id,
            "run_attempt_id" => run_attempt_id,
            "active_run_attempt_id" => active_run_attempt_id
          }
        )
      ]
    }
  end

  defp run_slice_finding(finding_code, message, details) do
    %{
      schema_version: @finding_schema_version,
      category: "run_slice_failure_finding",
      finding_code: finding_code,
      message: message,
      details: details
    }
  end

  defp next_station_key(position) do
    Phase1.station_keys()
    |> Enum.at(position)
  end

  defp stop_after?(summary, opts) do
    case Keyword.get(opts, :stop_after) do
      nil -> false
      count -> summary.processed_station_count >= count
    end
  end

  defp halt_after_enqueue?(station, opts),
    do: station.station_key == option_string(opts, :halt_after_enqueue)

  defp fail_station?(station, opts), do: station.station_key == option_string(opts, :fail_station)

  defp option_string(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      value -> to_string(value)
    end
  end

  defp resumed_count(%{source: "resumed"}), do: 1
  defp resumed_count(_station_summary), do: 0

  defp ensure_one_active_attempt_per_slice(args) do
    slice_id = PayloadHelpers.fetch_required!(args, :slice_id)
    run_attempt_id = PayloadHelpers.fetch_required!(args, :run_attempt_id)

    case fetch_active_attempt_for_other_run(slice_id, run_attempt_id) do
      nil -> :ok
      active_attempt -> {:error, active_attempt_failure(args, active_attempt)}
    end
  end

  defp fetch_active_attempt_for_other_run(slice_id, run_attempt_id) do
    result =
      Repo.query!(
        """
        SELECT id::text, external_id, name, status, payload, inserted_at, updated_at
        FROM run_attempts
        WHERE status = 'active'
          AND payload->>'slice_id' = $1
          AND external_id <> $2
        ORDER BY inserted_at
        LIMIT 1
        """,
        [slice_id, run_attempt_id],
        log: false
      )

    case result.rows do
      [] -> nil
      [row] -> row_to_record(row)
    end
  end

  defp station_sort_key(payload) do
    {
      numeric_position(payload["attempt_number"]),
      Enum.find_index(Phase1.station_keys(), &(&1 == payload["station_key"])) || 999,
      payload["station_key"]
    }
  end

  defp numeric_position(value) when is_integer(value), do: value

  defp numeric_position(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> 999
    end
  end

  defp numeric_position(_value), do: 999

  defp merge_payload(record, updates) do
    %{record | payload: Map.merge(record.payload, updates)}
  end

  defp fetch_resource(table, external_id) when table in ["station_runs", "station_effects"] do
    result =
      Repo.query!(
        """
        SELECT id::text, external_id, name, status, payload, inserted_at, updated_at
        FROM #{table}
        WHERE external_id = $1
        """,
        [external_id],
        log: false
      )

    case result.rows do
      [] -> :error
      [row] -> {:ok, row_to_record(row)}
    end
  end

  defp insert_resource!(table, attrs) when table in ["station_runs", "station_effects"] do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.query!(
      """
      INSERT INTO #{table} (id, external_id, name, status, payload, inserted_at, updated_at)
      VALUES ($1::uuid, $2, $3, $4, ($5::text)::jsonb, $6, $6)
      ON CONFLICT (external_id) DO NOTHING
      """,
      [
        dump_uuid!(id),
        attrs.external_id,
        attrs.name,
        attrs.status,
        Jason.encode!(attrs.payload),
        now
      ],
      log: false
    )

    {:ok, record} = fetch_resource(table, attrs.external_id)
    record
  end

  defp update_payload!(record, table) when table in ["station_runs", "station_effects"] do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    result =
      Repo.query!(
        """
        UPDATE #{table}
        SET payload = ($2::text)::jsonb, updated_at = $3
        WHERE external_id = $1
        RETURNING id::text, external_id, name, status, payload, inserted_at, updated_at
        """,
        [record.external_id, Jason.encode!(record.payload), now],
        log: false
      )

    [row] = result.rows
    row_to_record(row)
  end

  defp row_to_record([id, external_id, name, status, payload, inserted_at, updated_at]) do
    %{
      id: id,
      external_id: external_id,
      name: name,
      status: status,
      payload: decode_payload(payload),
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end

  defp normalize_args(args) when is_map(args) do
    Map.new(args, fn {key, value} -> {to_string(key), value} end)
  end

  defp decode_payload(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode_payload(payload), do: payload

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> raise ArgumentError, "expected UUID string, got: #{inspect(uuid)}"
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
  end
end
