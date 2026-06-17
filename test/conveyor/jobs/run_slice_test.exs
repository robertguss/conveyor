defmodule Conveyor.Jobs.RunSliceTest do
  use ExUnit.Case, async: false

  alias Conveyor.Jobs.RunSlice
  alias Conveyor.Ledger
  alias Conveyor.Repo
  alias Conveyor.Stations.Phase1

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:conveyor)
    :ok
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "linear Phase 1 StationPlan resumes from persisted StationRun rows" do
    args = run_args("resume")

    assert {:ok,
            %{
              status: "paused",
              pause_reason: "stop_after",
              processed_station_count: 4,
              next_station_key: "implementer"
            }} = RunSlice.run(args, stop_after: 4)

    assert station_payloads(args.run_attempt_id)
           |> Enum.map(& &1["station_key"]) ==
             Enum.take(Phase1.station_keys(), 4)

    assert {:ok,
            %{
              status: "completed",
              station_count: 12,
              processed_station_count: 12,
              resumed_station_count: 4
            }} = RunSlice.run(args)

    payloads = station_payloads(args.run_attempt_id)

    assert Enum.map(payloads, & &1["station_key"]) == Phase1.station_keys()
    assert Enum.all?(payloads, &(&1["station_status"] == "completed"))
    assert Enum.all?(payloads, &String.starts_with?(&1["output_sha256"], "sha256:"))

    timeline = Ledger.replay_timeline(args.run_attempt_id)

    assert count_events(timeline, "station.enqueued") == 12
    assert count_events(timeline, "station.dequeued") == 12

    worker_logs = RunSlice.worker_logs_for(args.run_attempt_id)

    assert length(worker_logs) == 12
    assert Enum.all?(worker_logs, &(&1["effect_type"] == "worker_log"))
    assert Enum.all?(worker_logs, &(&1["metadata"]["result"] == "success"))
  end

  test "a crash after enqueue resumes the in-progress station without duplicating enqueue events" do
    args = run_args("crash-resume")

    assert {:ok,
            %{
              status: "paused",
              pause_reason: "halt_after_enqueue",
              processed_station_count: 1,
              stations: [%{station_key: "readiness", station_status: "running"}]
            }} = RunSlice.run(args, halt_after_enqueue: "readiness")

    assert [%{"station_key" => "readiness", "station_status" => "running"}] =
             station_payloads(args.run_attempt_id)

    assert {:ok, %{status: "completed", resumed_station_count: 0}} = RunSlice.run(args)

    timeline = Ledger.replay_timeline(args.run_attempt_id)

    assert count_events(timeline, "station.enqueued") == 12
    assert count_events(timeline, "station.dequeued") == 12
  end

  test "worker failures persist failed StationRun state, worker log, and dequeue timeline entry" do
    args = run_args("failure")

    assert {:error,
            %{
              status: "failed",
              failure: %{
                station_key: "reviewer",
                station_status: "failed",
                failure_category: "station_worker_failed"
              }
            }} = RunSlice.run(args, fail_station: "reviewer")

    payloads = station_payloads(args.run_attempt_id)
    reviewer = Enum.find(payloads, &(&1["station_key"] == "reviewer"))

    assert reviewer["station_status"] == "failed"
    assert Enum.count(payloads, &(&1["station_status"] == "completed")) == 6

    timeline = Ledger.replay_timeline(args.run_attempt_id)

    assert count_events(timeline, "station.enqueued") == 7
    assert count_events(timeline, "station.dequeued") == 7

    worker_logs = RunSlice.worker_logs_for(args.run_attempt_id)

    reviewer_log =
      Enum.find(
        worker_logs,
        &(&1["effect_id"] == "#{reviewer["station_run_id"]}:worker-log:failure")
      )

    assert reviewer_log
    assert reviewer_log["metadata"]["result"] == "failure"
    assert reviewer_log["effect_status"] == "declared"
  end

  test "Oban perform runs the complete station plan" do
    args = run_args("perform")

    assert :ok = RunSlice.perform(%Oban.Job{args: args})

    assert Phase1.station_keys() ==
             Enum.map(station_payloads(args.run_attempt_id), & &1["station_key"])
  end

  defp run_args(suffix) do
    %{
      run_attempt_id: "run-slice-#{suffix}",
      slice_id: "slice-#{suffix}",
      run_spec_sha256: "sha256:run-spec-#{suffix}"
    }
  end

  defp station_payloads(run_attempt_id), do: RunSlice.station_runs_for(run_attempt_id)

  defp count_events(timeline, event_type) do
    Enum.count(timeline, &(&1.event_type == event_type))
  end
end
