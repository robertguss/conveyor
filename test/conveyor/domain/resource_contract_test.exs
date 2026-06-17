defmodule Conveyor.Domain.ResourceContractTest do
  use ExUnit.Case, async: false

  alias Conveyor.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

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

  test "Plan state machine enforces readiness guards and appends one ledger event" do
    assert {:ok, plan} =
             Ash.create(
               Conveyor.Domain.Plan,
               Conveyor.Domain.Plan.create_attrs!(%{plan_id: "state-plan-001"}),
               action: :create
             )

    assert {:error, finding} =
             Conveyor.Domain.Plan.transition(plan, :prepare_handoff, %{
               trace_id: "trace-state-plan-001",
               span_id: "span-state-plan-001"
             })

    assert %{
             category: "rejected_transition_guard",
             failure_category: "illegal_transition",
             transition: "prepare_handoff",
             from_state: "draft",
             explanation: explanation
           } = finding

    assert explanation =~ "cannot move"
    assert [] = Conveyor.Ledger.replay_timeline("state-plan-001")

    assert {:ok, audited, audit_event, [_outbox], audit_log} =
             Conveyor.Domain.Plan.transition(
               plan,
               :audit,
               %{artifact_refs: ["sha256:plan-audit"]},
               trace_id: "trace-state-plan-001",
               span_id: "span-state-plan-audit",
               stream_id: "state-plan-001"
             )

    assert audited.payload["plan_state"] == "audited"
    assert audit_log.category == "domain_state_transition"
    assert audit_event.event_type == "domain_state_transition.plan.audit"

    assert {:ok, handoff_ready, _event, [_outbox], _log} =
             Conveyor.Domain.Plan.transition(
               audited,
               :prepare_handoff,
               %{plan_ready: true, contract_lock_id: "lock-plan-001"},
               trace_id: "trace-state-plan-001",
               span_id: "span-state-plan-handoff",
               stream_id: "state-plan-001"
             )

    assert handoff_ready.payload["plan_state"] == "handoff_ready"

    timeline = Conveyor.Ledger.replay_timeline("state-plan-001")

    assert Enum.map(timeline, & &1.event_type) == [
             "domain_state_transition.plan.audit",
             "domain_state_transition.plan.prepare_handoff"
           ]
  end

  test "Slice state machine keeps product lifecycle separate from run failures" do
    assert {:ok, slice} =
             Ash.create(
               Conveyor.Domain.Slice,
               Conveyor.Domain.Slice.create_attrs!(%{
                 slice_id: "state-slice-001",
                 plan_id: "state-plan-001"
               }),
               action: :create
             )

    assert {:error, finding} =
             Conveyor.Domain.Slice.transition(slice, :approve, %{
               actor: "reviewer@example.com",
               previous_actor: "reviewer@example.com"
             })

    assert %{
             category: "rejected_transition_guard",
             failure_category: "guard_failed",
             guard: "actor_separated",
             explanation: "The same actor cannot perform both sides of this transition."
           } = finding

    assert {:ok, approved, event, [_outbox], log} =
             Conveyor.Domain.Slice.transition(
               slice,
               :approve,
               %{actor: "reviewer@example.com", previous_actor: "author@example.com"},
               trace_id: "trace-state-slice-001",
               span_id: "span-state-slice-approve",
               stream_id: "state-slice-001"
             )

    assert approved.payload["slice_state"] == "approved"
    assert event.event_type == "domain_state_transition.slice.approve"

    assert [%{guard: "actor_separated", status: "passed", explanation: explanation}] =
             log.guard_results

    assert is_binary(explanation)

    assert {:ok, blocked, block_event, [_outbox], _log} =
             Conveyor.Domain.Slice.transition(
               approved,
               :block,
               %{reason: "external dependency missing"},
               trace_id: "trace-state-slice-001",
               span_id: "span-state-slice-block",
               stream_id: "state-slice-001"
             )

    assert blocked.payload["slice_state"] == "blocked"
    assert block_event.event_type == "domain_state_transition.slice.block"

    timeline = Conveyor.Ledger.replay_timeline("state-slice-001")
    assert length(timeline) == 2
  end

  test "complete AgentBrief emits a digest and can transition an approved Slice to ready" do
    assert {:ok, slice} =
             Ash.create(
               Conveyor.Domain.Slice,
               Conveyor.Domain.Slice.create_attrs!(%{
                 slice_id: "agent-brief-slice-001",
                 plan_id: "agent-brief-plan-001"
               }),
               action: :create
             )

    assert {:ok, approved, _event, [_outbox], _log} =
             Conveyor.Domain.Slice.transition(
               slice,
               :approve,
               %{actor: "reviewer@example.com", previous_actor: "author@example.com"},
               trace_id: "trace-agent-brief-slice-001",
               span_id: "span-agent-brief-approve",
               stream_id: "agent-brief-slice-001"
             )

    assert {:ok, brief} =
             Ash.create(
               Conveyor.Domain.AgentBrief,
               Conveyor.Domain.AgentBrief.create_attrs!(agent_brief_attrs()),
               action: :create
             )

    assert %{
             schema_version: "conveyor.agent_brief_readiness@1",
             category: "agent_brief_readiness",
             status: "ready",
             ready: true,
             brief_key: "brief-complete-task",
             version: 1,
             slice_id: "agent-brief-slice-001",
             findings: [],
             next_actions: [],
             contract_digest: contract_digest
           } = Conveyor.Domain.AgentBrief.readiness_report(brief)

    assert contract_digest =~ ~r/^sha256:[a-f0-9]{64}$/
    assert brief.external_id == "brief-complete-task@1"
    assert brief.payload["contract_digest"] == contract_digest

    context = Conveyor.Domain.AgentBrief.readiness_context!(brief)

    assert %{
             plan_ready: true,
             readiness: "ready",
             contract_locked: true,
             contract_lock_id: "lock-agent-brief-001",
             artifact_refs: [^contract_digest],
             agent_brief_digest: ^contract_digest
           } = context

    assert {:ok, ready, event, [_outbox], log} =
             Conveyor.Domain.Slice.transition(
               approved,
               :ready,
               context,
               trace_id: "trace-agent-brief-slice-001",
               span_id: "span-agent-brief-ready",
               stream_id: "agent-brief-slice-001"
             )

    assert ready.payload["slice_state"] == "ready"
    assert event.event_type == "domain_state_transition.slice.ready"

    assert Enum.map(log.guard_results, & &1.guard) == [
             "plan_ready",
             "contract_locked",
             "artifacts_present"
           ]
  end

  test "AgentBrief readiness blocks vague, testless, and too-large contracts with stable findings" do
    cases = [
      {
        "vague",
        agent_brief_attrs(%{
          brief_key: "brief-vague",
          current_behavior: "Does stuff.",
          desired_behavior: "Make it better."
        }),
        "vague_agent_brief",
        "vague"
      },
      {
        "testless",
        agent_brief_attrs(%{
          brief_key: "brief-testless",
          required_tests: [],
          verification_commands: []
        }),
        "testless_agent_brief",
        "testless"
      },
      {
        "too-large",
        agent_brief_attrs(%{
          brief_key: "brief-too-large",
          current_behavior:
            String.duplicate("Existing bounded behavior remains reviewable. ", 400)
        }),
        "brief_too_large",
        "too_large"
      }
    ]

    for {_name, attrs, expected_code, expected_category} <- cases do
      report =
        attrs
        |> Conveyor.Domain.AgentBrief.build!()
        |> Conveyor.Domain.AgentBrief.readiness_report()

      refute report.ready
      assert report.status == "blocked"
      assert report.contract_digest =~ ~r/^sha256:[a-f0-9]{64}$/

      assert %{
               schema_version: "conveyor.agent_brief_readiness_finding@1",
               category: "agent_brief_readiness",
               finding_code: ^expected_code,
               readiness_category: ^expected_category,
               severity: "blocking",
               next_actions: [%{schema_version: "conveyor.agent_brief_next_action@1"}]
             } = Enum.find(report.findings, &(&1.finding_code == expected_code))

      assert Enum.any?(report.next_actions, fn action ->
               action.command == ["mix", "conveyor.plan_audit", "--agent-brief"]
             end)

      assert_raise ArgumentError, ~r/AgentBrief is not ready: /, fn ->
        Conveyor.Domain.AgentBrief.readiness_context!(report)
      end
    end
  end

  test "ContractLock records stable digests and invalidates changed future inputs" do
    attrs = contract_lock_attrs()
    lock = Conveyor.Domain.ContractLock.build!(attrs)

    reordered =
      Conveyor.Domain.ContractLock.build!(
        contract_lock_attrs(%{
          acceptance_criteria: Enum.reverse(attrs.acceptance_criteria),
          required_tests: Enum.reverse(attrs.required_tests),
          verification_commands: Enum.reverse(attrs.verification_commands),
          protected_paths: Enum.reverse(attrs.protected_paths)
        })
      )

    assert lock["schema_version"] == "contract_lock@1"
    assert lock["lock_digest"] == reordered["lock_digest"]
    assert lock["lock_digest"] =~ ~r/^sha256:[a-f0-9]{64}$/

    assert Enum.sort(Map.keys(lock["input_digests"])) ==
             Enum.sort(Conveyor.Domain.ContractLock.contract_input_keys())

    assert {:ok, record} =
             Ash.create(
               Conveyor.Domain.ContractLock,
               Conveyor.Domain.ContractLock.create_attrs!(attrs),
               action: :create
             )

    assert record.external_id == lock["lock_digest"]
    assert record.payload["lock_digest"] == lock["lock_digest"]
    assert record.payload["base_commit"] == "abc1234"

    assert %{
             schema_version: "conveyor.contract_lock_summary@1",
             category: "contract_lock_digest",
             matrix_ref: "conveyor-quality-ci-evals-vmr.13",
             lock_key: "contract-lock-complete-task",
             lock_digest: lock_digest,
             base_commit: "abc1234",
             acceptance_criteria_count: 2,
             required_test_count: 1,
             verification_command_count: 1,
             protected_path_count: 2
           } = Conveyor.Domain.ContractLock.summary(record)

    assert lock_digest == lock["lock_digest"]

    assert {:ok, %{lock_digest: ^lock_digest}} =
             Conveyor.Domain.ContractLock.validate_current(record, attrs)

    changed_attrs =
      contract_lock_attrs(%{
        policy: Map.put(attrs.policy, :policy_sha256, "sha256:policy-v2")
      })

    assert {:error,
            %{
              schema_version: "conveyor.contract_lock_finding@1",
              category: "contract_lock_invalidation",
              finding_code: "contract_lock_inputs_changed",
              severity: "blocking",
              matrix_ref: "conveyor-quality-ci-evals-vmr.13",
              old_lock_digest: ^lock_digest,
              new_lock_digest: new_lock_digest,
              changed_inputs: ["policy"],
              action: "create_new_contract_lock_and_run_attempt"
            }} = Conveyor.Domain.ContractLock.validate_current(record, changed_attrs)

    refute new_lock_digest == lock_digest

    assert %{
             lock_digest: ^lock_digest,
             input_digests: old_input_digests
           } = Conveyor.Domain.ContractLock.summary(record)

    assert old_input_digests == lock["input_digests"]
  end

  test "RunAttempt state machine guards autonomy, artifacts, review, gate, and reports" do
    assert {:ok, attempt} =
             Ash.create(
               Conveyor.Domain.RunAttempt,
               Conveyor.Domain.RunAttempt.create_attrs!(%{
                 run_attempt_id: "state-attempt-001",
                 slice_id: "state-slice-001",
                 run_spec_sha256: "sha256:run-spec-state-001",
                 attempt_number: 1
               }),
               action: :create
             )

    assert {:error, finding} =
             Conveyor.Domain.RunAttempt.transition(attempt, :start, %{
               plan_ready: true,
               contract_lock_id: "lock-state-attempt-001",
               autonomy_allowed: false
             })

    assert %{
             category: "rejected_transition_guard",
             failure_category: "guard_failed",
             guard: "autonomy_allowed",
             explanation: "Autonomy policy must allow this transition."
           } = finding

    assert {:ok, running, start_event, [_outbox], _log} =
             Conveyor.Domain.RunAttempt.transition(
               attempt,
               :start,
               %{
                 plan_ready: true,
                 contract_lock_id: "lock-state-attempt-001",
                 autonomy_allowed: true
               },
               trace_id: "trace-state-attempt-001",
               span_id: "span-state-attempt-start",
               stream_id: "state-attempt-001"
             )

    assert running.payload["attempt_state"] == "running"
    assert running.payload["attempt_status"] == "running"
    assert start_event.event_type == "domain_state_transition.run_attempt.start"

    transitions = [
      {:record_evidence, %{artifact_refs: ["sha256:evidence"]}, "evidence_recorded"},
      {
        :review,
        %{
          actor: "reviewer@example.com",
          previous_actor: "author@example.com",
          review_decision: "approve"
        },
        "reviewed"
      },
      {:gate, %{gate_decision: "pass"}, "gated"},
      {:report, %{artifact_refs: ["sha256:report"]}, "reported"}
    ]

    final_attempt =
      Enum.reduce(transitions, running, fn {transition, context, expected_state}, record ->
        assert {:ok, updated, _event, [_outbox], _log} =
                 Conveyor.Domain.RunAttempt.transition(
                   record,
                   transition,
                   context,
                   trace_id: "trace-state-attempt-001",
                   span_id: "span-state-attempt-#{transition}",
                   stream_id: "state-attempt-001"
                 )

        assert updated.payload["attempt_state"] == expected_state
        updated
      end)

    assert final_attempt.payload["attempt_status"] == "reported"

    timeline = Conveyor.Ledger.replay_timeline("state-attempt-001")
    assert length(timeline) == 5
    assert List.last(timeline).event_type == "domain_state_transition.run_attempt.report"
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
    assert run_bundle_attrs.external_id == bundle_payload["bundle_root_sha256"]
    assert bundle_payload["artifact_sha256s"] == [artifact_sha256]
    refute Map.has_key?(bundle_payload, "run_bundle_sha256")

    assert %{
             "schema_version" => "conveyor.run_bundle_manifest@1",
             "matrix_ref" => "conveyor-quality-ci-evals-vmr.13",
             "artifact_count" => 1,
             "excluded_fields" => excluded_fields,
             "artifacts" => [
               %{
                 "artifact_role" => "evidence",
                 "artifact_key" => "baseline-summary",
                 "sha256" => ^artifact_sha256
               }
             ]
           } = bundle_payload["canonical_manifest"]

    assert "created_at" in excluded_fields["timestamp_fields"]
    assert "blob_path" in excluded_fields["host_path_fields"]

    bundle_root_sha256 = run_bundle_attrs.external_id

    assert %{
             schema_version: "conveyor.run_bundle_summary@1",
             category: "run_bundle_projection",
             artifact_count: 1,
             bundle_root_sha256: ^bundle_root_sha256,
             run_spec_sha256: "sha256:run-spec-demo"
           } = Conveyor.Domain.RunBundle.summary(bundle_payload)

    dossier_sha256 = Conveyor.Domain.PayloadHelpers.sha256_binary("human review dossier")

    evidence_artifact =
      Map.merge(artifact_record.payload, %{
        "artifact_role" => "evidence",
        "path" => "evidence/baseline-summary.json",
        "created_at" => "2026-06-16T21:40:00Z",
        "blob_path" => "/tmp/first-host/blobs/evidence.json"
      })

    dossier_artifact = %{
      "schema_version" => "dossier@1",
      "artifact_role" => "dossier",
      "artifact_key" => "human-dossier",
      "path" => "dossiers/human-dossier.md",
      "sha256" => dossier_sha256,
      "generated_at" => "2026-06-16T21:40:00Z",
      "host_path" => "/tmp/first-host/dossiers/human-dossier.md"
    }

    first_bundle =
      Conveyor.Domain.RunBundle.build!(%{
        bundle_key: "run-phase1-demo-bundle",
        run_spec_sha256: "sha256:run-spec-demo",
        artifacts: [dossier_artifact, evidence_artifact],
        metadata: %{generated_at: "2026-06-16T21:40:00Z", host_path: "/tmp/first-host"}
      })

    second_bundle =
      Conveyor.Domain.RunBundle.build!(%{
        bundle_key: "run-phase1-demo-bundle",
        run_spec_sha256: "sha256:run-spec-demo",
        artifacts: [
          Map.put(evidence_artifact, "blob_path", "/tmp/second-host/blobs/evidence.json"),
          Map.put(dossier_artifact, "generated_at", "2026-06-17T21:40:00Z")
        ],
        metadata: %{generated_at: "2026-06-17T21:40:00Z", host_path: "/tmp/second-host"}
      })

    assert first_bundle["bundle_root_sha256"] == second_bundle["bundle_root_sha256"]
    assert first_bundle["canonical_manifest"] == second_bundle["canonical_manifest"]

    canonical_artifacts_json = Jason.encode!(first_bundle["canonical_manifest"]["artifacts"])
    refute canonical_artifacts_json =~ "/tmp/first-host"
    refute canonical_artifacts_json =~ "/tmp/second-host"
    refute canonical_artifacts_json =~ "created_at"

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

  test "RunBudget records counters and policy-controlled exhaustion stops" do
    run_budget =
      Conveyor.Domain.RunBudget.build!(%{
        run_budget_id: "budget-run-001",
        run_attempt_id: "budget-attempt-001",
        policy_profile: "implement",
        limits: %{
          wall_clock_ms: 10_000,
          idle_ms: 2_000,
          tool_calls: 4,
          command_count: 6,
          output_bytes: 4096,
          repeated_command_failures: 2,
          same_file_rewrites: 2,
          no_diff_progress_ms: 3_000,
          tokens: 20_000,
          cost_micros: 50_000
        },
        consumed_counters: %{tool_calls: 1, command_count: 1}
      })

    assert run_budget["schema_version"] == "conveyor.run_budget@1"
    assert run_budget["budget_status"] == "active"
    assert run_budget["limits"]["output_bytes"] == 4096
    assert run_budget["consumed_counters"]["tool_calls"] == 1

    assert {:ok, record} =
             Ash.create(
               Conveyor.Domain.RunBudget,
               Conveyor.Domain.RunBudget.create_attrs!(run_budget),
               action: :create
             )

    assert record.external_id == "budget-run-001"

    assert %{
             schema_version: "conveyor.run_budget_evaluation@1",
             category: "run_budget_evaluation",
             budget_status: "within_budget",
             policy_controlled_stop: false,
             ordinary_agent_failure: false,
             findings: []
           } = Conveyor.Domain.RunBudget.evaluate(run_budget, %{output_bytes: 1024})

    assert %{
             budget_status: "policy_controlled_stop",
             policy_controlled_stop: true,
             ordinary_agent_failure: false,
             consumed_counters: consumed_counters,
             limit_counters: limit_counters,
             stop_reasons: stop_reasons,
             findings: findings
           } =
             Conveyor.Domain.RunBudget.evaluate(run_budget, %{
               wall_clock_ms: 10_001,
               tokens: 20_001
             })

    assert consumed_counters["wall_clock_ms"] == 10_001
    assert limit_counters["tokens"] == 20_000
    assert stop_reasons == ["wall_clock_exhausted", "token_budget_exhausted"]

    assert Enum.all?(findings, &(&1.policy_controlled_stop and not &1.ordinary_agent_failure))
    assert Enum.map(findings, & &1.action) == ["stop_run_attempt", "stop_run_attempt"]
  end

  test "RunBudget treats non-progress fixtures as policy stops, not agent failures" do
    run_budget =
      Conveyor.Domain.RunBudget.build!(%{
        run_budget_id: "budget-non-progress-001",
        run_attempt_id: "budget-attempt-002",
        limits: %{
          idle_ms: 2_000,
          output_bytes: 4096,
          repeated_command_failures: 2,
          same_file_rewrites: 2,
          no_diff_progress_ms: 3_000
        }
      })

    scenarios = [
      {%{repeated_command_failures: 3}, "repeated_command_failures",
       "repeated_identical_failures"},
      {%{output_bytes: 4097}, "output_bytes", "output_flooding"},
      {%{idle_ms: 2_001}, "idle_ms", "heartbeat_without_progress"},
      {%{no_diff_progress_ms: 3_001}, "no_diff_progress_ms", "no_patch_progress"},
      {%{same_file_rewrites: 3}, "same_file_rewrites", "same_file_rewrite_loop"}
    ]

    for {consumed, counter, stop_reason} <- scenarios do
      assert %{
               budget_status: "policy_controlled_stop",
               policy_controlled_stop: true,
               ordinary_agent_failure: false,
               stop_reasons: [^stop_reason],
               findings: [
                 %{
                   schema_version: "conveyor.run_budget_finding@1",
                   category: "run_budget_stop",
                   failure_category: "budget_exhausted",
                   counter: ^counter,
                   stop_reason: ^stop_reason,
                   policy_controlled_stop: true,
                   ordinary_agent_failure: false,
                   action: "stop_run_attempt"
                 }
               ]
             } = Conveyor.Domain.RunBudget.evaluate(run_budget, consumed)
    end
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

  defp contract_lock_attrs(overrides \\ %{}) do
    %{
      lock_key: "contract-lock-complete-task",
      base_commit: "abc1234",
      plan_contract: %{
        plan_id: "plan-complete-task",
        schema_version: "conveyor.plan@1",
        plan_digest: "sha256:plan-v1",
        slice_ids: ["agent-brief-slice-001"]
      },
      agent_brief: Conveyor.Domain.AgentBrief.build!(agent_brief_attrs()),
      acceptance_criteria: [
        %{criterion_id: "AC-001", text: "PATCH /tasks/:id/complete marks a task complete."},
        %{criterion_id: "AC-002", text: "GET /tasks shows the completed state."}
      ],
      required_tests: ["pytest sample_apps/fastapi_tasks/tests/test_complete_task.py"],
      test_pack: %{
        test_pack_key: "fastapi-tasks-contract",
        version: 1,
        test_pack_digest: "sha256:test-pack-v1",
        scenarios: ["known-good-complete-task", "missing-state-update-mutant"]
      },
      verification_commands: [
        %{
          command_id: "VERIFY-001",
          acceptance_refs: ["AC-001", "AC-002"],
          command: ["python3", "-m", "pytest", "sample_apps/fastapi_tasks/tests"]
        }
      ],
      agents_md: %{
        path: "AGENTS.md",
        sha256: "sha256:agents-v1",
        required_rules: ["no file deletion", "run quality gates"]
      },
      policy: %{
        policy_id: "default-l1",
        policy_sha256: "sha256:policy-v1",
        autonomy_ceiling: "L1"
      },
      protected_paths: [".conveyor/**", "priv/repo/**"],
      created_by: "conductor",
      created_at: ~U[2026-06-17 02:20:00Z]
    }
    |> Map.merge(overrides)
  end

  defp agent_brief_attrs(overrides \\ %{}) do
    %{
      brief_key: "brief-complete-task",
      version: 1,
      slice_id: "agent-brief-slice-001",
      title: "Complete task endpoint AgentBrief",
      current_behavior:
        "Tasks can already be created and listed through the sample application API.",
      desired_behavior:
        "Tasks can be marked complete and list responses show the completed state.",
      key_interfaces: ["HTTP PATCH /tasks/:id/complete", "GET /tasks response schema"],
      acceptance_criteria_refs: ["AC-001", "AC-002"],
      required_tests: ["pytest sample_apps/fastapi_tasks/tests/test_complete_task.py"],
      verification_commands: [
        %{
          command_id: "VERIFY-001",
          command: ["python3", "-m", "pytest", "sample_apps/fastapi_tasks/tests"]
        }
      ],
      out_of_scope: ["Authentication changes", "Production deployment"],
      risks: ["Regression risk around existing task listing behavior"],
      non_goals: ["Do not redesign task persistence"],
      allowed_write_paths: ["sample_apps/fastapi_tasks/**"],
      protected_paths: [".conveyor/**", "priv/repo/**"],
      autonomy_level: "L1",
      lock_metadata: %{
        contract_lock_id: "lock-agent-brief-001",
        locked_by: "owner@example.com",
        locked_at: "2026-06-17T00:00:00Z",
        reason: "Ready for bounded tracer execution"
      }
    }
    |> Map.merge(overrides)
  end
end
