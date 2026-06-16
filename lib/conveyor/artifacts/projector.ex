defmodule Conveyor.Artifacts.Projector do
  @moduledoc """
  Behaviour for content-addressed artifact storage and human-friendly projection.

  Implementations must store bytes by digest before projection and must verify
  the stored bytes again before writing projected run-bundle files.
  """

  @type backend :: struct()
  @type finding :: map()
  @type stored_artifact :: map()
  @type projection :: map()

  @callback put_artifact(backend(), map()) :: {:ok, stored_artifact()} | {:error, finding()}
  @callback project_run(backend(), map()) :: {:ok, projection()} | {:error, finding()}

  def object_storage_deferred do
    %{
      schema_version: "conveyor.artifact_backend_deferred@1",
      category: "artifact_storage_backend",
      backend: "object_storage",
      status: "deferred",
      reason: "Phase 0 local disk backend establishes the projector seam before object storage."
    }
  end
end

defmodule Conveyor.Artifacts.Projector.LocalDisk do
  @moduledoc """
  Local disk implementation of the artifact projector.

  Blob identity lives under `.conveyor/blobs/sha256/<hex>`. Projection paths live
  under `.conveyor/runs/<run_id>` and are never treated as identity.
  """

  @behaviour Conveyor.Artifacts.Projector

  defstruct [:root]

  @ledger_schema "conveyor.artifact_projection_ledger@1"
  @finding_schema "conveyor.artifact_projection_finding@1"
  @manifest_schema "manifest@1"
  @run_bundle_schema "run_bundle@1"

  def new(opts) do
    root =
      opts
      |> Keyword.fetch!(:root)
      |> Path.expand()

    %__MODULE__{root: root}
  end

  @impl true
  def put_artifact(%__MODULE__{} = backend, attrs) when is_map(attrs) do
    bytes = fetch_required!(attrs, :bytes)
    sha256 = sha256_bytes(bytes)
    blob_path = blob_path(backend, sha256)

    File.mkdir_p!(Path.dirname(blob_path))
    File.write!(blob_path, bytes)

    artifact = %{
      schema_version: "conveyor.stored_artifact@1",
      artifact_role: fetch_required!(attrs, :artifact_role),
      artifact_key: fetch_required!(attrs, :artifact_key),
      projection_path: fetch_required!(attrs, :projection_path),
      content_type: Map.get(attrs, :content_type, "application/octet-stream"),
      sensitivity: Map.get(attrs, :sensitivity, "internal"),
      sha256: sha256,
      sha256_hex: strip_sha256(sha256),
      size_bytes: byte_size(bytes),
      blob_path: blob_path,
      ledger: [
        ledger_event("artifact_blob_stored", %{
          artifact_key: fetch_required!(attrs, :artifact_key),
          sha256: sha256,
          blob_path: blob_path,
          projection_path: fetch_required!(attrs, :projection_path)
        })
      ]
    }

    {:ok, artifact}
  end

  @impl true
  def project_run(%__MODULE__{} = backend, attrs) when is_map(attrs) do
    run_id = fetch_required!(attrs, :run_id)
    bundle_id = fetch_required!(attrs, :bundle_id)
    created_at = Map.get(attrs, :created_at, DateTime.utc_now()) |> iso8601()
    artifacts = fetch_required!(attrs, :artifacts)

    with {:ok, verified_artifacts} <- verify_artifacts(artifacts),
         {:ok, projected_entries, projection_ledger} <-
           write_projected_artifacts(backend, run_id, verified_artifacts),
         {:ok, manifest, manifest_path, manifest_sha256} <-
           write_manifest(backend, run_id, bundle_id, created_at, projected_entries),
         {:ok, run_bundle, run_bundle_path} <-
           write_run_bundle(
             backend,
             run_id,
             bundle_id,
             created_at,
             projected_entries,
             manifest_path,
             manifest_sha256
           ) do
      {:ok,
       %{
         schema_version: "conveyor.artifact_projection@1",
         run_id: run_id,
         bundle_id: bundle_id,
         root_digest: run_bundle["root_digest"],
         manifest: manifest,
         run_bundle: run_bundle,
         manifest_path: manifest_path,
         run_bundle_path: run_bundle_path,
         artifacts: projected_entries,
         ledger:
           Enum.flat_map(verified_artifacts, & &1.ledger) ++
             projection_ledger ++
             [
               ledger_event("run_bundle_projected", %{
                 run_id: run_id,
                 bundle_id: bundle_id,
                 root_digest: run_bundle["root_digest"],
                 manifest_path: manifest_path,
                 run_bundle_path: run_bundle_path
               })
             ]
       }}
    end
  end

  def digest_mismatch_finding(artifact, actual_sha256) do
    %{
      schema_version: @finding_schema,
      category: "artifact_digest_mismatch",
      severity: "error",
      matrix_ref: "conveyor-quality-ci-evals-vmr.13",
      artifact_key: artifact.artifact_key,
      expected_sha256: artifact.sha256,
      actual_sha256: actual_sha256,
      action: "block_projection",
      message: "Stored artifact bytes do not match the recorded digest."
    }
  end

  defp verify_artifacts(artifacts) when is_list(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, verified} ->
      bytes = File.read!(artifact.blob_path)
      actual_sha256 = sha256_bytes(bytes)

      if actual_sha256 == artifact.sha256 do
        {:cont, {:ok, [Map.put(artifact, :bytes, bytes) | verified]}}
      else
        {:halt, {:error, digest_mismatch_finding(artifact, actual_sha256)}}
      end
    end)
    |> case do
      {:ok, verified} -> {:ok, Enum.reverse(verified)}
      error -> error
    end
  end

  defp write_projected_artifacts(backend, run_id, artifacts) do
    Enum.reduce_while(artifacts, {:ok, [], []}, fn artifact, {:ok, entries, ledger} ->
      case projection_path(backend, run_id, artifact.projection_path) do
        {:ok, path, relative_path} ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, artifact.bytes)

          entry = %{
            "schema_version" => artifact_schema_version(artifact),
            "artifact_role" => artifact.artifact_role,
            "path" => relative_path,
            "sha256" => artifact.sha256_hex
          }

          event =
            ledger_event("artifact_projected", %{
              artifact_key: artifact.artifact_key,
              sha256: artifact.sha256,
              blob_path: artifact.blob_path,
              projection_path: path
            })

          {:cont, {:ok, [entry | entries], [event | ledger]}}

        {:error, finding} ->
          {:halt, {:error, finding}}
      end
    end)
    |> case do
      {:ok, entries, ledger} -> {:ok, Enum.reverse(entries), Enum.reverse(ledger)}
      error -> error
    end
  end

  defp write_manifest(backend, run_id, bundle_id, created_at, artifact_entries) do
    unsigned = %{
      "schema_version" => @manifest_schema,
      "manifest_id" => "#{bundle_id}-manifest",
      "run_id" => run_id,
      "created_at" => created_at,
      "artifacts" => artifact_entries
    }

    manifest = Map.put(unsigned, "root_digest", canonical_sha256(unsigned))
    encoded = encode_json(manifest)
    path = Path.join(run_root(backend, run_id), "manifest.json")
    File.write!(path, encoded)

    {:ok, manifest, path, strip_sha256(sha256_bytes(encoded))}
  end

  defp write_run_bundle(
         backend,
         run_id,
         bundle_id,
         created_at,
         projected_entries,
         manifest_path,
         manifest_sha256
       ) do
    manifest_entry = %{
      "schema_version" => @manifest_schema,
      "artifact_role" => "manifest",
      "path" => relative_to_projector_root(backend, manifest_path),
      "sha256" => manifest_sha256
    }

    artifact_entries = projected_entries ++ [manifest_entry]

    unsigned = %{
      "schema_version" => @run_bundle_schema,
      "bundle_id" => bundle_id,
      "run_id" => run_id,
      "created_at" => created_at,
      "artifact_schema_versions" => artifact_schema_versions(artifact_entries),
      "artifacts" => artifact_entries
    }

    run_bundle = Map.put(unsigned, "root_digest", canonical_sha256(unsigned))
    path = Path.join(run_root(backend, run_id), "run_bundle.json")
    File.write!(path, encode_json(run_bundle))

    {:ok, run_bundle, path}
  end

  defp artifact_schema_version(%{schema_version: schema_version})
       when is_binary(schema_version) do
    schema_version
  end

  defp artifact_schema_version(%{artifact_role: artifact_role}) do
    "#{artifact_role}@1"
  end

  defp artifact_schema_versions(entries) do
    Map.new(entries, fn entry ->
      {entry["artifact_role"], entry["schema_version"]}
    end)
  end

  defp blob_path(%__MODULE__{} = backend, sha256) do
    Path.join([backend.root, ".conveyor", "blobs", "sha256", strip_sha256(sha256)])
  end

  defp projection_path(%__MODULE__{} = backend, run_id, relative_path) do
    if Path.type(relative_path) == :relative and not path_escapes?(relative_path) do
      path = Path.join(run_root(backend, run_id), relative_path)
      {:ok, path, relative_to_projector_root(backend, path)}
    else
      {:error,
       %{
         schema_version: @finding_schema,
         category: "artifact_projection_path_rejected",
         severity: "error",
         matrix_ref: "conveyor-quality-ci-evals-vmr.13",
         path: relative_path,
         action: "block_projection"
       }}
    end
  end

  defp run_root(%__MODULE__{} = backend, run_id) do
    Path.join([backend.root, ".conveyor", "runs", run_id])
  end

  defp relative_to_projector_root(%__MODULE__{} = backend, path) do
    path
    |> Path.relative_to(Path.join(backend.root, ".conveyor"))
  end

  defp path_escapes?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == ".."))
  end

  defp fetch_required!(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key)) ||
      raise ArgumentError, "missing artifact projection field: #{key}"
  end

  defp sha256_bytes(bytes) when is_binary(bytes) do
    "sha256:" <>
      (:crypto.hash(:sha256, bytes)
       |> Base.encode16(case: :lower))
  end

  defp strip_sha256("sha256:" <> digest), do: digest

  defp canonical_sha256(payload), do: sha256_bytes(canonical_json(payload))

  defp canonical_json(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, value} ->
      Jason.encode!(key) <> ":" <> canonical_json(value)
    end)
    |> then(&"{#{&1}}")
  end

  defp canonical_json(list) when is_list(list) do
    list
    |> Enum.map_join(",", &canonical_json/1)
    |> then(&"[#{&1}]")
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp encode_json(payload), do: Jason.encode!(payload, pretty: true) <> "\n"

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(value) when is_binary(value), do: value

  defp ledger_event(event_type, fields) do
    Map.merge(
      %{
        schema_version: @ledger_schema,
        event_type: event_type,
        category: "artifact_projection"
      },
      fields
    )
  end
end
