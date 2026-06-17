defmodule Conveyor.Stations.Phase1 do
  @moduledoc """
  Linear Phase 1 station topology and deterministic station fingerprints.

  This module is intentionally data-first. Later beads can replace individual
  worker entries with richer modules without changing the persisted
  StationRun/StationEffect contracts.
  """

  alias Conveyor.Domain.PayloadHelpers

  @schema_version "conveyor.phase1_station_plan@1"
  @worker_log_schema_version "conveyor.station_worker_log@1"

  @station_specs [
    %{
      station_key: "readiness",
      worker_key: "phase1.readiness",
      intent: "Verify locked inputs, runtime prerequisites, and run readiness."
    },
    %{
      station_key: "baseline",
      worker_key: "phase1.baseline",
      intent: "Capture baseline checks before implementation stations mutate the workspace."
    },
    %{
      station_key: "acceptance_calibration",
      worker_key: "phase1.acceptance_calibration",
      intent: "Bind acceptance criteria to executable verification expectations."
    },
    %{
      station_key: "context_scout",
      worker_key: "phase1.context_scout",
      intent: "Collect project context and implementation boundaries."
    },
    %{
      station_key: "implementer",
      worker_key: "phase1.implementer",
      intent: "Apply the scoped implementation work for the run attempt."
    },
    %{
      station_key: "evidence",
      worker_key: "phase1.evidence",
      intent: "Collect reproducible evidence and artifact references."
    },
    %{
      station_key: "reviewer",
      worker_key: "phase1.reviewer",
      intent: "Review produced changes and evidence against the locked contract."
    },
    %{
      station_key: "gate",
      worker_key: "phase1.gate",
      intent: "Run gate checks and emit a pass/fail decision."
    },
    %{
      station_key: "canary",
      worker_key: "phase1.canary",
      intent: "Verify gate freshness with canary evidence."
    },
    %{
      station_key: "stale_effect_reconciliation",
      worker_key: "phase1.stale_effect_reconciliation",
      intent: "Reconcile stale effects before final projection."
    },
    %{
      station_key: "sandbox_reaping",
      worker_key: "phase1.sandbox_reaping",
      intent: "Clean up station sandbox state after durable evidence is recorded."
    },
    %{
      station_key: "artifact_projection",
      worker_key: "phase1.artifact_projection",
      intent: "Project final artifacts and manifest references."
    }
  ]

  def schema_version, do: @schema_version
  def worker_log_schema_version, do: @worker_log_schema_version
  def station_count, do: length(@station_specs)
  def station_keys, do: Enum.map(@station_specs, & &1.station_key)

  def station_plan(args) when is_map(args) do
    run_attempt_id = PayloadHelpers.fetch_required!(args, :run_attempt_id)
    run_spec_sha256 = PayloadHelpers.get(args, :run_spec_sha256, "sha256:run-spec-unset")

    @station_specs
    |> Enum.with_index(1)
    |> Enum.map(fn {spec, position} ->
      station_spec = station_spec(spec, position)
      input_payload = input_payload(run_attempt_id, run_spec_sha256, spec, position)

      %{
        station_key: spec.station_key,
        worker_key: spec.worker_key,
        position: position,
        intent: spec.intent,
        durable?: true,
        station_spec_sha256: PayloadHelpers.canonical_sha256(station_spec),
        input_sha256: PayloadHelpers.canonical_sha256(input_payload),
        output_sha256: output_sha256(spec.station_key, input_payload),
        worker_log_ref: "worker-log://#{run_attempt_id}/#{spec.station_key}"
      }
    end)
  end

  def station_run_id(args, station) when is_map(args) and is_map(station) do
    run_attempt_id = PayloadHelpers.fetch_required!(args, :run_attempt_id)

    "#{run_attempt_id}:#{String.pad_leading(to_string(station.position), 2, "0")}:#{station.station_key}"
  end

  def worker_output_sha256(station, result) when is_map(station) do
    PayloadHelpers.canonical_sha256(%{
      schema_version: @worker_log_schema_version,
      station_key: station.station_key,
      worker_key: station.worker_key,
      result: to_string(result),
      input_sha256: station.input_sha256
    })
  end

  def worker_log(station, args, result, message) when is_map(station) and is_map(args) do
    result = to_string(result)
    station_run_id = station_run_id(args, station)

    %{
      schema_version: @worker_log_schema_version,
      category: "station_worker_log",
      run_attempt_id: PayloadHelpers.fetch_required!(args, :run_attempt_id),
      station_run_id: station_run_id,
      station_key: station.station_key,
      worker_key: station.worker_key,
      result: result,
      message: message,
      input_sha256: station.input_sha256,
      output_sha256: worker_output_sha256(station, result),
      emitted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()
    }
  end

  defp station_spec(spec, position) do
    %{
      "schema_version" => @schema_version,
      "station_key" => spec.station_key,
      "worker_key" => spec.worker_key,
      "position" => position,
      "intent" => spec.intent,
      "durable" => true,
      "previous_station_key" => previous_station_key(position)
    }
  end

  defp input_payload(run_attempt_id, run_spec_sha256, spec, position) do
    %{
      "schema_version" => @schema_version,
      "run_attempt_id" => run_attempt_id,
      "run_spec_sha256" => run_spec_sha256,
      "station_key" => spec.station_key,
      "position" => position,
      "previous_station_key" => previous_station_key(position)
    }
  end

  defp output_sha256(station_key, input_payload) do
    PayloadHelpers.canonical_sha256(%{
      "schema_version" => @schema_version,
      "station_key" => station_key,
      "input_sha256" => PayloadHelpers.canonical_sha256(input_payload),
      "result" => "success"
    })
  end

  defp previous_station_key(1), do: nil

  defp previous_station_key(position) do
    @station_specs
    |> Enum.at(position - 2)
    |> Map.fetch!(:station_key)
  end
end
