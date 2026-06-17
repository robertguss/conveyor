defmodule Conveyor.Artifacts.ProjectorTest do
  use ExUnit.Case, async: true

  alias Conveyor.Artifacts.Projector
  alias Conveyor.Artifacts.Projector.LocalDisk

  test "stores bytes by sha256 before projecting human-friendly files" do
    backend = LocalDisk.new(root: tmp_root("happy-path"))
    bytes = ~s({"status":"passed"})

    assert {:ok, artifact} =
             LocalDisk.put_artifact(backend, %{
               artifact_key: "baseline-summary",
               artifact_role: "evidence",
               projection_path: "baseline/baseline-summary.json",
               schema_version: "evidence@1",
               content_type: "application/json",
               bytes: bytes
             })

    assert artifact.sha256 =~ ~r/^sha256:[a-f0-9]{64}$/
    assert artifact.blob_path =~ "/.conveyor/blobs/sha256/"
    assert File.read!(artifact.blob_path) == bytes

    assert {:ok, projection} =
             LocalDisk.project_run(backend, %{
               run_id: "run-001",
               bundle_id: "bundle-001",
               created_at: ~U[2026-06-16 21:40:00Z],
               artifacts: [artifact]
             })

    projected_path =
      Path.join([
        backend.root,
        ".conveyor",
        "runs",
        "run-001",
        "baseline",
        "baseline-summary.json"
      ])

    assert File.read!(projected_path) == bytes
    refute projected_path == artifact.blob_path
    assert projection.bundle_root_sha256 =~ ~r/^sha256:[a-f0-9]{64}$/
    assert projection.manifest["schema_version"] == "manifest@1"
    assert projection.run_bundle["schema_version"] == "run_bundle@1"
    assert projection.run_bundle["bundle_root_sha256"] == projection.bundle_root_sha256
    refute Map.has_key?(projection.run_bundle, "root_digest")

    assert [%{"path" => "runs/run-001/baseline/baseline-summary.json"}] =
             projection.manifest["artifacts"]

    assert %{
             "schema_version" => "conveyor.run_bundle_manifest@1",
             "matrix_ref" => "conveyor-quality-ci-evals-vmr.13",
             "artifact_count" => 1,
             "excluded_fields" => excluded_fields,
             "artifacts" => [
               %{
                 "artifact_role" => "evidence",
                 "path" => "runs/run-001/baseline/baseline-summary.json"
               }
             ]
           } = projection.run_bundle["canonical_manifest"]

    assert "created_at" in excluded_fields["timestamp_fields"]
    assert "blob_path" in excluded_fields["host_path_fields"]
    assert "manifest" in excluded_fields["generated_artifact_roles"]

    assert Enum.any?(projection.ledger, &(&1.event_type == "artifact_blob_stored"))
    assert Enum.any?(projection.ledger, &(&1.event_type == "artifact_projected"))
    assert Enum.any?(projection.ledger, &(&1.event_type == "run_bundle_projected"))
  end

  test "bundle_root_sha256 excludes timestamps host paths and input ordering" do
    first_backend = LocalDisk.new(root: tmp_root("canonical-first"))
    second_backend = LocalDisk.new(root: tmp_root("canonical-second"))

    first_evidence =
      store_plain_artifact(
        first_backend,
        "evidence",
        "evidence",
        "evidence/evidence.json",
        ~s({"status":"passed"})
      )

    first_dossier =
      store_plain_artifact(
        first_backend,
        "dossier",
        "dossier",
        "dossiers/summary.md",
        "human review dossier"
      )

    second_evidence =
      store_plain_artifact(
        second_backend,
        "evidence",
        "evidence",
        "evidence/evidence.json",
        ~s({"status":"passed"})
      )

    second_dossier =
      store_plain_artifact(
        second_backend,
        "dossier",
        "dossier",
        "dossiers/summary.md",
        "human review dossier"
      )

    assert first_evidence.blob_path != second_evidence.blob_path

    assert {:ok, first_projection} =
             LocalDisk.project_run(first_backend, %{
               run_id: "run-canonical",
               bundle_id: "bundle-canonical",
               created_at: ~U[2026-06-16 21:40:00Z],
               artifacts: [first_dossier, first_evidence]
             })

    assert {:ok, second_projection} =
             LocalDisk.project_run(second_backend, %{
               run_id: "run-canonical",
               bundle_id: "bundle-canonical",
               created_at: ~U[2026-06-17 21:40:00Z],
               artifacts: [second_evidence, second_dossier]
             })

    assert first_projection.manifest["root_digest"] != second_projection.manifest["root_digest"]
    assert first_projection.bundle_root_sha256 == second_projection.bundle_root_sha256

    assert first_projection.run_bundle["canonical_manifest"] ==
             second_projection.run_bundle["canonical_manifest"]

    canonical_artifacts_json =
      Jason.encode!(first_projection.run_bundle["canonical_manifest"]["artifacts"])

    refute canonical_artifacts_json =~ first_backend.root
    refute canonical_artifacts_json =~ second_backend.root
    refute canonical_artifacts_json =~ "blob_path"
    refute canonical_artifacts_json =~ "created_at"
  end

  test "blocks projection when stored blob bytes do not match recorded digest" do
    backend = LocalDisk.new(root: tmp_root("digest-mismatch"))

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
              expected_sha256: expected_sha256,
              actual_sha256: actual_sha256,
              action: "block_projection"
            }} =
             LocalDisk.project_run(backend, %{
               run_id: "run-002",
               bundle_id: "bundle-002",
               artifacts: [artifact]
             })

    refute expected_sha256 == actual_sha256

    refute File.exists?(
             Path.join([backend.root, ".conveyor", "runs", "run-002", "gate", "gate-result.json"])
           )
  end

  test "quarantines secret-bearing artifacts and blocks projection by default" do
    backend = LocalDisk.new(root: tmp_root("secret-block"))
    artifacts = store_secret_artifacts(backend)

    assert Enum.all?(artifacts, & &1.quarantined)
    assert Enum.all?(artifacts, &File.exists?(&1.redacted_blob_path))

    assert {:error,
            %{
              category: "artifact_secret_detected",
              action: "block_gate",
              redaction_reports: reports
            }} =
             LocalDisk.project_run(backend, %{
               run_id: "run-secret-blocked",
               bundle_id: "bundle-secret-blocked",
               artifacts: artifacts
             })

    assert length(reports) == 5

    for artifact <- artifacts do
      projected_path =
        Path.join([
          backend.root,
          ".conveyor",
          "runs",
          "run-secret-blocked",
          artifact.projection_path
        ])

      refute File.exists?(projected_path)
    end
  end

  test "projects redacted artifacts only when policy allows redacted continuation" do
    backend = LocalDisk.new(root: tmp_root("secret-redacted"))
    artifacts = store_secret_artifacts(backend)

    assert {:ok, projection} =
             LocalDisk.project_run(backend, %{
               run_id: "run-secret-redacted",
               bundle_id: "bundle-secret-redacted",
               artifacts: artifacts,
               policy: %{allow_redacted_continuation: true}
             })

    assert projection.redaction_report.quarantined_count == 5
    assert projection.redaction_report.finding_count >= 5

    for artifact <- artifacts do
      projected_path =
        Path.join([
          backend.root,
          ".conveyor",
          "runs",
          "run-secret-redacted",
          artifact.projection_path
        ])

      raw_bytes = File.read!(artifact.blob_path)
      redacted_bytes = File.read!(projected_path)

      assert raw_bytes =~ "FAKE_SECRET_"
      assert redacted_bytes =~ "[REDACTED:"
      refute redacted_bytes =~ "FAKE_SECRET_"
      refute redacted_bytes == raw_bytes
    end

    assert length(projection.manifest["artifacts"]) == 5

    for entry <- projection.manifest["artifacts"] do
      assert entry["quarantined"] == true
      assert entry["projection_mode"] == "redacted"
      assert entry["export_policy"]["raw_export"] == "quarantined"
      assert entry["raw_sha256"] != entry["redacted_sha256"]
      assert entry["sha256"] == entry["redacted_sha256"]
    end
  end

  test "rejects projection paths that escape the run bundle root" do
    backend = LocalDisk.new(root: tmp_root("path-rejection"))

    assert {:ok, artifact} =
             LocalDisk.put_artifact(backend, %{
               artifact_key: "unsafe",
               artifact_role: "evidence",
               projection_path: "../unsafe.json",
               schema_version: "evidence@1",
               bytes: "unsafe"
             })

    assert {:error,
            %{
              category: "artifact_projection_path_rejected",
              action: "block_projection"
            }} =
             LocalDisk.project_run(backend, %{
               run_id: "run-003",
               bundle_id: "bundle-003",
               artifacts: [artifact]
             })
  end

  test "exposes object storage as a deferred backend seam" do
    assert %{
             schema_version: "conveyor.artifact_backend_deferred@1",
             backend: "object_storage",
             status: "deferred"
           } = Projector.object_storage_deferred()
  end

  defp tmp_root(name) do
    Path.join([
      System.tmp_dir!(),
      "conveyor-artifact-projector",
      "#{System.unique_integer([:positive])}-#{name}"
    ])
  end

  defp store_plain_artifact(backend, key, role, path, bytes) do
    assert {:ok, artifact} =
             LocalDisk.put_artifact(backend, %{
               artifact_key: key,
               artifact_role: role,
               projection_path: path,
               schema_version: "#{role}@1",
               content_type: "text/plain",
               bytes: bytes
             })

    artifact
  end

  defp store_secret_artifacts(backend) do
    secret_specs = [
      {"prompt", "prompt", "prompts/task.md",
       "prompt api_key=FAKE_SECRET_PROMPT_sk-1234567890abcdef"},
      {"tool-output", "tool_output", "tool-output/codex.log",
       "tool emitted token=FAKE_SECRET_TOOL_ghp_1234567890abcdefghijklmnop"},
      {"command-log", "log", "logs/install.log",
       "POSTGRES_PASSWORD=FAKE_SECRET_LOG_password-value"},
      {"diff", "diff", "diffs/changes.diff", "+ secret: FAKE_SECRET_DIFF_AKIA1234567890ABCDEF"},
      {"dossier", "dossier", "dossiers/summary.md",
       "dossier password='FAKE_SECRET_DOSSIER_value'"}
    ]

    Enum.map(secret_specs, fn {key, role, path, bytes} ->
      assert {:ok, artifact} =
               LocalDisk.put_artifact(backend, %{
                 artifact_key: key,
                 artifact_role: role,
                 projection_path: path,
                 schema_version: "#{role}@1",
                 content_type: "text/plain",
                 bytes: bytes
               })

      artifact
    end)
  end
end
