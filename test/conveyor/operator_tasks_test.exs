defmodule Conveyor.OperatorTasksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Conveyor.Artifacts.Projector.LocalDisk
  alias Conveyor.EvidenceRecorder
  alias Conveyor.OperatorTasks

  @expected_commands ~w(
    init
    doctor
    plan_audit
    seed_sample
    demo
    show
    run_slice
    verify
    gate_canary
    report
    replay
    contract_diff
    ci
  )

  @new_shell_commands @expected_commands -- ["doctor", "plan_audit"]

  test "registry covers every Phase 0/1 operator command shell" do
    assert OperatorTasks.command_ids() == @expected_commands

    for spec <- OperatorTasks.command_specs() do
      assert spec.task == "conveyor.#{spec.id}"
      assert spec.shortdoc != ""
      assert spec.description != ""
      assert spec.matrix_ref == "conveyor-quality-ci-evals-vmr.13"
      assert spec.json_capable == true
      assert spec.live_provider_required == false
      assert spec.provider_requirements == []
      assert is_integer(spec.exit_code)
      assert is_binary(spec.service_module)
    end
  end

  test "every command emits a structured provider-free smoke result" do
    for command <- @expected_commands do
      result = OperatorTasks.smoke_result(command)

      assert result.schema_version == "conveyor.operator_task.smoke@1"
      assert result.matrix_ref == "conveyor-quality-ci-evals-vmr.13"
      assert result.command == command
      assert result.task == "conveyor.#{command}"
      assert result.exit_code == 0
      assert result.json_capable == true
      assert result.live_provider_required == false
      assert result.provider_requirements == []
      assert result.provider_mode == "none"
      assert result.smoke_result == "pass"
    end
  end

  test "every operator command has help text and JSON output guidance" do
    for command <- @expected_commands do
      help = OperatorTasks.help!(command)

      assert help =~ "mix conveyor.#{command} --json"
      assert help =~ "--output PATH"
      assert help =~ "contact live providers"
    end
  end

  test "new Mix task shells are compiled and expose moduledocs" do
    for command <- @new_shell_commands do
      module = task_module!(command)
      spec = OperatorTasks.spec!(command)

      assert Code.ensure_loaded?(module)
      assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(module)
      assert moduledoc =~ "mix #{spec.task} --json"
      assert moduledoc =~ "never contacts live providers"
    end
  end

  test "task shells print JSON and can write structured smoke output" do
    output_path =
      Path.join([
        System.tmp_dir!(),
        "conveyor-operator-task-test",
        "#{System.unique_integer([:positive])}-init.json"
      ])

    json_output =
      capture_io(fn ->
        Mix.Tasks.Conveyor.Init.run(["--json", "--output", output_path])
      end)

    assert Jason.decode!(json_output)["command"] == "init"
    assert Jason.decode!(File.read!(output_path))["command"] == "init"
  end

  test "task shells reject unstable positional arguments" do
    assert_raise Mix.Error, ~r/unexpected arguments/, fn ->
      Mix.Tasks.Conveyor.Init.run(["extra"])
    end
  end

  test "report command regenerates artifacts with stable RunBundle root and structured log" do
    first_backend = LocalDisk.new(root: tmp_root("report-first"))
    second_backend = LocalDisk.new(root: tmp_root("report-second"))

    assert {:ok, evidence} = EvidenceRecorder.build(evidence_attrs())

    first_artifact = store_evidence_artifact(first_backend, evidence)
    second_artifact = store_evidence_artifact(second_backend, evidence)

    assert {:ok, first_log} =
             Conveyor.OperatorTasks.Report.regenerate(%{
               backend: first_backend,
               run_id: evidence["run_id"],
               bundle_id: "bundle-report",
               created_at: ~U[2026-06-17 02:00:00Z],
               artifacts: [first_artifact]
             })

    assert {:ok, second_log} =
             Conveyor.OperatorTasks.Report.regenerate(%{
               backend: second_backend,
               run_id: evidence["run_id"],
               bundle_id: "bundle-report",
               created_at: ~U[2026-06-17 03:00:00Z],
               artifacts: [string_keyed_artifact(second_artifact)]
             })

    assert first_log.schema_version == "conveyor.report_regeneration_log@1"
    assert first_log.category == "report_regeneration"
    assert first_log.matrix_ref == "conveyor-quality-ci-evals-vmr.13"
    assert first_log.harness_ref == "conveyor-quality-ci-evals-vmr.14"

    assert first_log.vmr_refs == [
             "conveyor-quality-ci-evals-vmr.13",
             "conveyor-quality-ci-evals-vmr.14"
           ]

    assert first_log.command == "report"
    assert first_log.task == "conveyor.report"
    assert first_log.status == "pass"
    assert first_log.exit_code == 0
    assert first_log.bundle_root_sha256 =~ ~r/^sha256:[a-f0-9]{64}$/
    assert first_log.bundle_root_sha256 == second_log.bundle_root_sha256
    assert first_log.verification.digest_verification == "before_projection"
    assert first_log.verification.verified_blob_count == 1
    assert first_log.verification.generated_artifacts_verified == true
    assert first_log.source_artifact_count == 1
    assert first_log.projected_artifact_count == 3
    assert Enum.sort(first_log.projected_artifact_roles) == ["dossier", "evidence", "pr_body"]

    assert %{category: "human_report_generation", finding_count: 0} = first_log.generated_reports
    assert File.exists?(first_log.manifest_path)
    assert File.exists?(first_log.run_bundle_path)
  end

  test "report regeneration verifies blob digests before projecting files" do
    backend = LocalDisk.new(root: tmp_root("report-digest-mismatch"))

    assert {:ok, artifact} =
             LocalDisk.put_artifact(backend, %{
               artifact_key: "gate-result",
               artifact_role: "gate",
               projection_path: "gate/gate-result.json",
               schema_version: "gate@1",
               bytes: "original gate evidence"
             })

    File.write!(artifact.blob_path, "tampered gate evidence")

    assert {:error,
            %{
              category: "artifact_digest_mismatch",
              action: "block_projection",
              regeneration_status: "blocked",
              verification_stage: "pre_projection",
              harness_ref: "conveyor-quality-ci-evals-vmr.14"
            }} =
             Conveyor.OperatorTasks.Report.regenerate(%{
               backend: backend,
               run_id: "run-report-digest-mismatch",
               bundle_id: "bundle-report-digest-mismatch",
               artifacts: [artifact]
             })

    refute File.exists?(
             Path.join([
               backend.root,
               ".conveyor",
               "runs",
               "run-report-digest-mismatch",
               "gate",
               "gate-result.json"
             ])
           )
  end

  test "report regeneration emits explicit findings for missing and quarantined artifacts" do
    backend = LocalDisk.new(root: tmp_root("report-explicit-findings"))

    assert {:error,
            %{
              schema_version: "conveyor.report_regeneration_finding@1",
              category: "report_regeneration_missing_artifacts",
              action: "provide_stored_artifact_records",
              regeneration_status: "blocked"
            }} =
             Conveyor.OperatorTasks.Report.regenerate(%{
               backend: backend,
               run_id: "run-report-missing-artifacts",
               bundle_id: "bundle-report-missing-artifacts",
               artifacts: []
             })

    assert {:ok, secret_artifact} =
             LocalDisk.put_artifact(backend, %{
               artifact_key: "command-log",
               artifact_role: "log",
               projection_path: "logs/install.log",
               schema_version: "log@1",
               content_type: "text/plain",
               bytes: "POSTGRES_PASSWORD=FAKE_SECRET_LOG_password-value"
             })

    assert {:error,
            %{
              category: "artifact_secret_detected",
              action: "block_gate",
              regeneration_status: "blocked",
              redaction_reports: reports
            }} =
             Conveyor.OperatorTasks.Report.regenerate(%{
               backend: backend,
               run_id: "run-report-secret-blocked",
               bundle_id: "bundle-report-secret-blocked",
               artifacts: [secret_artifact]
             })

    assert length(reports) == 1
  end

  defp task_module!(command) do
    command
    |> OperatorTasks.spec!()
    |> Map.fetch!(:task_module)
    |> then(&String.to_existing_atom("Elixir." <> &1))
  end

  defp tmp_root(name) do
    Path.join([
      System.tmp_dir!(),
      "conveyor-operator-report-test",
      "#{System.unique_integer([:positive])}-#{name}"
    ])
  end

  defp store_evidence_artifact(backend, evidence) do
    assert {:ok, artifact} =
             LocalDisk.put_artifact(backend, %{
               artifact_key: evidence["evidence_id"],
               artifact_role: "evidence",
               projection_path: "evidence/evidence.json",
               schema_version: "evidence@1",
               content_type: "application/json",
               bytes: Jason.encode!(evidence)
             })

    artifact
  end

  defp string_keyed_artifact(artifact) do
    Map.new(artifact, fn {key, value} -> {to_string(key), value} end)
  end

  defp evidence_attrs do
    %{
      evidence_id: "evidence-report-001",
      run_id: "run-report-20260617-0001",
      slice_id: "slice-report-001",
      station_key: "record_evidence",
      summary: "Conductor verification reproduced the implementation claims.",
      agent: %{
        adapter: "codex",
        session_id: "agent-session-report-001",
        profile_id: "agent-profile-implementer"
      },
      base_commit: "1111111",
      head_commit: "2222222",
      autonomy_level: "L1",
      changed_files: ["lib/conveyor/operator_tasks.ex"],
      diff_ref: "artifact://diffs/run-report-20260617-0001.patch",
      conductor_commands: [
        %{
          command_id: "cmd-format",
          command: "mix format --check-formatted",
          exit_code: 0,
          status: "pass",
          evidence_ref: "artifact://conductor/format.log"
        },
        %{
          command_id: "cmd-test",
          command: "mix test test/conveyor/operator_tasks_test.exs",
          exit_code: 0,
          status: "pass",
          evidence_ref: "artifact://conductor/mix-test.log"
        }
      ],
      acceptance_criteria: [
        %{criterion_id: "AC-1", description: "Regeneration verifies digests first."},
        %{criterion_id: "AC-2", description: "Regeneration emits a stable root digest."}
      ],
      acceptance_results: %{
        "AC-1" => %{
          status: "pass",
          evidence_refs: ["artifact://conductor/mix-test.log"]
        },
        "AC-2" => %{
          status: "pass",
          evidence_refs: ["artifact://reports/dossier.md", "artifact://reports/pr_body.md"]
        }
      },
      quality_refs: ["artifact://quality/ubs.txt"],
      policy_violations: [],
      review_result: %{decision: "not_reviewed", evidence_refs: []},
      gate_result: %{decision: "not_run", evidence_refs: []},
      known_risks: [
        %{
          risk_id: "risk-report-regeneration-fixture",
          severity: "low",
          summary: "Fixture validates report command projection without live providers."
        }
      ],
      created_at: ~U[2026-06-17 02:00:00Z]
    }
  end
end
