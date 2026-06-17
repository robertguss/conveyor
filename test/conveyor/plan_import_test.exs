defmodule Conveyor.PlanImportTest do
  use ExUnit.Case, async: false

  alias Conveyor.PlanImport
  alias Conveyor.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "parses sidecar YAML into a handoff-ready normalized contract and persists the plan" do
    plan_id = unique_plan_id("yaml")
    source = yaml_plan(plan_id)

    report = PlanImport.lint_source(source, "conveyor.plan.yml")

    assert %{
             schema_version: "conveyor.plan_import.report@1",
             status: "ok",
             handoff_ready: true,
             source_kind: "sidecar_yaml",
             findings: [],
             normalized_contract_summary: %{
               schema_version: "conveyor.normalized_plan_summary@1",
               plan_id: ^plan_id,
               project_key: "fastapi_tasks",
               non_goal_count: 2,
               requirement_count: 2,
               acceptance_criteria_count: 2,
               verification_command_count: 2,
               decision_count: 2,
               slice_count: 2
             }
           } = report

    assert report.contract_sha256 == PlanImport.contract_sha256(report.normalized_contract)

    imported = PlanImport.import_source!(source, "conveyor.plan.yml")

    assert imported.record.external_id == plan_id
    assert imported.record.name == "Phase 1 sample task plan"
    assert imported.record.payload["contract_sha256"] == report.contract_sha256
    assert [%{"source_kind" => "sidecar_yaml"}] = imported.record.payload["source_refs"]
  end

  test "parses fenced Markdown and retains narrative source references" do
    plan_id = unique_plan_id("markdown")
    yaml = yaml_plan(plan_id)

    markdown = """
    # Phase 1 narrative plan

    The prose can explain intent, but the fenced block is the conductor contract.

    ```conveyor-plan@1
    #{yaml}
    ```
    """

    markdown_report = PlanImport.lint_source(markdown, "plans/phase1.md")
    yaml_report = PlanImport.lint_source(yaml, "conveyor.plan.yml")

    expected_end_line =
      markdown
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.find_value(fn
        {"```", line_no} -> line_no
        {_line, _line_no} -> nil
      end)

    assert markdown_report.status == "ok"
    assert markdown_report.contract_sha256 == yaml_report.contract_sha256

    assert [
             %{
               schema_version: "conveyor.plan_source_ref@1",
               source_path: "plans/phase1.md",
               source_kind: "markdown_fence",
               start_line: 5,
               end_line: ^expected_end_line
             }
           ] = markdown_report.source_refs
  end

  test "prose-only Markdown can lint but cannot become handoff-ready" do
    report =
      PlanImport.lint_source(
        """
        # Phase 1 narrative plan

        This is only prose. It is useful context, but it is not a contract.
        """,
        "plans/prose-only.md"
      )

    assert report.status == "lint_only"
    refute report.handoff_ready
    assert report.normalized_contract == nil

    assert [
             %{
               finding_code: "missing_normalized_contract",
               severity: "error",
               path: "$"
             }
           ] = report.findings

    assert_raise ArgumentError, ~r/not handoff_ready/, fn ->
      PlanImport.import_source!("# prose only", "plans/prose-only.md")
    end
  end

  test "schema validation rejects invalid normalized contracts with structured findings" do
    invalid_source =
      unique_plan_id("invalid")
      |> plan_contract()
      |> Map.delete("goal")
      |> Jason.encode!()

    report = PlanImport.lint_source(invalid_source, "conveyor.plan.json")

    assert report.status == "error"
    refute report.handoff_ready

    assert Enum.any?(report.findings, fn finding ->
             finding.finding_code == "missing_required_field" and finding.path == "$.goal"
           end)
  end

  defp unique_plan_id(prefix) do
    "plan-#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp yaml_plan(plan_id) do
    """
    schema_version: conveyor.plan@1
    plan_id: #{plan_id}
    title: Phase 1 sample task plan
    project:
      key: fastapi_tasks
      name: FastAPI Tasks
      repository: sample_apps/fastapi_tasks
    goal: Produce PR-quality evidence for a bounded sample change without merging or deploying it.
    non_goals:
      - Auto-merge generated patches
      - Deploy the sample service
    autonomy_level: L1
    cutline: TRACER_REQUIRED
    requirements:
      - requirement_id: REQ-001
        title: Complete task endpoint
        source_ref:
          section: Requirements / Complete task endpoint
        status: ready
        acceptance_criteria:
          - ac_id: AC-001
            text: Tasks can be marked complete and the state is visible in list responses.
      - requirement_id: REQ-002
        title: Preserve list task behavior
        source_ref:
          section: Requirements / Preserve list task behavior
        status: ready
        acceptance_criteria:
          - ac_id: AC-002
            text: Existing list behavior remains stable after completion support lands.
    verification_commands:
      - command_id: VERIFY-001
        acceptance_refs:
          - AC-001
          - AC-002
        command:
          - python3
          - "-m"
          - pytest
      - command_id: VERIFY-002
        acceptance_refs:
          - AC-002
        command:
          - mix
          - test
    decisions:
      - decision_id: DEC-001
        title: Keep implementation in the sample app
        rationale: Phase 1 demonstrates the tracer against a bounded local fixture.
      - decision_id: DEC-002
        title: Keep autonomy at L1
        rationale: Conveyor may prepare evidence and patches but does not merge or deploy.
    slices:
      - slice_id: SLICE-001
        title: Add task completion behavior
        requirement_refs:
          - REQ-001
        decision_refs:
          - DEC-001
          - DEC-002
        verification_refs:
          - VERIFY-001
        likely_files:
          - sample_apps/fastapi_tasks/src/fastapi_tasks/app.py
        conflict_domains:
          - sample-app
          - api-contract
        autonomy_level: L1
      - slice_id: SLICE-002
        title: Preserve list task behavior
        requirement_refs:
          - REQ-002
        decision_refs:
          - DEC-002
        verification_refs:
          - VERIFY-001
          - VERIFY-002
        likely_files:
          - sample_apps/fastapi_tasks/tests/test_baseline.py
        conflict_domains:
          - sample-app
          - tests
        autonomy_level: L1
    """
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
        }
      ],
      "verification_commands" => [
        %{
          "command_id" => "VERIFY-001",
          "acceptance_refs" => ["AC-001"],
          "command" => ["mix", "test"]
        }
      ],
      "decisions" => [
        %{
          "decision_id" => "DEC-001",
          "title" => "Keep autonomy at L1",
          "rationale" => "Conveyor may prepare evidence and patches but does not merge or deploy."
        }
      ],
      "slices" => [
        %{
          "slice_id" => "SLICE-001",
          "title" => "Add task completion behavior",
          "requirement_refs" => ["REQ-001"],
          "decision_refs" => ["DEC-001"],
          "verification_refs" => ["VERIFY-001"],
          "likely_files" => ["sample_apps/fastapi_tasks/src/fastapi_tasks/app.py"],
          "conflict_domains" => ["sample-app", "api-contract"],
          "autonomy_level" => "L1"
        }
      ]
    }
  end
end
