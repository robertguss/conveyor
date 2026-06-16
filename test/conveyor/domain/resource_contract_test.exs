defmodule Conveyor.Domain.ResourceContractTest do
  use ExUnit.Case, async: false

  test "registers every active Phase 0/1 resource in the Ash domain" do
    registered = Ash.Domain.Info.resources(Conveyor.Domain) |> MapSet.new()

    assert MapSet.new(resources()) == registered
  end

  test "tracks the backing table for every active resource" do
    assert length(resources()) == 46
    assert length(tables()) == 46
    assert length(Enum.uniq(tables())) == 46
  end

  test "emits structured migration and guard evidence logs" do
    assert %{
             schema_version: "conveyor.domain_resource_contract@1",
             category: "domain_resource_migration",
             resource_count: 46,
             table_count: 46,
             resources: resources,
             immutable_fields: immutable_fields
           } = Conveyor.Domain.Resources.migration_log()

    assert length(resources) == 46
    assert "external_id" in immutable_fields

    assert %{
             schema_version: "conveyor.domain_resource_contract@1",
             category: "domain_resource_guard",
             failure_category: "immutable_field_update_rejected",
             resource: "Conveyor.Domain.Project",
             field: "external_id"
           } =
             Conveyor.Domain.Resources.guard_violation_log(Conveyor.Domain.Project, :external_id)
  end

  test "mutable resources support Ash create, read, and update actions" do
    for resource <- mutable_resources() do
      suffix = resource |> Module.split() |> List.last() |> Macro.underscore()

      attrs = %{
        external_id: "#{suffix}-001",
        name: "#{suffix} baseline",
        status: "active",
        payload: %{"resource" => suffix}
      }

      assert {:ok, record} = Ash.create(resource, attrs, action: :create)
      assert record.external_id == attrs.external_id
      assert record.name == attrs.name
      assert record.status == "active"

      assert {:ok, [_ | _]} = Ash.read(resource, action: :read)

      assert {:ok, updated} =
               Ash.update(record, %{name: "#{suffix} updated", status: "paused"}, action: :update)

      assert updated.name == "#{suffix} updated"
      assert updated.status == "paused"
      assert updated.external_id == attrs.external_id
    end
  end

  test "immutable external ids are guarded by the update action" do
    for resource <- mutable_resources() do
      suffix = resource |> Module.split() |> List.last() |> Macro.underscore()

      assert {:ok, record} =
               Ash.create(
                 resource,
                 %{external_id: "#{suffix}-immutable", name: "#{suffix} immutable"},
                 action: :create
               )

      assert {:error, error} =
               Ash.update(record, %{external_id: "#{suffix}-changed"}, action: :update)

      assert Exception.message(error) =~ "external_id"
    end
  end

  test "append-only resources do not expose update or destroy actions" do
    for resource <- append_only_resources() do
      assert Ash.Resource.Info.action(resource, :create)
      assert Ash.Resource.Info.action(resource, :read)
      refute Ash.Resource.Info.action(resource, :update)
      refute Ash.Resource.Info.action(resource, :destroy)
    end
  end

  test "RunSpec generation is stable and binds station IO to the content address" do
    run_spec = Conveyor.Domain.RunSpec.build!(run_spec_attrs())

    reordered =
      Conveyor.Domain.RunSpec.build!(run_spec_attrs(%{contract_digests: reordered_digest_set()}))

    assert run_spec["run_spec_sha256"] == reordered["run_spec_sha256"]
    assert run_spec["run_spec_sha256"] =~ ~r/^sha256:[a-f0-9]{64}$/

    for station <- run_spec["stations"] do
      assert station["inputs"]["run_spec_sha256"] == run_spec["run_spec_sha256"]
      assert station["outputs"]["run_spec_sha256"] == run_spec["run_spec_sha256"]
    end

    assert %{
             schema_version: "conveyor.run_spec_digest_summary@1",
             category: "run_spec_digest_set",
             run_id: "run-phase1-demo",
             run_spec_sha256: run_spec_sha256,
             digest_count: 22,
             station_keys: ["readiness", "evidence"]
           } = Conveyor.Domain.RunSpec.digest_summary(run_spec)

    assert run_spec_sha256 == run_spec["run_spec_sha256"]
  end

  test "contract changes require a new RunSpec and RunAttempt instead of mutating evidence" do
    old_run_spec = Conveyor.Domain.RunSpec.build!(run_spec_attrs())

    new_attrs =
      run_spec_attrs(%{
        contract_digests: Map.put(digest_set(), "policy", "sha256:policy-v2")
      })

    new_run_spec = Conveyor.Domain.RunSpec.build!(new_attrs)

    refute Conveyor.Domain.RunSpec.equivalent?(old_run_spec, new_run_spec)

    assert %{
             schema_version: "conveyor.run_spec_diff@1",
             category: "run_spec_contract_change",
             finding_code: "contract_change_requires_new_run_spec_and_run_attempt",
             action: "create_new_run_spec_and_run_attempt",
             old_run_spec_sha256: old_sha256,
             new_run_spec_sha256: new_sha256,
             changed_digest_keys: ["policy"]
           } = Conveyor.Domain.RunSpec.diff_finding(old_run_spec, new_run_spec)

    assert old_sha256 == old_run_spec["run_spec_sha256"]
    assert new_sha256 == new_run_spec["run_spec_sha256"]
  end

  test "RunSpec payloads are created once and not updated in place" do
    attrs = Conveyor.Domain.RunSpec.create_attrs!(run_spec_attrs())

    assert {:ok, record} = Ash.create(Conveyor.Domain.RunSpec, attrs, action: :create)

    assert record.external_id == record.payload["run_spec_sha256"]

    assert {:error, error} =
             Ash.update(
               record,
               %{payload: Map.put(record.payload, "run_id", "mutated")},
               action: :update
             )

    assert Exception.message(error) =~ "payload"
  end

  test "artifact and bundle resources use content-addressed evidence identity" do
    artifact_attrs =
      Conveyor.Domain.Artifact.create_attrs!(%{
        artifact_key: "baseline-summary",
        content: ~s({"status":"passed"}),
        content_type: "application/json",
        sensitivity: "internal",
        blob_uri: "file://artifacts/baseline-summary.json",
        metadata: %{suite: "baseline_regression"}
      })

    assert %{external_id: "sha256:" <> _, payload: artifact_payload} = artifact_attrs
    assert artifact_attrs.external_id == artifact_payload["sha256"]
    assert artifact_payload["artifact_key"] == "baseline-summary"
    assert artifact_payload["sensitivity"] == "internal"
    assert artifact_payload["size_bytes"] == byte_size(~s({"status":"passed"}))

    assert %{
             schema_version: "conveyor.artifact_summary@1",
             category: "content_addressed_artifact",
             sha256: artifact_sha256,
             sensitivity: "internal"
           } = Conveyor.Domain.Artifact.summary(artifact_payload)

    assert artifact_sha256 == artifact_attrs.external_id

    assert {:ok, artifact_record} =
             Ash.create(Conveyor.Domain.Artifact, artifact_attrs, action: :create)

    run_bundle_attrs =
      Conveyor.Domain.RunBundle.create_attrs!(%{
        bundle_key: "run-phase1-demo-bundle",
        run_spec_sha256: "sha256:run-spec-demo",
        artifacts: [artifact_record.payload],
        metadata: %{station: "evidence"}
      })

    assert %{external_id: "sha256:" <> _, payload: bundle_payload} = run_bundle_attrs
    assert run_bundle_attrs.external_id == bundle_payload["run_bundle_sha256"]
    assert bundle_payload["artifact_sha256s"] == [artifact_sha256]

    assert %{
             schema_version: "conveyor.run_bundle_summary@1",
             category: "run_bundle_projection",
             artifact_count: 1,
             run_spec_sha256: "sha256:run-spec-demo"
           } = Conveyor.Domain.RunBundle.summary(bundle_payload)

    assert {:ok, _bundle_record} =
             Ash.create(Conveyor.Domain.RunBundle, run_bundle_attrs, action: :create)
  end

  test "retention and approval resources record manual external actions" do
    artifact_payload =
      Conveyor.Domain.Artifact.build!(%{
        artifact_key: "human-dossier",
        content: "approval evidence",
        sensitivity: "confidential",
        blob_uri: "file://artifacts/human-dossier.md"
      })

    retention_policy =
      Conveyor.Domain.RetentionPolicy.build!(%{
        policy_key: "phase1-human-dossier",
        retain_for_days: 30,
        sensitivity: "confidential",
        delete_requires_human_approval: true
      })

    assert Conveyor.Domain.RetentionPolicy.decision(retention_policy, artifact_payload) ==
             "requires_human_approval"

    external_change =
      Conveyor.Domain.ExternalChange.record!(%{
        change_id: "external-change-001",
        system: "github",
        change_type: "manual_label",
        actor: "reviewer@example.com",
        summary: "Reviewer applied an external triage label.",
        occurred_at: ~U[2026-06-16 21:00:00Z],
        metadata: %{label: "needs-human-review"}
      })

    approval_attrs =
      Conveyor.Domain.HumanApproval.create_attrs!(%{
        approval_id: "approval-001",
        actor: "reviewer@example.com",
        action: "approve_manual_external_change",
        target: "github:conveyor/pull/1",
        reason: "External label records a human review decision.",
        occurred_at: ~U[2026-06-16 21:01:00Z],
        external_change: external_change,
        evidence_refs: [artifact_payload["sha256"]]
      })

    assert %{
             "manual_external_action" => true,
             "external_change" => %{"change_id" => "external-change-001"},
             "evidence_refs" => [artifact_sha256]
           } = approval_attrs.payload

    assert artifact_sha256 == artifact_payload["sha256"]

    assert {:ok, _change_record} =
             Ash.create(
               Conveyor.Domain.ExternalChange,
               Conveyor.Domain.ExternalChange.create_attrs!(%{
                 change_id: "external-change-001-db",
                 system: "github",
                 change_type: "manual_label",
                 actor: "reviewer@example.com",
                 summary: "Reviewer applied an external triage label.",
                 occurred_at: ~U[2026-06-16 21:00:00Z]
               }),
               action: :create
             )

    assert {:ok, approval_record} =
             Ash.create(Conveyor.Domain.HumanApproval, approval_attrs, action: :create)

    assert approval_record.payload["manual_external_action"]
  end

  test "patch equivalence records every post-integration classification" do
    cases = [
      {"exact",
       %{expected_patch_sha256: "sha256:expected", applied_patch_sha256: "sha256:expected"}},
      {
        "equivalent_with_human_edits",
        %{
          expected_patch_sha256: "sha256:expected",
          applied_patch_sha256: "sha256:human-edited",
          human_edits: true,
          tests_passed: true,
          semantic_equivalence: true
        }
      },
      {"divergent",
       %{expected_patch_sha256: "sha256:expected", applied_patch_sha256: "sha256:other"}},
      {
        "partial",
        %{
          expected_patch_sha256: "sha256:expected",
          applied_patch_sha256: "sha256:partial",
          matched_hunks: 2,
          unmatched_hunks: 1
        }
      },
      {"unknown", %{}}
    ]

    assert Enum.map(cases, &elem(&1, 0)) == Conveyor.Domain.PatchEquivalence.classifications()

    for {expected, attrs} <- cases do
      attrs = Map.put(attrs, :equivalence_id, "patch-equivalence-#{expected}")

      assert Conveyor.Domain.PatchEquivalence.classify(attrs) == expected

      record = Conveyor.Domain.PatchEquivalence.record!(attrs)

      assert record["classification"] == expected
      assert record["finding_code"] == "patch_equivalence_#{expected}"
    end

    assert {:ok, record} =
             Ash.create(
               Conveyor.Domain.PatchEquivalence,
               Conveyor.Domain.PatchEquivalence.create_attrs!(%{
                 equivalence_id: "patch-equivalence-db",
                 expected_patch_sha256: "sha256:expected",
                 applied_patch_sha256: "sha256:expected"
               }),
               action: :create
             )

    assert record.payload["classification"] == "exact"
  end

  test "execution resources preserve run, station, session, tool, review, and gate links" do
    first_attempt =
      Conveyor.Domain.RunAttempt.build!(%{
        run_attempt_id: "exec-run-attempt-001",
        slice_id: "slice-demo",
        run_spec_sha256: "sha256:run-spec-demo",
        attempt_number: 1
      })

    retry_attempt =
      Conveyor.Domain.RunAttempt.build!(%{
        run_attempt_id: "exec-run-attempt-002",
        slice_id: "slice-demo",
        run_spec_sha256: "sha256:run-spec-demo-v2",
        attempt_number: 2,
        previous_run_attempt_id: "exec-run-attempt-001"
      })

    assert first_attempt["slice_id"] == retry_attempt["slice_id"]
    assert first_attempt["run_attempt_id"] != retry_attempt["run_attempt_id"]

    station_run =
      Conveyor.Domain.StationRun.build!(%{
        station_run_id: "exec-station-run-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_key: "implement",
        station_spec_sha256: "sha256:station-implement",
        attempt_number: 1,
        input_sha256: "sha256:station-input",
        output_sha256: "sha256:station-output"
      })

    agent_session =
      Conveyor.Domain.AgentSession.build!(%{
        agent_session_id: "exec-agent-session-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_run_id: station_run["station_run_id"],
        adapter: "codex",
        agent_profile_id: "agent-profile-implementer",
        started_at: ~U[2026-06-16 21:10:00Z],
        transcript_ref: "artifact://transcripts/exec-agent-session-001.jsonl"
      })

    assert agent_session["session_role"] == "adapter_output"
    refute agent_session["agent_session_id"] == first_attempt["run_attempt_id"]

    patch_set =
      Conveyor.Domain.PatchSet.build!(%{
        patch_set_id: "exec-patch-set-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_run_id: station_run["station_run_id"],
        diff_sha256: "sha256:diff-001",
        tool_invocation_ids: ["exec-tool-invocation-001"]
      })

    tool_invocation =
      Conveyor.Domain.ToolInvocation.build!(%{
        tool_invocation_id: "exec-tool-invocation-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_run_id: station_run["station_run_id"],
        agent_session_id: agent_session["agent_session_id"],
        command_ref: "cmd://mix-test-resource-contract",
        started_at: ~U[2026-06-16 21:11:00Z],
        exit_code: 0,
        artifact_refs: ["sha256:test-log"]
      })

    review =
      Conveyor.Domain.Review.build!(%{
        review_id: "exec-review-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_run_id: station_run["station_run_id"],
        reviewer_profile_id: "agent-profile-reviewer",
        decision: "approve",
        findings: [%{severity: "info", message: "Evidence covers linked station output."}],
        evidence_refs: ["exec-evidence-001"]
      })

    gate_result =
      Conveyor.Domain.GateResult.build!(%{
        gate_result_id: "exec-gate-result-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_run_id: station_run["station_run_id"],
        review_id: review["review_id"],
        decision: "pass",
        suite_kind: "focused",
        evidence_refs: ["exec-evidence-001"]
      })

    evidence =
      Conveyor.Domain.Evidence.build!(%{
        evidence_id: "exec-evidence-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_run_id: station_run["station_run_id"],
        artifact_sha256: "sha256:evidence-artifact",
        evidence_type: "test_log",
        requirement_ids: ["REQ-001"]
      })

    quality_run =
      Conveyor.Domain.CodeQualityRun.build!(%{
        code_quality_run_id: "exec-quality-run-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_run_id: station_run["station_run_id"],
        adapter: "noop",
        decision: "advisory_pass",
        artifact_refs: ["sha256:quality-report"]
      })

    workspace =
      Conveyor.Domain.WorkspaceMaterialization.build!(%{
        workspace_id: "exec-workspace-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        base_commit: "abc1234",
        path_digest: "sha256:workspace-path",
        materialized_at: ~U[2026-06-16 21:09:00Z]
      })

    risk_assessment =
      Conveyor.Domain.RiskAssessment.build!(%{
        risk_assessment_id: "exec-risk-001",
        run_attempt_id: first_attempt["run_attempt_id"],
        station_run_id: station_run["station_run_id"],
        risk_level: "medium",
        policy: "phase1-default",
        factors: ["touches_domain"]
      })

    records = [
      {
        Conveyor.Domain.RunAttempt,
        Map.put(Conveyor.Domain.RunAttempt.create_attrs!(first_attempt), :status, "archived")
      },
      {Conveyor.Domain.RunAttempt, Conveyor.Domain.RunAttempt.create_attrs!(retry_attempt)},
      {Conveyor.Domain.StationRun, Conveyor.Domain.StationRun.create_attrs!(station_run)},
      {Conveyor.Domain.AgentSession, Conveyor.Domain.AgentSession.create_attrs!(agent_session)},
      {Conveyor.Domain.PatchSet, Conveyor.Domain.PatchSet.create_attrs!(patch_set)},
      {Conveyor.Domain.ToolInvocation,
       Conveyor.Domain.ToolInvocation.create_attrs!(tool_invocation)},
      {Conveyor.Domain.Review, Conveyor.Domain.Review.create_attrs!(review)},
      {Conveyor.Domain.GateResult, Conveyor.Domain.GateResult.create_attrs!(gate_result)},
      {Conveyor.Domain.Evidence, Conveyor.Domain.Evidence.create_attrs!(evidence)},
      {Conveyor.Domain.CodeQualityRun, Conveyor.Domain.CodeQualityRun.create_attrs!(quality_run)},
      {
        Conveyor.Domain.WorkspaceMaterialization,
        Conveyor.Domain.WorkspaceMaterialization.create_attrs!(workspace)
      },
      {Conveyor.Domain.RiskAssessment,
       Conveyor.Domain.RiskAssessment.create_attrs!(risk_assessment)}
    ]

    for {resource, attrs} <- records do
      assert {:ok, record} = Ash.create(resource, attrs, action: :create)
      assert record.payload["run_attempt_id"] || record.payload["workspace_id"]
    end

    assert %{
             schema_version: "conveyor.execution_association_summary@1",
             category: "execution_resource_association",
             slice_attempts: [
               %{
                 slice_id: "slice-demo",
                 attempt_count: 2,
                 run_attempt_ids: ["exec-run-attempt-001", "exec-run-attempt-002"]
               }
             ],
             agent_sessions: [
               %{
                 "agent_session_id" => "exec-agent-session-001",
                 "run_attempt_id" => "exec-run-attempt-001",
                 "station_run_id" => "exec-station-run-001",
                 "adapter" => "codex",
                 "session_role" => "adapter_output"
               }
             ],
             patch_sets: [%{"patch_set_id" => "exec-patch-set-001"}],
             tool_invocations: [%{"tool_invocation_id" => "exec-tool-invocation-001"}],
             review_ids: ["exec-review-001"],
             gate_result_ids: ["exec-gate-result-001"],
             evidence_ids: ["exec-evidence-001"],
             code_quality_run_ids: ["exec-quality-run-001"],
             workspace_materialization_ids: ["exec-workspace-001"],
             risk_assessment_ids: ["exec-risk-001"],
             independently_queryable: ["reviews", "gate_results"]
           } =
             Conveyor.Domain.ExecutionResources.association_summary(%{
               run_attempts: [first_attempt, retry_attempt],
               station_runs: [station_run],
               agent_sessions: [agent_session],
               patch_sets: [patch_set],
               tool_invocations: [tool_invocation],
               reviews: [review],
               gate_results: [gate_result],
               evidence: [evidence],
               code_quality_runs: [quality_run],
               workspace_materializations: [workspace],
               risk_assessments: [risk_assessment]
             })

    assert {:ok, reviews} = Ash.read(Conveyor.Domain.Review, action: :read)
    assert Enum.any?(reviews, &(&1.payload["review_id"] == "exec-review-001"))

    assert {:ok, gate_results} = Ash.read(Conveyor.Domain.GateResult, action: :read)
    assert Enum.any?(gate_results, &(&1.payload["gate_result_id"] == "exec-gate-result-001"))
  end

  test "station idempotency resumes completed runs and reconciles unknown effects" do
    station_attrs = %{
      station_run_id: "idem-station-run-001",
      run_attempt_id: "idem-run-attempt-001",
      station_key: "evidence",
      station_spec_sha256: "sha256:station-spec-v1",
      attempt_number: 1,
      input_sha256: "sha256:station-input-v1",
      output_sha256: "sha256:station-output-v1",
      station_status: "completed"
    }

    completed_station = Conveyor.Domain.StationRun.build!(station_attrs)

    declared_effect =
      Conveyor.Domain.StationEffect.build!(%{
        effect_id: "idem-effect-001",
        run_attempt_id: completed_station["run_attempt_id"],
        station_run_id: completed_station["station_run_id"],
        effect_type: "artifact_write",
        external_ref: "artifact://idem/evidence.json",
        output_sha256: completed_station["output_sha256"],
        declared_at: ~U[2026-06-16 21:20:00Z]
      })

    assert declared_effect["effect_status"] == "declared"
    assert declared_effect["idempotency_key"] =~ ~r/^sha256:[a-f0-9]{64}$/

    assert {:ok, _effect_record} =
             Ash.create(
               Conveyor.Domain.StationEffect,
               Conveyor.Domain.StationEffect.create_attrs!(declared_effect),
               action: :create
             )

    assert {:ok, _station_record} =
             Ash.create(
               Conveyor.Domain.StationRun,
               Conveyor.Domain.StationRun.create_attrs!(completed_station),
               action: :create
             )

    duplicate_station =
      Conveyor.Domain.StationRun.build!(%{
        station_attrs
        | station_run_id: "idem-station-run-duplicate"
      })

    assert duplicate_station["idempotency_key"] == completed_station["idempotency_key"]

    assert {:error, duplicate_error} =
             Ash.create(
               Conveyor.Domain.StationRun,
               Conveyor.Domain.StationRun.create_attrs!(duplicate_station),
               action: :create
             )

    assert Exception.message(duplicate_error) =~ "station_runs_idempotency_key_unique"

    assert %{
             schema_version: "conveyor.station_run_retry_decision@1",
             category: "station_retry_decision",
             action: "resume_completed_station",
             reason: "station_already_completed",
             retry_safe: true,
             duplicate_artifacts: false,
             existing_idempotency_key: idempotency_key,
             requested_idempotency_key: requested_idempotency_key
           } = Conveyor.Domain.StationRun.retry_decision(completed_station, station_attrs)

    assert requested_idempotency_key == idempotency_key

    changed_input_attrs = %{
      station_attrs
      | station_run_id: "idem-station-run-002",
        station_spec_sha256: "sha256:station-spec-v2",
        attempt_number: 2,
        input_sha256: "sha256:station-input-v2"
    }

    assert %{
             action: "create_new_station_attempt",
             reason: "station_inputs_changed",
             retry_safe: false
           } = Conveyor.Domain.StationRun.retry_decision(completed_station, changed_input_attrs)

    unknown_effect =
      Conveyor.Domain.StationEffect.build!(%{
        effect_id: "idem-effect-unknown",
        run_attempt_id: completed_station["run_attempt_id"],
        station_run_id: completed_station["station_run_id"],
        effect_type: "external_process",
        external_ref: "process://unknown",
        declared_at: ~U[2026-06-16 21:21:00Z],
        effect_status: "unknown"
      })

    assert %{
             action: "reconcile_unknown_effects_before_retry",
             reason: "unknown_effects_present",
             retry_safe: false,
             unknown_effect_ids: ["idem-effect-unknown"]
           } =
             Conveyor.Domain.StationRun.retry_decision(completed_station, station_attrs, [
               unknown_effect
             ])

    assert %{
             schema_version: "conveyor.station_run_idempotency_summary@1",
             category: "station_idempotency",
             station_run_id: "idem-station-run-001",
             idempotency_key: ^idempotency_key,
             output_sha256: "sha256:station-output-v1",
             unknown_effect_ids: ["idem-effect-unknown"],
             effect_states: effect_states
           } =
             Conveyor.Domain.StationRun.idempotency_summary(completed_station, [
               declared_effect,
               unknown_effect
             ])

    assert Enum.any?(effect_states, &(&1.effect_id == "idem-effect-001"))
    assert Enum.any?(effect_states, &(&1.effect_status == "unknown"))
  end

  defp resources, do: Conveyor.Domain.Resources.resource_modules()
  defp tables, do: Conveyor.Domain.Resources.table_names()
  defp append_only_resources, do: Conveyor.Domain.Resources.append_only_resources()
  defp mutable_resources, do: resources() -- append_only_resources()

  defp run_spec_attrs(overrides \\ %{}) do
    %{
      run_id: "run-phase1-demo",
      project_id: "project-conveyor",
      base_commit: "abc1234",
      slice_id: "slice-demo",
      autonomy_level: "L1",
      contract_digests: digest_set(),
      stations: [
        %{
          station_key: "readiness",
          intent: "Verify the run can start from locked inputs.",
          inputs: %{project_config: "locked"},
          outputs: %{report: "readiness.json"}
        },
        %{
          station_key: "evidence",
          intent: "Collect evidence without mutating the locked contract.",
          inputs: %{artifact_plan: "required"},
          outputs: %{bundle_manifest: "run_bundle.json"}
        }
      ]
    }
    |> Map.merge(overrides)
  end

  defp digest_set do
    Map.new(Conveyor.Domain.RunSpec.digest_keys(), fn key -> {key, "sha256:#{key}-v1"} end)
  end

  defp reordered_digest_set do
    digest_set()
    |> Enum.reverse()
    |> Map.new()
  end
end
