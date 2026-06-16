defmodule Conveyor.PlanImport do
  @moduledoc """
  Imports normalized `conveyor.plan@1` contracts from sidecar files or Markdown.

  Markdown remains the narrative surface, but only a schema-valid fenced
  `conveyor-plan@1` block can become handoff-ready conductor input.
  """

  alias Conveyor.Domain.PayloadHelpers

  @contract_schema_version "conveyor.plan@1"
  @report_schema_version "conveyor.plan_import.report@1"
  @finding_schema_version "conveyor.plan_import.finding@1"
  @summary_schema_version "conveyor.normalized_plan_summary@1"
  @default_schema_path Path.join(["docs", "schemas", "conveyor.plan.v1.schema.json"])
  @markdown_fence "conveyor-plan@1"

  def contract_schema_version, do: @contract_schema_version
  def report_schema_version, do: @report_schema_version
  def finding_schema_version, do: @finding_schema_version
  def summary_schema_version, do: @summary_schema_version

  def lint_file(path, opts \\ []) when is_binary(path) and is_list(opts) do
    case File.read(path) do
      {:ok, contents} ->
        lint_source(contents, path, opts)

      {:error, reason} ->
        report(nil, path, "missing_file", [], [
          finding("source_read_failed", "error", "$", "could not read plan source: #{inspect(reason)}")
        ])
    end
  end

  def lint_source(contents, source_path, opts \\ [])
      when is_binary(contents) and is_binary(source_path) and is_list(opts) do
    schema_path = Keyword.get(opts, :schema_path, @default_schema_path)

    case decode_source(contents, source_path) do
      {:ok, contract, source_ref} ->
        normalized = PayloadHelpers.normalize_map(contract)
        findings = validate_contract(normalized, schema_path)
        report(normalized, source_path, source_ref.source_kind, [source_ref], findings)

      {:prose_only, source_ref} ->
        report(nil, source_path, source_ref.source_kind, [source_ref], [
          finding(
            "missing_normalized_contract",
            "error",
            "$",
            "Markdown plan is prose-only; add a fenced conveyor-plan@1 block before handoff"
          )
        ])

      {:error, source_kind, findings} ->
        report(nil, source_path, source_kind, [], findings)
    end
  end

  def import_file!(path, opts \\ []) when is_binary(path) and is_list(opts) do
    path
    |> lint_file(opts)
    |> persist_report!()
  end

  def import_source!(contents, source_path, opts \\ [])
      when is_binary(contents) and is_binary(source_path) and is_list(opts) do
    contents
    |> lint_source(source_path, opts)
    |> persist_report!()
  end

  def contract_sha256(contract) when is_map(contract), do: PayloadHelpers.canonical_sha256(contract)

  defp persist_report!(%{handoff_ready: true, normalized_contract: contract} = report) do
    payload =
      contract
      |> Map.put("contract_sha256", report.contract_sha256)
      |> Map.put("source_refs", report.source_refs)

    attrs = %{
      external_id: contract["plan_id"],
      name: contract["title"],
      status: "active",
      payload: payload
    }

    case Ash.create(Conveyor.Domain.Plan, attrs, action: :create) do
      {:ok, record} ->
        Map.put(report, :record, record)

      {:error, error} ->
        raise "failed to persist plan #{contract["plan_id"]}: #{Exception.message(error)}"
    end
  end

  defp persist_report!(report) do
    codes = report.findings |> Enum.map(& &1.finding_code) |> Enum.join(", ")
    raise ArgumentError, "plan source is not handoff_ready: #{codes}"
  end

  defp decode_source(contents, source_path) do
    case source_kind_for(source_path) do
      "sidecar_json" ->
        decode_json(contents, source_ref(source_path, "sidecar_json", 1, line_count(contents)))

      "sidecar_yaml" ->
        decode_yaml(contents, source_ref(source_path, "sidecar_yaml", 1, line_count(contents)))

      "markdown_fence" ->
        decode_markdown(contents, source_path)

      source_kind ->
        {:error, source_kind,
         [
           finding(
             "unsupported_source_type",
             "error",
             "$",
             "plan source must be .json, .yml, .yaml, or Markdown with a conveyor-plan@1 fence"
           )
         ]}
    end
  end

  defp decode_markdown(contents, source_path) do
    lines = String.split(contents, "\n", trim: false)

    case find_fenced_contract(lines) do
      {:ok, body, start_line, end_line} ->
        decode_yaml(body, source_ref(source_path, "markdown_fence", start_line, end_line))

      {:error, :unterminated, start_line} ->
        {:error, "markdown_fence",
         [
           finding(
             "unterminated_contract_fence",
             "error",
             "$",
             "fenced conveyor-plan@1 block starting at line #{start_line} is not closed"
           )
         ]}

      :not_found ->
        {:prose_only, source_ref(source_path, "markdown_prose", 1, length(lines))}
    end
  end

  defp decode_json(contents, source_ref) do
    case Jason.decode(contents) do
      {:ok, contract} when is_map(contract) ->
        {:ok, contract, source_ref}

      {:ok, _other} ->
        {:error, source_ref.source_kind, [
          finding("invalid_source_payload", "error", "$", "plan source must decode to an object")
        ]}

      {:error, error} ->
        {:error, source_ref.source_kind, [
          finding("malformed_source", "error", "$", "could not parse JSON plan: #{Exception.message(error)}")
        ]}
    end
  end

  defp decode_yaml(contents, source_ref) do
    case YamlElixir.read_from_string(contents) do
      {:ok, contract} when is_map(contract) ->
        {:ok, contract, source_ref}

      {:ok, _other} ->
        {:error, source_ref.source_kind, [
          finding("invalid_source_payload", "error", "$", "plan source must decode to an object")
        ]}

      {:error, error} ->
        {:error, source_ref.source_kind, [
          finding("malformed_source", "error", "$", "could not parse YAML plan: #{Exception.message(error)}")
        ]}
    end
  end

  defp validate_contract(contract, schema_path) do
    case File.read(schema_path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, schema} ->
            validate_value(schema, contract, "$")

          {:error, error} ->
            [finding("schema_load_failed", "error", "$", "invalid plan schema JSON: #{Exception.message(error)}")]
        end

      {:error, reason} ->
        [finding("schema_load_failed", "error", "$", "could not read plan schema: #{inspect(reason)}")]
    end
  end

  defp validate_value(schema, value, path) when is_map(schema) do
    []
    |> add_const_findings(schema, value, path)
    |> add_enum_findings(schema, value, path)
    |> add_type_findings(schema, value, path)
  end

  defp add_const_findings(findings, %{"const" => expected}, value, path) do
    if value == expected do
      findings
    else
      [
        finding("invalid_const", "error", path, "expected #{inspect(expected)}, got #{inspect(value)}")
        | findings
      ]
    end
  end

  defp add_const_findings(findings, _schema, _value, _path), do: findings

  defp add_enum_findings(findings, %{"enum" => allowed}, value, path) do
    if value in allowed do
      findings
    else
      [
        finding("invalid_enum", "error", path, "expected one of #{inspect(allowed)}, got #{inspect(value)}")
        | findings
      ]
    end
  end

  defp add_enum_findings(findings, _schema, _value, _path), do: findings

  defp add_type_findings(findings, %{"type" => "object"} = schema, value, path) when is_map(value) do
    findings ++ validate_object(schema, value, path)
  end

  defp add_type_findings(findings, %{"type" => "array"} = schema, value, path) when is_list(value) do
    findings ++ validate_array(schema, value, path)
  end

  defp add_type_findings(findings, %{"type" => "string"} = schema, value, path)
       when is_binary(value) do
    findings ++ validate_string(schema, value, path)
  end

  defp add_type_findings(findings, %{"type" => "boolean"}, value, _path) when is_boolean(value) do
    findings
  end

  defp add_type_findings(findings, %{"type" => expected}, value, path) do
    [
      finding("invalid_type", "error", path, "expected #{expected}, got #{type_name(value)}")
      | findings
    ]
  end

  defp add_type_findings(findings, _schema, _value, _path), do: findings

  defp validate_object(schema, value, path) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    allowed = properties |> Map.keys() |> MapSet.new()

    missing_findings =
      required
      |> Enum.reject(&Map.has_key?(value, &1))
      |> Enum.map(fn key ->
        finding("missing_required_field", "error", "#{path}.#{key}", "required field #{key} is missing")
      end)

    extra_findings =
      if Map.get(schema, "additionalProperties", true) == false do
        value
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(allowed, &1))
        |> Enum.sort()
        |> Enum.map(fn key ->
          finding("additional_property", "error", "#{path}.#{key}", "field #{key} is not allowed")
        end)
      else
        []
      end

    child_findings =
      properties
      |> Enum.flat_map(fn {key, child_schema} ->
        if Map.has_key?(value, key) do
          validate_value(child_schema, Map.fetch!(value, key), "#{path}.#{key}")
        else
          []
        end
      end)

    missing_findings ++ extra_findings ++ child_findings
  end

  defp validate_array(schema, values, path) do
    min_item_findings =
      case Map.get(schema, "minItems") do
        count when is_integer(count) and length(values) < count ->
          [finding("min_items_violation", "error", path, "expected at least #{count} item(s)")]

        _other ->
          []
      end

    item_schema = Map.get(schema, "items", %{})

    child_findings =
      values
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} ->
        validate_value(item_schema, value, "#{path}[#{index}]")
      end)

    min_item_findings ++ child_findings
  end

  defp validate_string(schema, value, path) do
    case Map.get(schema, "minLength") do
      count when is_integer(count) ->
        if String.length(value) < count do
          [finding("min_length_violation", "error", path, "expected at least #{count} character(s)")]
        else
          []
        end

      _other ->
        []
    end
  end

  defp report(contract, source_path, source_kind, source_refs, findings) do
    contract_sha256 = if contract, do: contract_sha256(contract)
    handoff_ready = contract != nil and not Enum.any?(findings, &(&1.severity == "error"))

    %{
      schema_version: @report_schema_version,
      category: "plan_import",
      source_path: source_path,
      source_kind: source_kind,
      status: status(handoff_ready, findings),
      handoff_ready: handoff_ready,
      contract_schema_version: contract && contract["schema_version"],
      contract_sha256: contract_sha256,
      normalized_contract: contract,
      normalized_contract_summary: contract && normalized_contract_summary(contract, contract_sha256),
      source_refs: source_refs,
      findings: findings
    }
  end

  defp normalized_contract_summary(contract, contract_sha256) do
    requirements = Map.get(contract, "requirements", [])

    %{
      schema_version: @summary_schema_version,
      plan_id: contract["plan_id"],
      project_key: get_in(contract, ["project", "key"]),
      goal: contract["goal"],
      contract_sha256: contract_sha256,
      non_goal_count: length(Map.get(contract, "non_goals", [])),
      requirement_count: length(requirements),
      acceptance_criteria_count:
        Enum.reduce(requirements, 0, fn requirement, count ->
          count + length(Map.get(requirement, "acceptance_criteria", []))
        end),
      verification_command_count: length(Map.get(contract, "verification_commands", [])),
      decision_count: length(Map.get(contract, "decisions", [])),
      slice_count: length(Map.get(contract, "slices", []))
    }
  end

  defp status(true, _findings), do: "ok"

  defp status(false, [%{finding_code: "missing_normalized_contract"}]), do: "lint_only"

  defp status(false, _findings), do: "error"

  defp find_fenced_contract(lines) do
    indexed = Enum.with_index(lines, 1)

    case Enum.find(indexed, fn {line, _line_no} -> fence_open?(line) end) do
      nil ->
        :not_found

      {_line, start_line} ->
        indexed
        |> Enum.drop(start_line)
        |> Enum.split_while(fn {line, _line_no} -> not fence_close?(line) end)
        |> case do
          {body_lines, [{_closing, end_line} | _rest]} ->
            body =
              body_lines
              |> Enum.map(&elem(&1, 0))
              |> Enum.join("\n")

            {:ok, body, start_line, end_line}

          {_body_lines, []} ->
            {:error, :unterminated, start_line}
        end
    end
  end

  defp fence_open?(line), do: fence_info(line) == @markdown_fence
  defp fence_close?(line), do: String.trim(line) == "```"

  defp fence_info(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "```") and trimmed != "```" do
      trimmed
      |> String.trim_leading("```")
      |> String.trim()
    end
  end

  defp source_kind_for(source_path) do
    case source_path |> Path.extname() |> String.downcase() do
      ".json" -> "sidecar_json"
      ".yaml" -> "sidecar_yaml"
      ".yml" -> "sidecar_yaml"
      ".md" -> "markdown_fence"
      ".markdown" -> "markdown_fence"
      _other -> "unknown"
    end
  end

  defp source_ref(source_path, source_kind, start_line, end_line) do
    %{
      schema_version: "conveyor.plan_source_ref@1",
      source_path: source_path,
      source_kind: source_kind,
      start_line: start_line,
      end_line: end_line
    }
  end

  defp finding(code, severity, path, message) do
    %{
      schema_version: @finding_schema_version,
      category: "plan_import",
      finding_code: code,
      severity: severity,
      path: path,
      message: message
    }
  end

  defp type_name(value) when is_map(value), do: "object"
  defp type_name(value) when is_list(value), do: "array"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "number"
  defp type_name(nil), do: "null"
  defp type_name(_value), do: "unknown"

  defp line_count(contents), do: contents |> String.split("\n", trim: false) |> length()
end
