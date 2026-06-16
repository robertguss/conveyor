defmodule Conveyor.Domain.PlanningGraphTest do
  use ExUnit.Case, async: false

  alias Conveyor.Domain.PlanningGraph

  test "creates the complete planning graph from a sample plan" do
    result = PlanningGraph.create!(sample_plan())

    assert result.records.plan.external_id == "plan-phase1-demo"
    assert length(result.records.requirements) == 2
    assert length(result.records.human_decisions) == 2
    assert length(result.records.epics) == 1
    assert length(result.records.slices) == 2
    assert length(result.records.agent_briefs) == 3

    for slice <- result.records.slices do
      assert [_ | _] = slice.payload["requirement_refs"]
      assert [_ | _] = slice.payload["decision_refs"]
      assert [_ | _] = slice.payload["improvement_refs"]
      assert [_ | _] = slice.payload["likely_files"]
      assert [_ | _] = slice.payload["conflict_domains"]
      assert slice.payload["autonomy_ceiling"] == "L1"
    end
  end

  test "emits a structured traceability summary for slices and AgentBrief versions" do
    graph = PlanningGraph.build!(sample_plan())
    summary = PlanningGraph.traceability_summary(graph)

    assert %{
             schema_version: "conveyor.planning_traceability_summary@1",
             category: "planning_traceability",
             plan_id: "plan-phase1-demo",
             status: "ok",
             requirement_count: 2,
             decision_count: 2,
             epic_count: 1,
             slice_count: 2,
             agent_brief_count: 3,
             locked_agent_brief_versions: ["brief-complete-task@1", "brief-list-tasks@1"],
             rerun_agent_brief_versions: ["brief-complete-task@2"],
             orphan_finding_count: 0,
             orphan_findings: []
           } = summary

    assert "brief-complete-task@1" in summary.agent_brief_versions
    assert "brief-complete-task@2" in summary.agent_brief_versions
    assert "brief-list-tasks@1" in summary.agent_brief_versions

    assert [
             %{
               slice_id: "slice-complete-task",
               requirement_refs: ["REQ-001"],
               decision_refs: ["DEC-001"],
               improvement_refs: ["IMP-001"],
               agent_brief_key: "brief-complete-task@1"
             },
             %{
               slice_id: "slice-list-tasks",
               requirement_refs: ["REQ-002"],
               decision_refs: ["DEC-002"],
               improvement_refs: ["IMP-002"],
               agent_brief_key: "brief-list-tasks@1"
             }
           ] = summary.slice_traceability
  end

  test "AgentBrief versioning supports locks and reruns" do
    [brief | _] = sample_plan().agent_briefs

    locked = PlanningGraph.lock_agent_brief!(brief)
    rerun = PlanningGraph.rerun_agent_brief!(locked, %{version: 2})

    assert locked["schema_version"] == "agent_brief@1"
    assert locked["locked"]
    assert locked["version"] == 1

    refute rerun["locked"]
    assert rerun["version"] == 2
    assert rerun["rerun_of"] == "brief-complete-task@1"
  end

  test "orphan findings identify missing slice traceability refs" do
    graph =
      sample_plan(%{
        slices: [
          %{
            id: "slice-orphan",
            epic_id: "epic-phase1",
            goal: "Demonstrate orphan detection",
            current_behavior: "A slice can be malformed in a draft plan.",
            desired_behavior: "The traceability checker reports every broken ref.",
            requirement_refs: ["REQ-missing"],
            decision_refs: ["DEC-missing"],
            improvement_refs: [],
            likely_files: ["sample_apps/fastapi_tasks/src/fastapi_tasks/app.py"],
            conflict_domains: ["sample-app"],
            autonomy_ceiling: "L1",
            agent_brief_id: "brief-missing",
            agent_brief_version: 1
          }
        ]
      })
      |> PlanningGraph.build!()

    assert [
             %{
               schema_version: "conveyor.planning_traceability_finding@1",
               category: "planning_traceability",
               finding_code: "orphan_requirement_ref",
               severity: "error",
               slice_id: "slice-orphan",
               field: "requirement_refs",
               ref: "REQ-missing"
             },
             %{
               finding_code: "orphan_decision_ref",
               field: "decision_refs",
               ref: "DEC-missing"
             },
             %{
               finding_code: "missing_improvement_ref",
               field: "improvement_refs",
               ref: nil
             },
             %{
               finding_code: "orphan_agent_brief_ref",
               field: "agent_brief_id",
               ref: "brief-missing@1"
             }
           ] = PlanningGraph.orphan_findings(graph)

    assert PlanningGraph.traceability_summary(graph).status == "error"
  end

  defp sample_plan(overrides \\ %{}) do
    %{
      plan_id: "plan-phase1-demo",
      title: "Phase 1 task sample plan",
      summary: "Connect human requirements to two executable sample app slices.",
      phase: "phase:1",
      requirements: [
        %{
          key: "REQ-001",
          title: "Complete task endpoint",
          acceptance_refs: ["AC-001"]
        },
        %{
          key: "REQ-002",
          title: "List task endpoint",
          acceptance_refs: ["AC-002"]
        }
      ],
      human_decisions: [
        %{
          id: "DEC-001",
          title: "Keep implementation in the sample app",
          decision_type: "scope",
          improvement_refs: ["IMP-001"]
        },
        %{
          id: "DEC-002",
          title: "Keep baseline list behavior visible",
          decision_type: "acceptance",
          improvement_refs: ["IMP-002"]
        }
      ],
      epics: [
        %{
          id: "epic-phase1",
          title: "FastAPI sample task workflow",
          requirement_refs: ["REQ-001", "REQ-002"]
        }
      ],
      slices: [
        %{
          id: "slice-complete-task",
          epic_id: "epic-phase1",
          goal: "Add task completion behavior",
          current_behavior: "Tasks can be created and listed.",
          desired_behavior: "Tasks can be marked complete.",
          requirement_refs: ["REQ-001"],
          decision_refs: ["DEC-001"],
          improvement_refs: ["IMP-001"],
          likely_files: ["sample_apps/fastapi_tasks/src/fastapi_tasks/app.py"],
          conflict_domains: ["sample-app", "api-contract"],
          autonomy_ceiling: "L1",
          agent_brief_id: "brief-complete-task",
          agent_brief_version: 1
        },
        %{
          id: "slice-list-tasks",
          epic_id: "epic-phase1",
          goal: "Preserve list task behavior",
          current_behavior: "The list endpoint returns all tasks.",
          desired_behavior: "The list endpoint remains stable after changes.",
          requirement_refs: ["REQ-002"],
          decision_refs: ["DEC-002"],
          improvement_refs: ["IMP-002"],
          likely_files: ["sample_apps/fastapi_tasks/tests/test_baseline.py"],
          conflict_domains: ["sample-app", "tests"],
          autonomy_ceiling: "L1",
          agent_brief_id: "brief-list-tasks",
          agent_brief_version: 1
        }
      ],
      agent_briefs: [
        %{
          id: "brief-complete-task",
          title: "Complete task endpoint brief",
          slice_id: "slice-complete-task",
          version: 1,
          locked: true
        },
        %{
          id: "brief-complete-task",
          title: "Complete task endpoint rerun brief",
          slice_id: "slice-complete-task",
          version: 2,
          rerun_of: "brief-complete-task@1"
        },
        %{
          id: "brief-list-tasks",
          title: "List task stability brief",
          slice_id: "slice-list-tasks",
          version: 1,
          locked: true
        }
      ]
    }
    |> Map.merge(overrides)
  end
end
