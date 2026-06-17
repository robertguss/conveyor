defmodule Conveyor.EvidenceRecorderTest do
  use ExUnit.Case, async: true

  alias Conveyor.EvidenceRecorder

  test "writes schema-valid machine evidence from independent conductor verification" do
    root = tmp_root("machine-evidence")

    assert {:ok, evidence, summary} =
             EvidenceRecorder.write(root, evidence_attrs())

    evidence_path = Path.join([root, ".conveyor", evidence["path"]])

    assert File.exists?(evidence_path)
    assert evidence["schema_version"] == "evidence@1"
    assert evidence["artifact_type"] == "report"
    assert evidence["provenance"]["source"] == "independent_conductor_verification"
    refute evidence["provenance"]["agent_self_report_used"]
    refute Map.has_key?(evidence, "agent_self_report")
    assert EvidenceRecorder.verify_digest(evidence)

    assert %{
             schema_version: "conveyor.evidence_summary@1",
             category: "machine_evidence_record",
             evidence_id: "evidence-run-001",
             acceptance_count: 2,
             command_count: 2,
             sha256: sha256
           } = summary

    assert sha256 == evidence["sha256"]

    assert_schema_valid!(evidence_path)
  end

  test "rejects incomplete acceptance-criterion mappings with a structured finding" do
    attrs =
      evidence_attrs(%{
        acceptance_results: %{
          "AC-1" => %{
            status: "pass",
            evidence_refs: ["artifact://conductor/mix-test.log"]
          }
        }
      })

    assert {:error,
            %{
              schema_version: "conveyor.evidence_finding@1",
              category: "evidence_acceptance_mapping",
              failure_category: "incomplete_acceptance_mapping",
              severity: "error",
              missing_criteria: ["AC-2"],
              action: "record_independent_conductor_results_for_each_acceptance_criterion"
            }} = EvidenceRecorder.build(attrs)
  end

  defp evidence_attrs(overrides \\ %{}) do
    %{
      evidence_id: "evidence-run-001",
      run_id: "run-20260617-0001",
      slice_id: "slice-auth-001",
      station_key: "record_evidence",
      summary: "Conductor verification reproduced the implementation claims.",
      agent: %{
        adapter: "codex",
        session_id: "agent-session-001",
        profile_id: "agent-profile-implementer"
      },
      agent_self_report: "Agent says every acceptance criterion passed.",
      base_commit: "1111111",
      head_commit: "2222222",
      autonomy_level: "L1",
      changed_files: ["lib/conveyor/evidence_recorder.ex"],
      diff_ref: "artifact://diffs/run-20260617-0001.patch",
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
          command: "mix test test/conveyor/evidence_recorder_test.exs",
          exit_code: 0,
          status: "pass",
          evidence_ref: "artifact://conductor/mix-test.log"
        }
      ],
      acceptance_criteria: [
        %{criterion_id: "AC-1", description: "Evidence comes from conductor verification."},
        %{criterion_id: "AC-2", description: "Acceptance-criterion mapping is complete."}
      ],
      acceptance_results: %{
        "AC-1" => %{
          status: "pass",
          evidence_refs: ["artifact://conductor/mix-test.log"]
        },
        "AC-2" => %{
          status: "pass",
          evidence_refs: ["artifact://conductor/schema-validation.json"]
        }
      },
      quality_refs: ["artifact://quality/ubs.txt"],
      policy_violations: [],
      review_result: %{decision: "not_reviewed", evidence_refs: []},
      gate_result: %{decision: "not_run", evidence_refs: []},
      known_risks: [
        %{
          risk_id: "risk-jsonschema-runtime",
          severity: "low",
          summary: "Schema validation uses local Python tooling."
        }
      ],
      created_at: ~U[2026-06-17 00:40:00Z]
    }
    |> Map.merge(overrides)
  end

  defp assert_schema_valid!(payload_path) do
    schema =
      "docs/schemas/evidence.v1.schema.json"
      |> File.read!()
      |> Jason.decode!()

    payload =
      payload_path
      |> File.read!()
      |> Jason.decode!()

    assert [] = schema_errors(schema, payload)
  end

  defp schema_errors(schema, value, path \\ "$") do
    []
    |> add_type_errors(schema, value, path)
    |> add_const_errors(schema, value, path)
    |> add_enum_errors(schema, value, path)
    |> add_string_errors(schema, value, path)
    |> add_object_errors(schema, value, path)
    |> add_array_errors(schema, value, path)
  end

  defp add_type_errors(errors, %{"type" => "object"}, value, path) when not is_map(value),
    do: ["#{path} must be object" | errors]

  defp add_type_errors(errors, %{"type" => "array"}, value, path) when not is_list(value),
    do: ["#{path} must be array" | errors]

  defp add_type_errors(errors, %{"type" => "string"}, value, path) when not is_binary(value),
    do: ["#{path} must be string" | errors]

  defp add_type_errors(errors, %{"type" => "integer"}, value, path) when not is_integer(value),
    do: ["#{path} must be integer" | errors]

  defp add_type_errors(errors, _schema, _value, _path), do: errors

  defp add_const_errors(errors, %{"const" => expected}, value, path) do
    if value == expected, do: errors, else: ["#{path} must equal #{inspect(expected)}" | errors]
  end

  defp add_const_errors(errors, _schema, _value, _path), do: errors

  defp add_enum_errors(errors, %{"enum" => values}, value, path) do
    if value in values, do: errors, else: ["#{path} must be one of #{inspect(values)}" | errors]
  end

  defp add_enum_errors(errors, _schema, _value, _path), do: errors

  defp add_string_errors(errors, schema, value, path) when is_binary(value) do
    errors
    |> maybe_min_length_error(schema, value, path)
    |> maybe_pattern_error(schema, value, path)
  end

  defp add_string_errors(errors, _schema, _value, _path), do: errors

  defp maybe_min_length_error(errors, %{"minLength" => min_length}, value, path) do
    if String.length(value) >= min_length,
      do: errors,
      else: ["#{path} length must be at least #{min_length}" | errors]
  end

  defp maybe_min_length_error(errors, _schema, _value, _path), do: errors

  defp maybe_pattern_error(errors, %{"pattern" => pattern}, value, path) do
    if Regex.match?(Regex.compile!(pattern), value),
      do: errors,
      else: ["#{path} must match #{pattern}" | errors]
  end

  defp maybe_pattern_error(errors, _schema, _value, _path), do: errors

  defp add_object_errors(errors, schema, value, path) when is_map(value) do
    properties = Map.get(schema, "properties", %{})

    errors
    |> required_errors(Map.get(schema, "required", []), value, path)
    |> additional_property_errors(
      Map.get(schema, "additionalProperties", true),
      properties,
      value,
      path
    )
    |> property_errors(properties, value, path)
  end

  defp add_object_errors(errors, _schema, _value, _path), do: errors

  defp required_errors(errors, required, value, path) do
    Enum.reduce(required, errors, fn key, acc ->
      if Map.has_key?(value, key), do: acc, else: ["#{path}.#{key} is required" | acc]
    end)
  end

  defp additional_property_errors(errors, false, properties, value, path) do
    allowed = Map.keys(properties) |> MapSet.new()

    value
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> Enum.reduce(errors, fn key, acc -> ["#{path}.#{key} is not allowed" | acc] end)
  end

  defp additional_property_errors(errors, _additional_properties, _properties, _value, _path),
    do: errors

  defp property_errors(errors, properties, value, path) do
    Enum.reduce(properties, errors, fn {key, property_schema}, acc ->
      if Map.has_key?(value, key) do
        schema_errors(property_schema, Map.fetch!(value, key), "#{path}.#{key}") ++ acc
      else
        acc
      end
    end)
  end

  defp add_array_errors(errors, schema, value, path) when is_list(value) do
    errors
    |> maybe_min_items_error(schema, value, path)
    |> item_errors(Map.get(schema, "items"), value, path)
  end

  defp add_array_errors(errors, _schema, _value, _path), do: errors

  defp maybe_min_items_error(errors, %{"minItems" => min_items}, value, path) do
    if length(value) >= min_items,
      do: errors,
      else: ["#{path} must contain at least #{min_items} item(s)" | errors]
  end

  defp maybe_min_items_error(errors, _schema, _value, _path), do: errors

  defp item_errors(errors, nil, _value, _path), do: errors

  defp item_errors(errors, item_schema, value, path) do
    value
    |> Enum.with_index()
    |> Enum.reduce(errors, fn {item, index}, acc ->
      schema_errors(item_schema, item, "#{path}[#{index}]") ++ acc
    end)
  end

  defp tmp_root(name) do
    Path.join([
      System.tmp_dir!(),
      "conveyor-evidence-recorder",
      "#{System.unique_integer([:positive])}-#{name}"
    ])
  end
end
