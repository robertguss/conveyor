defmodule Conveyor.GateEngineTest do
  use ExUnit.Case, async: false

  alias Conveyor.GateEngine
  alias Conveyor.Domain.RunAttempt
  alias Conveyor.Domain.Slice
  alias Conveyor.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "passes only when every required stage passes and emits transition contexts" do
    composition =
      base_attrs()
      |> Map.put(:stages, [
        %{stage_key: "artifact_integrity", status: "pass", required: true},
        %{stage_key: "policy", status: "passed", required: true},
        %{
          stage_key: "optional_lint",
          status: "fail",
          required: false,
          next_action: "inspect_optional_lint"
        }
      ])
      |> GateEngine.compose!()

    assert composition.decision == "pass"
    assert composition.failure_findings == []
    assert composition.failed_required_stage_count == 0

    assert %{
             "decision" => "pass",
             "gate_version" => "gate@1",
             "gate_code_digest" => gate_code_digest,
             "policy_digest" => policy_digest,
             "contract_lock_digest" => contract_lock_digest,
             "canary_suite_version" => "canary-suite@1",
             "stage_results" => stage_results,
             "stage_log" => stage_log,
             "transition_plan" => transition_plan
           } = composition.gate_result

    assert gate_code_digest =~ ~r/^sha256:[a-f0-9]{64}$/
    assert policy_digest =~ ~r/^sha256:[a-f0-9]{64}$/
    assert contract_lock_digest =~ ~r/^sha256:[a-f0-9]{64}$/
    assert length(stage_results) == 3

    assert Enum.map(stage_results, & &1["stage_key"]) == [
             "artifact_integrity",
             "optional_lint",
             "policy"
           ]

    assert Enum.all?(stage_log, &(&1["logged_at"] == "2026-06-17T01:00:00Z"))

    assert %{
             "run_attempt" => %{
               "allowed" => true,
               "transition" => "gate",
               "context" => %{"gate_complete" => true, "gate_decision" => "pass"}
             },
             "slice" => %{"allowed" => true, "transition" => "gate"}
           } = transition_plan

    assert composition.summary == GateEngine.summary(composition.gate_result)

    {run_attempt, slice} = create_gateable_records()

    assert {:ok, transitions} =
             GateEngine.apply_transitions(composition, run_attempt, slice,
               trace_id: "trace-gate-engine-pass",
               span_id: "span-gate-engine-pass",
               stream_id: "gate-engine-pass"
             )

    assert transitions.run_attempt.payload["attempt_state"] == "gated"
    assert transitions.slice.payload["slice_state"] == "gated"

    assert Enum.map(transitions.ledger_events, & &1.event_type) == [
             "domain_state_transition.run_attempt.gate",
             "domain_state_transition.slice.gate"
           ]
  end

  test "any required stage failure blocks and names stage plus next action" do
    composition =
      base_attrs()
      |> Map.put(:stages, [
        %{stage_key: "artifact_integrity", status: "pass", required: true},
        %{
          stage_key: "canary",
          status: "fail",
          required: true,
          next_action: "rerun_canary_suite"
        },
        %{stage_key: "non_required_observation", status: "fail", required: false}
      ])
      |> GateEngine.compose!()

    assert composition.decision == "fail"
    assert composition.failed_required_stage_count == 1

    assert [
             %{
               "category" => "required_gate_stage_failed",
               "severity" => "blocking",
               "stage_key" => "canary",
               "next_action" => "rerun_canary_suite",
               "matrix_ref" => "conveyor-quality-ci-evals-vmr.13",
               "harness_ref" => "conveyor-quality-ci-evals-vmr.14"
             } = finding
           ] = composition.failure_findings

    assert composition.gate_result["decision"] == "fail"
    assert composition.gate_result["gate_version"] == "gate@1"
    assert composition.gate_result["gate_code_digest"] == base_attrs().gate_code_digest
    assert composition.gate_result["policy_digest"] == base_attrs().policy_digest
    assert composition.gate_result["contract_lock_digest"] == base_attrs().contract_lock_digest
    assert composition.gate_result["canary_suite_version"] == "canary-suite@1"
    assert composition.gate_result["finding_refs"] == [finding["finding_ref"]]

    assert %{
             "run_attempt" => %{
               "allowed" => false,
               "blocked_by" => ["canary"],
               "context" => %{
                 "gate_complete" => false,
                 "gate_decision" => "fail",
                 "reason" => "required gate stages failed: canary"
               }
             },
             "slice" => %{"allowed" => false, "blocked_by" => ["canary"]}
           } = composition.transition_plan

    assert {:error,
            %{
              category: "gate_transition_blocked",
              failed_required_stages: ["canary"],
              action: "keep_run_attempt_and_slice_ungated"
            }} = GateEngine.apply_transitions(composition, %{}, %{})

    assert Enum.any?(composition.stage_log, fn log ->
             log["stage_key"] == "canary" and log["logged_at"] == "2026-06-17T01:00:00Z"
           end)
  end

  defp base_attrs do
    %{
      gate_result_id: "gate-result-001",
      run_attempt_id: "run-attempt-001",
      station_run_id: "station-run-001",
      suite_kind: "focused",
      gate_version: "gate@1",
      gate_code_digest: "sha256:" <> String.duplicate("a", 64),
      policy_digest: "sha256:" <> String.duplicate("b", 64),
      contract_lock_digest: "sha256:" <> String.duplicate("c", 64),
      canary_suite_version: "canary-suite@1",
      evidence_refs: ["sha256:" <> String.duplicate("d", 64)],
      evaluated_at: "2026-06-17T01:00:00Z"
    }
  end

  defp create_gateable_records do
    run_attempt_payload =
      %{
        run_attempt_id: "run-attempt-001",
        slice_id: "slice-gate-engine-001",
        run_spec_sha256: "sha256:" <> String.duplicate("e", 64),
        attempt_number: 1
      }
      |> RunAttempt.build!()
      |> Map.merge(%{
        "attempt_state" => "reviewed",
        "attempt_status" => "reviewed",
        "lifecycle_state" => "reviewed"
      })

    slice_payload =
      %{slice_id: "slice-gate-engine-001", plan_id: "plan-gate-engine-001"}
      |> Slice.build!()
      |> Map.merge(%{"slice_state" => "in_progress", "lifecycle_state" => "in_progress"})

    assert {:ok, run_attempt} =
             Ash.create(
               RunAttempt,
               %{
                 external_id: run_attempt_payload["run_attempt_id"],
                 name: "gate engine run attempt",
                 status: "active",
                 payload: run_attempt_payload
               },
               action: :create
             )

    assert {:ok, slice} =
             Ash.create(
               Slice,
               %{
                 external_id: slice_payload["slice_id"],
                 name: "gate engine slice",
                 status: "active",
                 payload: slice_payload
               },
               action: :create
             )

    {run_attempt, slice}
  end
end
