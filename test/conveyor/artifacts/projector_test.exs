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
    assert projection.root_digest =~ ~r/^sha256:[a-f0-9]{64}$/
    assert projection.manifest["schema_version"] == "manifest@1"
    assert projection.run_bundle["schema_version"] == "run_bundle@1"

    assert [%{"path" => "runs/run-001/baseline/baseline-summary.json"}] =
             projection.manifest["artifacts"]

    assert Enum.any?(projection.ledger, &(&1.event_type == "artifact_blob_stored"))
    assert Enum.any?(projection.ledger, &(&1.event_type == "artifact_projected"))
    assert Enum.any?(projection.ledger, &(&1.event_type == "run_bundle_projected"))
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
end
