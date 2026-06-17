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

  test "reviewer-on-dossier output stores actor separation, digest, and rubric metadata" do
    review = GateEngine.build_review!(base_review_attrs())

    assert %{
             "schema_version" => "conveyor.review@1",
             "review_id" => "review-001",
             "run_attempt_id" => "run-attempt-001",
             "station_run_id" => "station-run-001",
             "reviewer_profile_id" => "reviewer-profile-001",
             "decision" => "approve",
             "evidence_refs" => [dossier_digest],
             "metadata" => %{
               "schema_version" => "conveyor.reviewer_on_dossier@1",
               "category" => "reviewer_on_dossier",
               "dossier_digest" => dossier_digest,
               "rubric_version" => "review-rubric@1",
               "reviewer_session_id" => "reviewer-session-001",
               "implementer_profile_id" => "implementer-profile-001",
               "implementer_session_id" => "implementer-session-001",
               "recommendation" => "gate",
               "summary" => "Recorded dossier evidence supports the requested change.",
               "checks" => [%{"check_id" => "CHK-001", "status" => "pass"}],
               "actor_separation" => %{
                 "reviewer_profile_distinct" => true,
                 "reviewer_session_distinct" => true
               }
             }
           } = review

    composition =
      base_attrs()
      |> Map.put(:review_id, review["review_id"])
      |> Map.put(:stages, [
        %{
          stage_key: "review",
          status: "pass",
          required: true,
          details: %{
            expected_dossier_digest: dossier_digest,
            review: review
          }
        }
      ])
      |> GateEngine.compose!()

    assert composition.decision == "pass"
    assert composition.failure_findings == []
    assert composition.gate_result["review_id"] == "review-001"

    assert [%{"stage_key" => "review", "passed" => true, "findings" => []}] =
             composition.gate_result["stage_results"]
  end

  test "malformed or non-separated reviewer output fails before gate use" do
    assert_raise ArgumentError, "reviewer output checks must be a non-empty list", fn ->
      base_review_attrs()
      |> put_in([:output, :checks], [])
      |> GateEngine.build_review!()
    end

    assert_raise ArgumentError,
                 "reviewer profile/session must be distinct from implementer",
                 fn ->
                   base_review_attrs()
                   |> Map.put(:reviewer_session_id, "implementer-session-001")
                   |> GateEngine.build_review!()
                 end
  end

  test "review stage fails closed when dossier digest does not match" do
    review = GateEngine.build_review!(base_review_attrs())

    composition =
      base_attrs()
      |> Map.put(:review_id, review["review_id"])
      |> Map.put(:stages, [
        %{
          stage_key: "review",
          status: "pass",
          required: true,
          details: %{
            expected_dossier_digest: "sha256:" <> String.duplicate("f", 64),
            review: review
          }
        }
      ])
      |> GateEngine.compose!()

    assert composition.decision == "fail"

    assert [
             %{
               "stage_key" => "review",
               "failure_categories" => ["review_dossier_digest_mismatch"],
               "next_action" => "resolve_review_evidence_before_gate"
             }
           ] = composition.failure_findings
  end

  test "test execution stage passes with baseline, calibrated acceptance, retries, and AC evidence" do
    composition =
      base_attrs()
      |> Map.put(:stages, [
        %{
          stage_key: "test_execution",
          status: "pass",
          required: true,
          details: %{
            baseline: %{
              status: "pass",
              evidence_refs: ["artifact://gate/baseline.xml"]
            },
            locked_acceptance: %{
              base_calibration: %{
                status: "fail",
                evidence_refs: ["artifact://gate/acceptance-base.xml"]
              },
              patch_result: %{
                status: "pass",
                evidence_refs: ["artifact://gate/acceptance-patch.xml"]
              },
              acceptance_results: [
                %{
                  criterion_id: "AC-001",
                  status: "passed",
                  evidence_refs: ["artifact://gate/ac-001.log"]
                },
                %{
                  criterion_id: "AC-002",
                  status: "skipped",
                  skip_allowed: true,
                  skip_reason:
                    "AC-002 is explicitly allowed to be skipped by the locked TestPack.",
                  evidence_refs: []
                }
              ],
              required_criteria: ["AC-001", "AC-002"],
              attempts: [
                %{attempt: 1, status: "infra_error", classification: "infra"},
                %{attempt: 2, status: "passed"}
              ]
            },
            flake_policy: %{allowed: true, max_retries: 2}
          }
        }
      ])
      |> GateEngine.compose!()

    assert composition.decision == "pass"
    assert composition.failure_findings == []

    assert [
             %{
               "stage_key" => "test_execution",
               "passed" => true,
               "findings" => []
             }
           ] = composition.gate_result["stage_results"]
  end

  test "test execution stage fails closed for incomplete acceptance evidence" do
    composition =
      base_attrs()
      |> Map.put(:stages, [
        %{
          stage_key: "test_execution",
          status: "pass",
          required: true,
          details: %{
            baseline: %{status: "pass", evidence_refs: ["artifact://gate/baseline.xml"]},
            locked_acceptance: %{
              base_calibration: %{
                status: "pass",
                evidence_refs: ["artifact://gate/acceptance-base.xml"]
              },
              patch_result: %{
                status: "pass",
                evidence_refs: ["artifact://gate/acceptance-patch.xml"]
              },
              acceptance_results: [
                %{criterion_id: "AC-001", status: "passed", evidence_refs: []},
                %{criterion_id: "AC-002", status: "skipped", evidence_refs: []}
              ],
              required_criteria: ["AC-001", "AC-002", "AC-003"]
            }
          }
        }
      ])
      |> GateEngine.compose!()

    assert composition.decision == "fail"

    assert [
             %{
               "stage_key" => "test_execution",
               "failure_categories" => failure_categories,
               "detail_findings" => detail_findings,
               "next_action" => "resolve_test_execution_evidence_before_gate"
             }
           ] = composition.failure_findings

    assert "acceptance_not_calibrated_red" in failure_categories
    assert "missing_acceptance_evidence" in failure_categories
    assert "skipped_acceptance_result" in failure_categories
    assert "missing_acceptance_result" in failure_categories

    assert Enum.all?(detail_findings, &(&1["category"] == "gate_test_execution"))
    assert composition.gate_result["decision"] == "fail"
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

  defp base_review_attrs do
    %{
      review_id: "review-001",
      run_attempt_id: "run-attempt-001",
      station_run_id: "station-run-001",
      reviewer_profile_id: "reviewer-profile-001",
      reviewer_session_id: "reviewer-session-001",
      implementer_profile_id: "implementer-profile-001",
      implementer_session_id: "implementer-session-001",
      dossier_digest: "sha256:" <> String.duplicate("e", 64),
      rubric_version: "review-rubric@1",
      output: %{
        decision: "approve",
        recommendation: "gate",
        summary: "Recorded dossier evidence supports the requested change.",
        findings: [
          %{
            finding_id: "RVW-001",
            severity: "info",
            message: "Dossier contains mapped acceptance and verification evidence."
          }
        ],
        checks: [
          %{
            check_id: "CHK-001",
            status: "pass"
          }
        ]
      }
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
