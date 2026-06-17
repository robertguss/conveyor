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
  @redaction_report_schema "conveyor.redaction_report@1"

  @secret_patterns [
    %{
      id: "openai_api_key",
      label: "OpenAI API key",
      regex: ~r/sk-[A-Za-z0-9_-]{16,}/,
      replacement: "[REDACTED:openai_api_key]"
    },
    %{
      id: "aws_access_key_id",
      label: "AWS access key id",
      regex: ~r/AKIA[0-9A-Z]{16}/,
      replacement: "[REDACTED:aws_access_key_id]"
    },
    %{
      id: "github_token",
      label: "GitHub token",
      regex: ~r/gh[pousr]_[A-Za-z0-9_]{20,}/,
      replacement: "[REDACTED:github_token]"
    },
    %{
      id: "assignment_secret",
      label: "Credential assignment",
      regex: ~r/(?i)\b[a-z0-9_]*(api[_-]?key|password|secret|token)\s*[:=]\s*['"]?[^\s'",}]+/,
      replacement: "[REDACTED:assignment_secret]"
    }
  ]

  @sensitive_labels MapSet.new(["secret", "sensitive", "restricted"])

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
    artifact_key = fetch_required!(attrs, :artifact_key)
    artifact_role = fetch_required!(attrs, :artifact_role)
    projection_path = fetch_required!(attrs, :projection_path)
    secret_findings = secret_findings(bytes, artifact_key, artifact_role, projection_path)
    sensitivity = classify_sensitivity(attrs, secret_findings)
    quarantined = sensitive?(sensitivity)
    redacted_bytes = redacted_bytes(bytes, secret_findings)
    redacted_sha256 = sha256_bytes(redacted_bytes)

    redacted_blob_path =
      maybe_store_redacted_blob(backend, quarantined, redacted_sha256, redacted_bytes)

    redaction_report =
      redaction_report(artifact_key, artifact_role, secret_findings, sha256, redacted_sha256)

    File.mkdir_p!(Path.dirname(blob_path))
    File.write!(blob_path, bytes)

    artifact = %{
      schema_version: "conveyor.stored_artifact@1",
      artifact_role: artifact_role,
      artifact_key: artifact_key,
      projection_path: projection_path,
      content_type: Map.get(attrs, :content_type, "application/octet-stream"),
      sensitivity: sensitivity,
      quarantined: quarantined,
      sha256: sha256,
      sha256_hex: strip_sha256(sha256),
      raw_sha256: sha256,
      raw_sha256_hex: strip_sha256(sha256),
      redacted_sha256: redacted_sha256,
      redacted_sha256_hex: strip_sha256(redacted_sha256),
      size_bytes: byte_size(bytes),
      blob_path: blob_path,
      redacted_blob_path: redacted_blob_path,
      redaction_report: redaction_report,
      secret_findings: secret_findings,
      ledger: [
        ledger_event("artifact_blob_stored", %{
          artifact_key: artifact_key,
          sha256: sha256,
          blob_path: blob_path,
          projection_path: projection_path,
          sensitivity: sensitivity,
          quarantined: quarantined
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
    policy = Map.get(attrs, :policy, Map.get(attrs, "policy", %{}))

    with {:ok, verified_artifacts} <- verify_artifacts(artifacts),
         :ok <- enforce_secret_policy(verified_artifacts, policy),
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
         redaction_report: projection_redaction_report(verified_artifacts),
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

  def secret_blocking_finding(artifacts) do
    reports =
      artifacts
      |> Enum.filter(&Map.get(&1, :quarantined, false))
      |> Enum.map(& &1.redaction_report)

    %{
      schema_version: @finding_schema,
      category: "artifact_secret_detected",
      severity: "error",
      matrix_ref: "conveyor-quality-ci-evals-vmr.13",
      action: "block_gate",
      message: "Sensitive artifact findings require explicit redacted-continuation policy.",
      redaction_reports: reports
    }
  end

  def sensitive_without_redaction_finding(artifacts) do
    %{
      schema_version: @finding_schema,
      category: "artifact_sensitive_without_redaction",
      severity: "error",
      matrix_ref: "conveyor-quality-ci-evals-vmr.13",
      action: "block_gate",
      message: "Sensitive artifacts without a distinct redacted digest cannot be projected.",
      artifacts:
        Enum.map(artifacts, fn artifact ->
          %{
            artifact_key: artifact.artifact_key,
            artifact_role: artifact.artifact_role,
            raw_sha256: artifact.raw_sha256
          }
        end)
    }
  end

  defp verify_artifacts(artifacts) when is_list(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, verified} ->
      bytes = File.read!(artifact.blob_path)
      actual_sha256 = sha256_bytes(bytes)

      if actual_sha256 == artifact.sha256 do
        case verify_redacted_artifact(artifact) do
          {:ok, redacted_bytes} ->
            verified_artifact =
              artifact
              |> Map.put(:bytes, bytes)
              |> Map.put(:redacted_bytes, redacted_bytes)

            {:cont, {:ok, [verified_artifact | verified]}}

          {:error, finding} ->
            {:halt, {:error, finding}}
        end
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
          projection_bytes = projection_bytes(artifact)
          projected_sha256 = sha256_bytes(projection_bytes)

          File.mkdir_p!(Path.dirname(path))
          File.write!(path, projection_bytes)

          entry = %{
            "schema_version" => artifact_schema_version(artifact),
            "artifact_role" => artifact.artifact_role,
            "path" => relative_path,
            "sha256" => strip_sha256(projected_sha256),
            "raw_sha256" => artifact.raw_sha256_hex,
            "redacted_sha256" => redacted_sha256_hex(artifact),
            "sensitivity" => artifact.sensitivity,
            "quarantined" => artifact.quarantined,
            "projection_mode" => projection_mode(artifact),
            "export_policy" => export_policy(artifact)
          }

          event =
            ledger_event("artifact_projected", %{
              artifact_key: artifact.artifact_key,
              sha256: projected_sha256,
              raw_sha256: artifact.raw_sha256,
              redacted_sha256: Map.get(artifact, :redacted_sha256),
              blob_path: artifact.blob_path,
              projection_path: path,
              projection_mode: projection_mode(artifact)
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

  defp secret_findings(bytes, artifact_key, artifact_role, projection_path) do
    Enum.flat_map(@secret_patterns, fn pattern ->
      count = Regex.scan(pattern.regex, bytes) |> length()

      if count == 0 do
        []
      else
        [
          %{
            schema_version: @finding_schema,
            category: "artifact_secret_detected",
            severity: "error",
            secret_type: pattern.id,
            label: pattern.label,
            artifact_key: artifact_key,
            artifact_role: artifact_role,
            projection_path: projection_path,
            occurrence_count: count,
            action: "quarantine_raw_artifact"
          }
        ]
      end
    end)
  end

  defp classify_sensitivity(attrs, secret_findings) do
    explicit =
      attrs
      |> Map.get(:sensitivity, Map.get(attrs, "sensitivity", "internal"))
      |> to_string()

    cond do
      secret_findings != [] -> "secret"
      sensitive?(explicit) -> explicit
      true -> explicit
    end
  end

  defp sensitive?(sensitivity) do
    sensitivity
    |> to_string()
    |> String.downcase()
    |> then(&MapSet.member?(@sensitive_labels, &1))
  end

  defp redacted_bytes(bytes, secret_findings) when secret_findings == [], do: bytes

  defp redacted_bytes(bytes, _secret_findings) do
    Enum.reduce(@secret_patterns, bytes, fn pattern, redacted ->
      Regex.replace(pattern.regex, redacted, pattern.replacement)
    end)
  end

  defp maybe_store_redacted_blob(backend, true, redacted_sha256, redacted_bytes) do
    path = blob_path(backend, redacted_sha256)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, redacted_bytes)
    path
  end

  defp maybe_store_redacted_blob(_backend, false, _redacted_sha256, _redacted_bytes), do: nil

  defp redaction_report(artifact_key, artifact_role, findings, raw_sha256, redacted_sha256) do
    %{
      schema_version: @redaction_report_schema,
      artifact_key: artifact_key,
      artifact_role: artifact_role,
      finding_count: Enum.count(findings),
      findings: findings,
      raw_sha256: raw_sha256,
      redacted_sha256: redacted_sha256,
      redacted: raw_sha256 != redacted_sha256
    }
  end

  defp verify_redacted_artifact(%{quarantined: true} = artifact) do
    case Map.get(artifact, :redacted_blob_path) do
      path when is_binary(path) ->
        bytes = File.read!(path)
        actual_sha256 = sha256_bytes(bytes)

        if actual_sha256 == artifact.redacted_sha256 do
          {:ok, bytes}
        else
          {:error, redacted_digest_mismatch_finding(artifact, actual_sha256)}
        end

      _ ->
        {:error, sensitive_without_redaction_finding([artifact])}
    end
  end

  defp verify_redacted_artifact(_artifact), do: {:ok, nil}

  defp redacted_digest_mismatch_finding(artifact, actual_sha256) do
    %{
      schema_version: @finding_schema,
      category: "artifact_redacted_digest_mismatch",
      severity: "error",
      matrix_ref: "conveyor-quality-ci-evals-vmr.13",
      artifact_key: artifact.artifact_key,
      expected_sha256: artifact.redacted_sha256,
      actual_sha256: actual_sha256,
      action: "block_projection",
      message: "Stored redacted artifact bytes do not match the recorded digest."
    }
  end

  defp enforce_secret_policy(artifacts, policy) do
    quarantined = Enum.filter(artifacts, &Map.get(&1, :quarantined, false))
    without_redaction = Enum.reject(quarantined, &redacted_projection_available?/1)

    cond do
      quarantined == [] ->
        :ok

      without_redaction != [] ->
        {:error, sensitive_without_redaction_finding(without_redaction)}

      policy_allows_redacted_continuation?(policy) ->
        :ok

      true ->
        {:error, secret_blocking_finding(quarantined)}
    end
  end

  defp policy_allows_redacted_continuation?(policy) when is_map(policy) do
    direct =
      Map.get(policy, :allow_redacted_continuation) ||
        Map.get(policy, "allow_redacted_continuation")

    nested =
      case Map.get(policy, :secret_policy, Map.get(policy, "secret_policy", %{})) do
        secret_policy when is_map(secret_policy) ->
          Map.get(secret_policy, :allow_redacted_continuation) ||
            Map.get(secret_policy, "allow_redacted_continuation")

        _ ->
          false
      end

    direct == true or nested == true
  end

  defp policy_allows_redacted_continuation?(_policy), do: false

  defp redacted_projection_available?(artifact) do
    Map.get(artifact, :redacted_blob_path) not in [nil, ""] and
      Map.get(artifact, :redacted_sha256) != Map.get(artifact, :raw_sha256)
  end

  defp projection_bytes(%{quarantined: true} = artifact), do: artifact.redacted_bytes
  defp projection_bytes(artifact), do: artifact.bytes

  defp projection_mode(%{quarantined: true}), do: "redacted"
  defp projection_mode(_artifact), do: "raw"

  defp redacted_sha256_hex(%{quarantined: true, redacted_sha256_hex: sha256}), do: sha256
  defp redacted_sha256_hex(_artifact), do: nil

  defp export_policy(%{quarantined: true}) do
    %{
      "raw_export" => "quarantined",
      "projection" => "redacted",
      "gate" => "requires_allow_redacted_continuation"
    }
  end

  defp export_policy(_artifact) do
    %{
      "raw_export" => "allowed",
      "projection" => "raw",
      "gate" => "allowed"
    }
  end

  defp projection_redaction_report(artifacts) do
    reports = Enum.map(artifacts, & &1.redaction_report)

    %{
      schema_version: @redaction_report_schema,
      artifact_count: Enum.count(artifacts),
      quarantined_count: Enum.count(artifacts, &Map.get(&1, :quarantined, false)),
      finding_count: Enum.sum(Enum.map(reports, & &1.finding_count)),
      reports: reports
    }
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
