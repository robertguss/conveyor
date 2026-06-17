defmodule Conveyor.PlanAuditTest do
  use ExUnit.Case, async: true

  alias Conveyor.PlanAudit

  @source_path "plans/sample.conveyor.plan.json"
  @rerun_command ["mix", "conveyor.plan_audit", @source_path]
  @vmr_ref "conveyor-quality-ci-evals-vmr.13"

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

    assert [
             %{
               schema_version: "conveyor.human_decision@1",
               category: "human_decision",
               decision_id: "DEC-001",
               decision_type: "architecture",
               rationale: "Phase 1 demonstrates the tracer against a bounded local fixture.",
               vmr_ref: @vmr_ref
             },
             %{
               schema_version: "conveyor.human_decision@1",
               category: "human_decision",
               decision_id: "DEC-002",
               decision_type: "scope_exclusion",
               rationale:
                 "Conveyor may prepare evidence and patches but does not merge or deploy.",
               vmr_ref: @vmr_ref
             }
           ] = report.human_decision_records

    assert report.human_approval_records == []

    assert %{
             schema_version: "conveyor.plan_traceability_matrix@1",
             requirement_rows: [
               %{
                 requirement_id: "REQ-001",
                 status: "ready",
                 source_ref: %{"section" => "Requirements / Complete task endpoint"},
                 acceptance_ids: ["AC-001"],
                 slice_ids: ["SLICE-001"],
                 verification_command_ids: ["VERIFY-001"]
               },
               %{
                 requirement_id: "REQ-002",
                 status: "ready",
                 acceptance_ids: ["AC-002"],
                 slice_ids: ["SLICE-002"],
                 verification_command_ids: ["VERIFY-001", "VERIFY-002"]
               }
             ],
             slice_rows: [
               %{slice_id: "SLICE-001", orphan: false},
               %{slice_id: "SLICE-002", orphan: false}
             ],
             verification_rows: [
               %{command_id: "VERIFY-001", acceptance_refs: ["AC-001", "AC-002"]},
               %{command_id: "VERIFY-002", acceptance_refs: ["AC-002"]}
             ],
             contract_change_rows: []
           } = report.traceability_matrix

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

  test "contract-affecting changes require rationale, approval rationale, and artifact digests" do
    contract =
      plan_contract("plan-audit-missing-contract-change-rationale")
      |> Map.put("contract_changes", [
        %{
          "change_id" => "CHANGE-001",
          "change_type" => "acceptance_weakening",
          "summary" => "Remove the visible list-response acceptance check.",
          "rationale" => "",
          "decision_refs" => ["DEC-002"],
          "approval_refs" => ["APPROVAL-001"],
          "artifact_digests" => []
        }
      ])
      |> Map.put("human_approvals", [
        %{
          "approval_id" => "APPROVAL-001",
          "approval_type" => "acceptance_weakening",
          "actor" => "owner@example.com",
          "target" => "CHANGE-001",
          "reason" => "",
          "artifact_digests" => []
        }
      ])

    report = audit_plan(contract)

    assert_blocking_finding(report, "architecture_decisions", "missing_contract_change_rationale")

    assert_blocking_finding(
      report,
      "architecture_decisions",
      "missing_contract_change_artifact_digest"
    )

    assert_blocking_finding(report, "architecture_decisions", "missing_approval_rationale")
    assert_blocking_finding(report, "architecture_decisions", "missing_approval_artifact_digest")

    assert Enum.any?(report.findings, fn finding ->
             finding.finding_code == "missing_contract_change_rationale" and
               finding.vmr_ref == @vmr_ref
           end)

    assert [
             %{
               change_id: "CHANGE-001",
               change_type: "acceptance_weakening",
               decision_refs: ["DEC-002"],
               approval_refs: ["APPROVAL-001"],
               artifact_digests: [],
               approved: true,
               vmr_ref: @vmr_ref
             }
           ] = report.traceability_matrix.contract_change_rows
  end

  test "approved contract changes emit structured HumanApproval records" do
    digest = "sha256:contract-change-artifact"

    contract =
      plan_contract("plan-audit-approved-contract-change")
      |> Map.put("contract_changes", [
        %{
          "change_id" => "CHANGE-001",
          "change_type" => "external_integration",
          "summary" => "Record a human-approved external integration contract.",
          "rationale" => "The external integration boundary changes reviewed evidence.",
          "decision_refs" => ["DEC-001"],
          "approval_refs" => ["APPROVAL-001"],
          "artifact_digests" => [digest]
        }
      ])
      |> Map.put("human_approvals", [
        %{
          "approval_id" => "APPROVAL-001",
          "approval_type" => "external_integration",
          "actor" => "owner@example.com",
          "target" => "CHANGE-001",
          "reason" => "Reviewed the external integration contract and evidence digest.",
          "artifact_digests" => [digest]
        }
      ])

    report = audit_plan(contract)

    assert report.status == "handoff_ready"
    assert report.handoff_ready == true

    assert [
             %{
               schema_version: "conveyor.human_approval@1",
               category: "human_approval",
               approval_id: "APPROVAL-001",
               approval_type: "external_integration",
               actor: "owner@example.com",
               target: "CHANGE-001",
               reason: "Reviewed the external integration contract and evidence digest.",
               artifact_digests: [^digest],
               evidence_refs: [^digest],
               vmr_ref: @vmr_ref
             }
           ] = report.human_approval_records

    assert [
             %{
               change_id: "CHANGE-001",
               approved: true,
               artifact_digests: [^digest],
               vmr_ref: @vmr_ref
             }
           ] = report.traceability_matrix.contract_change_rows
  end

  test "broken requirement traceability produces a stable blocking finding" do
    contract =
      plan_contract("plan-audit-broken-traceability")
      |> put_in(["slices", Access.at(0), "requirement_refs"], ["REQ-999"])

    report = audit_plan(contract)

    assert_blocking_finding(report, "requirement_traceability", "unknown_requirement_ref")
  end

  test "orphan requirements fail audit and appear in the traceability matrix" do
    contract =
      plan_contract("plan-audit-orphan-requirement")
      |> put_in(["slices", Access.at(1), "requirement_refs"], [])

    report = audit_plan(contract)

    assert_blocking_finding(report, "requirement_traceability", "uncovered_requirement")

    assert Enum.any?(report.traceability_matrix.requirement_rows, fn row ->
             row.requirement_id == "REQ-002" and row.slice_ids == []
           end)
  end

  test "orphan slices fail audit and appear in the traceability matrix" do
    contract =
      plan_contract("plan-audit-orphan-slice")
      |> put_in(["slices", Access.at(0), "requirement_refs"], [])
      |> put_in(["slices", Access.at(0), "decision_refs"], [])

    report = audit_plan(contract)

    assert_blocking_finding(report, "requirement_traceability", "orphan_slice")

    assert Enum.any?(report.traceability_matrix.slice_rows, fn row ->
             row.slice_id == "SLICE-001" and row.orphan == true
           end)
  end

  test "open requirements block handoff_ready" do
    contract =
      plan_contract("plan-audit-open-requirement")
      |> put_in(["requirements", Access.at(0), "status"], "open")

    report = audit_plan(contract)

    assert_blocking_finding(report, "requirement_traceability", "open_requirement_blocks_handoff")
  end

  test "deferred and out_of_scope requirements are explicit in the matrix without blocking" do
    deferred = %{
      "requirement_id" => "REQ-003",
      "title" => "Future search filter",
      "source_ref" => %{"section" => "Deferred / Future search filter"},
      "status" => "deferred",
      "acceptance_criteria" => [
        %{"ac_id" => "AC-003", "text" => "Search filtering is deferred to a later slice."}
      ]
    }

    out_of_scope = %{
      "requirement_id" => "REQ-004",
      "title" => "Production deployment",
      "source_ref" => %{"section" => "Out of scope / Production deployment"},
      "status" => "out_of_scope",
      "acceptance_criteria" => [
        %{"ac_id" => "AC-004", "text" => "Production deployment is explicitly out of scope."}
      ]
    }

    contract =
      plan_contract("plan-audit-deferred-requirements")
      |> Map.update!("requirements", &(&1 ++ [deferred, out_of_scope]))

    report = audit_plan(contract)

    assert report.status == "handoff_ready"
    assert report.handoff_ready == true
    refute Enum.any?(report.findings, &(&1.finding_code == "uncovered_requirement"))
    refute Enum.any?(report.findings, &(&1.finding_code == "unverified_acceptance_criterion"))

    assert Enum.any?(report.traceability_matrix.requirement_rows, fn row ->
             row.requirement_id == "REQ-003" and row.status == "deferred" and
               row.deferred == true and row.slice_ids == []
           end)

    assert Enum.any?(report.traceability_matrix.requirement_rows, fn row ->
             row.requirement_id == "REQ-004" and row.status == "out_of_scope" and
               row.out_of_scope == true and row.slice_ids == []
           end)
  end

  test "verification commands must map to acceptance criteria" do
    contract =
      plan_contract("plan-audit-unmapped-test")
      |> put_in(["verification_commands", Access.at(0), "acceptance_refs"], [])

    report = audit_plan(contract)

    assert_blocking_finding(report, "testability", "missing_verification_acceptance_refs")
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
          "source_ref" => %{"section" => "Requirements / Complete task endpoint"},
          "status" => "ready",
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
          "source_ref" => %{"section" => "Requirements / Preserve list task behavior"},
          "status" => "ready",
          "acceptance_criteria" => [
            %{
              "ac_id" => "AC-002",
              "text" => "Existing list behavior remains stable after completion support lands."
            }
          ]
        }
      ],
      "verification_commands" => [
        %{
          "command_id" => "VERIFY-001",
          "acceptance_refs" => ["AC-001", "AC-002"],
          "command" => ["python3", "-m", "pytest"]
        },
        %{
          "command_id" => "VERIFY-002",
          "acceptance_refs" => ["AC-002"],
          "command" => ["mix", "test"]
        }
      ],
      "decisions" => [
        %{
          "decision_id" => "DEC-001",
          "title" => "Keep implementation in the sample app",
          "decision_type" => "architecture",
          "rationale" => "Phase 1 demonstrates the tracer against a bounded local fixture."
        },
        %{
          "decision_id" => "DEC-002",
          "title" => "Keep autonomy at L1",
          "decision_type" => "scope_exclusion",
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
