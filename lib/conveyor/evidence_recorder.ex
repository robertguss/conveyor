defmodule Conveyor.EvidenceRecorder do
  @moduledoc """
  Builds and writes the machine evidence record produced by conductor verification.

  Agent narration may appear in upstream inputs, but this recorder only emits
  evidence derived from conductor-owned verification results.
  """

  @schema_version "evidence@1"
  @summary_schema_version "conveyor.evidence_summary@1"
  @finding_schema_version "conveyor.evidence_finding@1"

  def build(attrs) when is_map(attrs) do
    with {:ok, criteria} <- normalize_criteria(fetch(attrs, :acceptance_criteria, [])),
         {:ok, acceptance} <-
           normalize_acceptance(criteria, fetch(attrs, :acceptance_results, %{})),
         :ok <- ensure_mapping_complete(acceptance) do
      evidence =
        attrs
        |> unsigned_evidence(criteria, acceptance)
        |> put_digest()

      {:ok, evidence}
    end
  end

  def write(root, attrs) when is_binary(root) and is_map(attrs) do
    with {:ok, evidence} <- build(attrs) do
      absolute_path = Path.join([Path.expand(root), ".conveyor", evidence["path"]])

      File.mkdir_p!(Path.dirname(absolute_path))
      File.write!(absolute_path, encode_json(evidence))

      {:ok, evidence, summary(evidence, absolute_path)}
    end
  end

  def verify_digest(evidence) when is_map(evidence) do
    evidence["sha256"] == digest_unsigned(evidence)
  end

  def digest_unsigned(evidence) when is_map(evidence) do
    evidence
    |> Map.drop(["sha256"])
    |> canonical_json()
    |> sha256_hex()
  end

  def summary(evidence, absolute_path \\ nil) when is_map(evidence) do
    acceptance_results = get_in(evidence, ["acceptance", "results"]) || []

    %{
      schema_version: @summary_schema_version,
      category: "machine_evidence_record",
      evidence_id: evidence["evidence_id"],
      run_id: evidence["run_id"],
      slice_id: evidence["slice_id"],
      sha256: evidence["sha256"],
      path: evidence["path"],
      absolute_path: absolute_path,
      acceptance_count: length(acceptance_results),
      command_count: length(evidence["conductor_commands"] || []),
      quality_ref_count: length(evidence["quality_refs"] || []),
      policy_violation_count: length(evidence["policy_violations"] || []),
      known_risk_count: length(evidence["known_risks"] || [])
    }
  end

  def incomplete_mapping_finding(missing_ids, criteria_ids) do
    %{
      schema_version: @finding_schema_version,
      category: "evidence_acceptance_mapping",
      failure_category: "incomplete_acceptance_mapping",
      severity: "error",
      missing_criteria: missing_ids,
      criteria_ids: criteria_ids,
      action: "record_independent_conductor_results_for_each_acceptance_criterion"
    }
  end

  defp unsigned_evidence(attrs, criteria, acceptance) do
    run_id = fetch_required!(attrs, :run_id)

    %{
      "schema_version" => @schema_version,
      "evidence_id" => fetch_required!(attrs, :evidence_id),
      "run_id" => run_id,
      "slice_id" => fetch_required!(attrs, :slice_id),
      "station_key" => fetch(attrs, :station_key, "record_evidence"),
      "artifact_type" => "report",
      "path" => fetch(attrs, :path, "runs/#{run_id}/evidence/evidence.json"),
      "summary" => fetch_required!(attrs, :summary),
      "redaction_status" => fetch(attrs, :redaction_status, "not_required"),
      "agent" => normalize_agent(fetch_required!(attrs, :agent)),
      "base_commit" => fetch_required!(attrs, :base_commit),
      "head_commit" => fetch_required!(attrs, :head_commit),
      "autonomy_level" => fetch_required!(attrs, :autonomy_level),
      "changed_files" => normalize_string_list(fetch_required!(attrs, :changed_files)),
      "diff_ref" => fetch_required!(attrs, :diff_ref),
      "conductor_commands" => normalize_commands(fetch_required!(attrs, :conductor_commands)),
      "acceptance" => %{
        "mapping_complete" => true,
        "criteria" => criteria,
        "results" => acceptance.results
      },
      "quality_refs" => normalize_string_list(fetch(attrs, :quality_refs, [])),
      "policy_violations" => normalize_maps(fetch(attrs, :policy_violations, [])),
      "review_result" => normalize_result(fetch_required!(attrs, :review_result), :review_result),
      "gate_result" => normalize_result(fetch_required!(attrs, :gate_result), :gate_result),
      "known_risks" => normalize_maps(fetch(attrs, :known_risks, [])),
      "provenance" => %{
        "created_at" => normalize_datetime(fetch(attrs, :created_at, DateTime.utc_now())),
        "created_by" => "conductor",
        "source" => "independent_conductor_verification",
        "agent_self_report_used" => false
      }
    }
  end

  defp put_digest(evidence), do: Map.put(evidence, "sha256", digest_unsigned(evidence))

  defp normalize_criteria(criteria) when is_list(criteria) and criteria != [] do
    {:ok,
     Enum.map(criteria, fn criterion ->
       %{
         "criterion_id" => fetch_required!(criterion, :criterion_id),
         "description" => fetch_required!(criterion, :description)
       }
     end)}
  end

  defp normalize_criteria(_criteria),
    do: {:error, validation_finding("acceptance_criteria must be a non-empty list")}

  defp normalize_acceptance(criteria, results_input) do
    results_by_id = acceptance_results_by_id(results_input)

    results =
      Enum.map(criteria, fn %{"criterion_id" => criterion_id} ->
        case Map.get(results_by_id, criterion_id) do
          nil -> nil
          result -> normalize_acceptance_result(criterion_id, result)
        end
      end)

    missing_ids =
      criteria
      |> Enum.zip(results)
      |> Enum.filter(fn {_criterion, result} ->
        is_nil(result) or result["evidence_refs"] == []
      end)
      |> Enum.map(fn {%{"criterion_id" => criterion_id}, _result} -> criterion_id end)

    {:ok, %{results: Enum.reject(results, &is_nil/1), missing_ids: missing_ids}}
  end

  defp acceptance_results_by_id(results) when is_map(results) do
    Map.new(results, fn {criterion_id, result} -> {to_string(criterion_id), result} end)
  end

  defp acceptance_results_by_id(results) when is_list(results) do
    Map.new(results, fn result -> {fetch_required!(result, :criterion_id), result} end)
  end

  defp acceptance_results_by_id(_results),
    do: raise(ArgumentError, "acceptance_results must be a map or list")

  defp normalize_acceptance_result(criterion_id, result) when is_map(result) do
    %{
      "criterion_id" => criterion_id,
      "status" => fetch_required!(result, :status),
      "evidence_refs" => normalize_string_list(fetch(result, :evidence_refs, [])),
      "verified_by" => fetch(result, :verified_by, "conductor"),
      "verification_source" => "independent_conductor_verification"
    }
  end

  defp ensure_mapping_complete(%{missing_ids: []}), do: :ok

  defp ensure_mapping_complete(%{missing_ids: missing_ids, results: results}) do
    result_ids = Enum.map(results, & &1["criterion_id"])
    {:error, incomplete_mapping_finding(missing_ids, Enum.sort(result_ids ++ missing_ids))}
  end

  defp normalize_agent(agent) when is_map(agent) do
    %{
      "adapter" => fetch_required!(agent, :adapter),
      "session_id" => fetch_required!(agent, :session_id),
      "profile_id" => fetch_required!(agent, :profile_id)
    }
  end

  defp normalize_agent(_agent), do: raise(ArgumentError, "agent must be a map")

  defp normalize_commands(commands) when is_list(commands) and commands != [] do
    Enum.map(commands, fn command ->
      %{
        "command_id" => fetch_required!(command, :command_id),
        "command" => fetch_required!(command, :command),
        "exit_code" => fetch_required!(command, :exit_code),
        "status" => fetch_required!(command, :status),
        "evidence_ref" => fetch_required!(command, :evidence_ref)
      }
    end)
  end

  defp normalize_commands(_commands),
    do: raise(ArgumentError, "conductor_commands must be a non-empty list")

  defp normalize_result(result, _key) when is_map(result), do: normalize_map(result)
  defp normalize_result(_result, key), do: raise(ArgumentError, "#{key} must be a map")

  defp normalize_maps(values) when is_list(values), do: Enum.map(values, &normalize_map/1)
  defp normalize_maps(_values), do: raise(ArgumentError, "expected a list of maps")

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_map(_map), do: raise(ArgumentError, "expected a map")

  defp normalize_string_list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp normalize_string_list(_values), do: raise(ArgumentError, "expected a list")

  defp normalize_value(%DateTime{} = datetime), do: normalize_datetime(datetime)
  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp normalize_datetime(value) when is_binary(value), do: value

  defp fetch_required!(map, key) when is_map(map) do
    fetch(map, key) || raise KeyError, key: key, term: map
  end

  defp fetch(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp validation_finding(message) do
    %{
      schema_version: @finding_schema_version,
      category: "evidence_validation",
      failure_category: "invalid_evidence_input",
      severity: "error",
      message: message
    }
  end

  defp encode_json(payload), do: Jason.encode!(payload, pretty: true) <> "\n"

  defp sha256_hex(binary) when is_binary(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end

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
end
