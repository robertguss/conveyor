defmodule Conveyor.PlanAuditTest do
  use ExUnit.Case, async: true

  alias Conveyor.PlanAudit

  @source_path "plans/sample.conveyor.plan.json"
  @rerun_command ["mix", "conveyor.plan_audit", @source_path]

  test "good sample plan reaches handoff_ready with structured audit-score JSON" do
    report = audit_plan(plan_contract("plan-audit-good"))

    assert %{
             schema_version: "conveyor.plan_audit.report@1",
             category: "plan_audit",
             status: "handoff_ready",
             handoff_ready: true,
             exit_code: 0,
             score: 100,
             max_score: 100,
             cutline: "TRACER_REQUIRED",
             findings: [],
             rerun_command: @rerun_command
           } = report

    assert Enum.all?(report.dimensions, &(&1.status == "pass"))

    json = report |> Jason.encode!() |> Jason.decode!()
    assert json["schema_version"] == "conveyor.plan_audit.report@1"
    assert json["score"] == 100
  end

  test "missing acceptance criteria produces a stable blocking finding" do
    contract =
      plan_contract("plan-audit-missing-acceptance")
      |> put_in(["requirements", Access.at(0), "acceptance_criteria"], [])

    report = audit_plan(contract)

    assert_blocking_finding(report, "acceptance_coverage", "missing_acceptance_criteria")
  end

  test "missing tests produces a stable blocking finding" do
    contract =
      plan_contract("plan-audit-missing-tests")
      |> Map.put("verification_commands", [])

    report = audit_plan(contract)

    assert_blocking_finding(report, "testability", "missing_verification_commands")
  end

  test "missing decisions produces a stable blocking finding" do
    contract =
      plan_contract("plan-audit-missing-decisions")
      |> Map.put("decisions", [])

    report = audit_plan(contract)

    assert_blocking_finding(report, "architecture_decisions", "missing_architecture_decisions")
  end

  test "broken requirement traceability produces a stable blocking finding" do
    contract =
      plan_contract("plan-audit-broken-traceability")
      |> put_in(["slices", Access.at(0), "requirement_refs"], ["REQ-999"])

    report = audit_plan(contract)

    assert_blocking_finding(report, "requirement_traceability", "unknown_requirement_ref")
  end

  test "missing risk policy produces a stable blocking finding" do
    contract =
      plan_contract("plan-audit-missing-risk")
      |> Map.put("cutline", "ADVISORY_ONLY")

    report = audit_plan(contract)

    assert_blocking_finding(report, "risk_policy", "missing_risk_policy")
  end

  test "missing likely files produces a stable blocking finding" do
    contract =
      plan_contract("plan-audit-missing-likely-files")
      |> put_in(["slices", Access.at(0), "likely_files"], [])

    report = audit_plan(contract)

    assert_blocking_finding(report, "likely_files", "missing_likely_files")
  end

  defp audit_plan(contract) do
    contract
    |> Jason.encode!()
    |> PlanAudit.audit_source(@source_path)
  end

  defp assert_blocking_finding(report, dimension, finding_code) do
    assert report.status == "blocked"
    assert report.handoff_ready == false
    assert report.exit_code == 4
    assert report.score < 100

    assert %{
             severity: "blocking",
             dimension: ^dimension,
             finding_code: ^finding_code,
             next_actions: [
               %{
                 schema_version: "conveyor.plan_audit.next_action@1",
                 label: label,
                 command: @rerun_command
               }
             ],
             rerun_command: @rerun_command
           } = Enum.find(report.findings, &(&1.finding_code == finding_code))

    assert is_binary(label)
    assert label != ""
    assert Enum.any?(report.next_actions, &(&1.command == @rerun_command))

    assert Enum.any?(report.dimensions, fn score ->
             score.dimension == dimension and score.status == "blocked" and
               finding_code in score.finding_codes
           end)
  end

  defp plan_contract(plan_id) do
    %{
      "schema_version" => "conveyor.plan@1",
      "plan_id" => plan_id,
      "title" => "Phase 1 sample task plan",
      "project" => %{
        "key" => "fastapi_tasks",
        "name" => "FastAPI Tasks",
        "repository" => "sample_apps/fastapi_tasks"
      },
      "goal" =>
        "Produce PR-quality evidence for a bounded sample change without merging or deploying it.",
      "non_goals" => [
        "Auto-merge generated patches",
        "Deploy the sample service"
      ],
      "autonomy_level" => "L1",
      "cutline" => "TRACER_REQUIRED",
      "requirements" => [
        %{
          "requirement_id" => "REQ-001",
          "title" => "Complete task endpoint",
          "acceptance_criteria" => [
            %{
              "ac_id" => "AC-001",
              "text" => "Tasks can be marked complete and the state is visible in list responses."
            }
          ]
        },
        %{
          "requirement_id" => "REQ-002",
          "title" => "Preserve list task behavior",
          "acceptance_criteria" => [
            %{
              "ac_id" => "AC-002",
              "text" => "Existing list behavior remains stable after completion support lands."
            }
          ]
        }
      ],
      "verification_commands" => [
        %{"command_id" => "VERIFY-001", "command" => ["python3", "-m", "pytest"]},
        %{"command_id" => "VERIFY-002", "command" => ["mix", "test"]}
      ],
      "decisions" => [
        %{
          "decision_id" => "DEC-001",
          "title" => "Keep implementation in the sample app",
          "rationale" => "Phase 1 demonstrates the tracer against a bounded local fixture."
        },
        %{
          "decision_id" => "DEC-002",
          "title" => "Keep autonomy at L1",
          "rationale" => "Conveyor may prepare evidence and patches but does not merge or deploy."
        }
      ],
      "slices" => [
        %{
          "slice_id" => "SLICE-001",
          "title" => "Add task completion behavior",
          "requirement_refs" => ["REQ-001"],
          "decision_refs" => ["DEC-001", "DEC-002"],
          "verification_refs" => ["VERIFY-001"],
          "likely_files" => ["sample_apps/fastapi_tasks/src/fastapi_tasks/app.py"],
          "conflict_domains" => ["sample-app", "api-contract"],
          "autonomy_level" => "L1"
        },
        %{
          "slice_id" => "SLICE-002",
          "title" => "Preserve list task behavior",
          "requirement_refs" => ["REQ-002"],
          "decision_refs" => ["DEC-002"],
          "verification_refs" => ["VERIFY-001", "VERIFY-002"],
          "likely_files" => ["sample_apps/fastapi_tasks/tests/test_baseline.py"],
          "conflict_domains" => ["sample-app", "tests"],
          "autonomy_level" => "L1"
        }
      ]
    }
  end
end
