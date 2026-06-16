defmodule Conveyor.ProjectConfig do
  @moduledoc """
  Deterministic loader for `.conveyor/config.toml`.

  Project config is conductor-owned input, not agent authority. The loader keeps
  parsing strict, emits redaction-safe findings, and refuses to let local config
  replace locked RunSpec inputs after execution has started.
  """

  @matrix_ref "conveyor-quality-ci-evals-vmr.13"
  @schema_version "conveyor.config.resolution@1"
  @required_commands ~w(plan_audit agents_md policy verify)
  @required_consumers ~w(plan_audit agents_md policy verification)
  @required_command_fields ~w(
    executable
    argv
    cwd
    timeout_ms
    env_keys
    read_roots
    write_roots
    network
    toolchain_profile
    policy_profile
    code_quality_profile
    artifact_path
    consumers
  )
  @secret_fragments ~w(secret token password credential private_key api_key)

  defstruct [
    :source_path,
    :version,
    :project_key,
    :defaults,
    :toolchain_profiles,
    :policy_profiles,
    :code_quality_profiles,
    :artifact_projection,
    :sample_repository,
    :commands,
    :digest
  ]

  def default_path, do: Path.join([".conveyor", "config.toml"])

  def load(path \\ default_path(), opts \\ []) when is_binary(path) and is_list(opts) do
    source_path = Path.expand(path)

    case File.read(path) do
      {:ok, contents} ->
        {raw_config, parse_findings} = parse_toml(contents)
        {config, validation_findings} = normalize(raw_config, source_path)

        findings =
          parse_findings ++
            validation_findings ++ locked_run_spec_findings(config, Keyword.get(opts, :locked_run_spec))

        event = to_log_event(config, findings, source_path)

        if error_findings?(findings) do
          {:error, event}
        else
          {:ok, config, event}
        end

      {:error, reason} ->
        finding =
          finding(
            "missing_config",
            "error",
            "could not read .conveyor config: #{inspect(reason)}",
            source_path
          )

        {:error, to_log_event(nil, [finding], source_path)}
    end
  end

  def command(%__MODULE__{commands: commands}, id) when is_binary(id) do
    Map.fetch(commands, id)
  end

  def commands_for(%__MODULE__{commands: commands}, consumer) when is_binary(consumer) do
    commands
    |> Map.values()
    |> Enum.filter(&(consumer in &1["consumers"]))
    |> Enum.sort_by(& &1["id"])
  end

  def to_log_event(config, findings \\ [], source_path \\ nil) do
    %{
      schema_version: @schema_version,
      matrix_ref: @matrix_ref,
      source_path: source_path || (config && config.source_path),
      status: if(error_findings?(findings), do: "error", else: "ok"),
      config_digest: config && config.digest,
      project_key: config && config.project_key,
      resolved_profiles: resolved_profiles(config),
      commands: resolved_commands(config),
      artifact_projection: config && config.artifact_projection,
      sample_repository: config && config.sample_repository,
      findings: Enum.map(findings, &redact_finding/1)
    }
  end

  defp parse_toml(contents) do
    {raw_config, _section, _seen_sections, findings} =
      contents
      |> String.split("\n", trim: false)
      |> Enum.with_index(1)
      |> Enum.reduce({%{}, [], MapSet.new(), []}, fn {line, line_no}, acc ->
        parse_toml_line(acc, line, line_no)
      end)

    {raw_config, Enum.reverse(findings)}
  end

  defp parse_toml_line({config, section, seen_sections, findings}, line, line_no) do
    trimmed =
      line
      |> strip_comment()
      |> String.trim()

    cond do
      trimmed == "" ->
        {config, section, seen_sections, findings}

      match = Regex.run(~r/^\[([A-Za-z0-9_.-]+)\]$/, trimmed) ->
        path = match |> Enum.at(1) |> String.split(".")
        section_key = Enum.join(path, ".")

        findings =
          if MapSet.member?(seen_sections, section_key) do
            [
              finding(
                "duplicate_section",
                "error",
                "duplicate config section [#{section_key}]",
                section_key,
                line_no
              )
              | findings
            ]
          else
            findings
          end

        {ensure_path(config, path), path, MapSet.put(seen_sections, section_key), findings}

      match = Regex.run(~r/^([A-Za-z0-9_.-]+)\s*=\s*(.+)$/, trimmed) ->
        key_path = section ++ (match |> Enum.at(1) |> String.split("."))
        value_text = Enum.at(match, 2)

        cond do
          path_exists?(config, key_path) ->
            path = Enum.join(key_path, ".")

            finding =
              finding("duplicate_key", "error", "duplicate config key #{path}", path, line_no)

            {config, section, seen_sections, [finding | findings]}

          true ->
            case parse_toml_value(value_text) do
              {:ok, value} ->
                {put_path(config, key_path, value), section, seen_sections, findings}

              {:error, message} ->
                path = Enum.join(key_path, ".")
                finding = finding("invalid_value", "error", message, path, line_no)
                {config, section, seen_sections, [finding | findings]}
            end
        end

      true ->
        finding =
          finding(
            "invalid_syntax",
            "error",
            "expected a section header or key/value assignment",
            "line:#{line_no}",
            line_no
          )

        {config, section, seen_sections, [finding | findings]}
    end
  end

  defp parse_toml_value(value_text) do
    value = String.trim(value_text)

    cond do
      String.starts_with?(value, "\"") ->
        parse_toml_string(value)

      String.starts_with?(value, "[") ->
        parse_toml_array(value)

      value == "true" ->
        {:ok, true}

      value == "false" ->
        {:ok, false}

      Regex.match?(~r/^-?[0-9]+$/, value) ->
        {:ok, String.to_integer(value)}

      true ->
        {:error, "unsupported TOML value; use quoted strings, integers, booleans, or arrays"}
    end
  end

  defp parse_toml_string(value) do
    if String.ends_with?(value, "\"") and String.length(value) >= 2 do
      body = String.slice(value, 1, String.length(value) - 2)

      {:ok,
       body
       |> String.replace("\\\"", "\"")
       |> String.replace("\\\\", "\\")}
    else
      {:error, "unterminated quoted string"}
    end
  end

  defp parse_toml_array(value) do
    if String.ends_with?(value, "]") do
      body =
        value
        |> String.slice(1, String.length(value) - 2)
        |> String.trim()

      if body == "" do
        {:ok, []}
      else
        body
        |> split_array_items()
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, values} ->
          case parse_toml_value(item) do
            {:ok, value} -> {:cont, {:ok, [value | values]}}
            {:error, message} -> {:halt, {:error, "invalid array item: #{message}"}}
          end
        end)
        |> case do
          {:ok, values} -> {:ok, Enum.reverse(values)}
          {:error, message} -> {:error, message}
        end
      end
    else
      {:error, "unterminated array"}
    end
  end

  defp split_array_items(body) do
    {items, current, _in_string, _escaped} =
      body
      |> String.graphemes()
      |> Enum.reduce({[], "", false, false}, fn char, {items, current, in_string, escaped} ->
        cond do
          escaped ->
            {items, current <> char, in_string, false}

          in_string and char == "\\" ->
            {items, current <> char, in_string, true}

          char == "\"" ->
            {items, current <> char, !in_string, false}

          char == "," and not in_string ->
            {[String.trim(current) | items], "", in_string, false}

          true ->
            {items, current <> char, in_string, false}
        end
      end)

    Enum.reverse([String.trim(current) | items])
  end

  defp strip_comment(line) do
    {text, _in_string, _escaped} =
      line
      |> String.graphemes()
      |> Enum.reduce_while({"", false, false}, fn char, {text, in_string, escaped} ->
        cond do
          escaped ->
            {:cont, {text <> char, in_string, false}}

          in_string and char == "\\" ->
            {:cont, {text <> char, in_string, true}}

          char == "\"" ->
            {:cont, {text <> char, !in_string, false}}

          char == "#" and not in_string ->
            {:halt, {text, in_string, escaped}}

          true ->
            {:cont, {text <> char, in_string, false}}
        end
      end)

    text
  end

  defp normalize(raw_config, source_path) do
    {toolchain_profiles, toolchain_findings} =
      profile_group(raw_config, ["toolchain", "profiles"], "toolchain.profiles")

    {policy_profiles, policy_findings} =
      profile_group(raw_config, ["policy", "profiles"], "policy.profiles")

    {code_quality_profiles, quality_findings} =
      profile_group(raw_config, ["code_quality", "profiles"], "code_quality.profiles")

    defaults = %{
      "toolchain_profile" => Map.get(raw_config, "default_toolchain_profile"),
      "policy_profile" => Map.get(raw_config, "default_policy_profile"),
      "code_quality_profile" => Map.get(raw_config, "default_code_quality_profile")
    }

    {commands, command_findings} =
      normalize_commands(raw_config, defaults, toolchain_profiles, policy_profiles, code_quality_profiles)

    config = %__MODULE__{
      source_path: source_path,
      version: Map.get(raw_config, "version"),
      project_key: Map.get(raw_config, "project_key"),
      defaults: defaults,
      toolchain_profiles: toolchain_profiles,
      policy_profiles: policy_profiles,
      code_quality_profiles: code_quality_profiles,
      artifact_projection: normalize_map(Map.get(raw_config, "artifact_projection", %{})),
      sample_repository: normalize_map(Map.get(raw_config, "sample_repository", %{})),
      commands: commands
    }

    findings =
      []
      |> require_version(config.version)
      |> require_string(config.project_key, "project_key", "project_key is required")
      |> require_default_profile(defaults, "toolchain_profile", toolchain_profiles)
      |> require_default_profile(defaults, "policy_profile", policy_profiles)
      |> require_default_profile(defaults, "code_quality_profile", code_quality_profiles)
      |> require_map(config.artifact_projection, "artifact_projection")
      |> require_map(config.sample_repository, "sample_repository")

    findings =
      findings ++ toolchain_findings ++ policy_findings ++ quality_findings ++ command_findings

    config = %{config | digest: digest_config(config)}

    {config, findings}
  end

  defp normalize_commands(raw_config, defaults, toolchain_profiles, policy_profiles, code_quality_profiles) do
    raw_commands = get_path(raw_config, ["commands"]) || %{}

    base_findings =
      if is_map(raw_commands) do
        []
      else
        [
          finding(
            "invalid_commands_section",
            "error",
            "commands must be a table of command specs",
            "commands"
          )
        ]
      end

    raw_commands = if is_map(raw_commands), do: raw_commands, else: %{}

    missing_findings =
      @required_commands
      |> Enum.reject(&Map.has_key?(raw_commands, &1))
      |> Enum.map(fn id ->
        finding("missing_required_command", "error", "missing required command #{id}", "commands.#{id}")
      end)

    {commands, spec_findings} =
      raw_commands
      |> Enum.sort_by(fn {id, _spec} -> id end)
      |> Enum.map(fn {id, spec} ->
        normalize_command(
          id,
          spec,
          defaults,
          toolchain_profiles,
          policy_profiles,
          code_quality_profiles
        )
      end)
      |> Enum.reduce({%{}, []}, fn {id, command, findings}, {commands, all_findings} ->
        {Map.put(commands, id, command), all_findings ++ findings}
      end)

    consumer_findings =
      @required_consumers
      |> Enum.reject(fn consumer ->
        Enum.any?(commands, fn {_id, command} -> consumer in command["consumers"] end)
      end)
      |> Enum.map(fn consumer ->
        finding(
          "missing_consumer_command",
          "error",
          "no command spec is available to #{consumer}",
          "commands"
        )
      end)

    {commands, base_findings ++ missing_findings ++ spec_findings ++ consumer_findings}
  end

  defp normalize_command(id, spec, defaults, toolchain_profiles, policy_profiles, code_quality_profiles)
       when is_map(spec) do
    command =
      %{
        "id" => id,
        "executable" => Map.get(spec, "executable"),
        "argv" => Map.get(spec, "argv", []),
        "cwd" => Map.get(spec, "cwd", "."),
        "timeout_ms" => Map.get(spec, "timeout_ms"),
        "env_keys" => Map.get(spec, "env_keys", []),
        "read_roots" => Map.get(spec, "read_roots", []),
        "write_roots" => Map.get(spec, "write_roots", []),
        "network" => Map.get(spec, "network", "disabled"),
        "toolchain_profile" => Map.get(spec, "toolchain_profile", defaults["toolchain_profile"]),
        "policy_profile" => Map.get(spec, "policy_profile", defaults["policy_profile"]),
        "code_quality_profile" => Map.get(spec, "code_quality_profile", defaults["code_quality_profile"]),
        "artifact_path" => Map.get(spec, "artifact_path"),
        "consumers" => Map.get(spec, "consumers", [])
      }
      |> normalize_map()

    findings =
      []
      |> require_command_fields(id, command)
      |> require_profile_ref(id, command, "toolchain_profile", toolchain_profiles)
      |> require_profile_ref(id, command, "policy_profile", policy_profiles)
      |> require_profile_ref(id, command, "code_quality_profile", code_quality_profiles)

    {id, command, findings}
  end

  defp normalize_command(id, _spec, _defaults, _toolchain_profiles, _policy_profiles, _code_quality_profiles) do
    command = %{"id" => id, "consumers" => []}

    finding =
      finding(
        "invalid_command_spec",
        "error",
        "command #{id} must be a table",
        "commands.#{id}"
      )

    {id, command, [finding]}
  end

  defp require_command_fields(findings, id, command) do
    Enum.reduce(@required_command_fields, findings, fn field, findings ->
      cond do
        field in ~w(argv env_keys read_roots write_roots consumers) ->
          require_string_list(findings, Map.get(command, field), "commands.#{id}.#{field}")

        field == "timeout_ms" ->
          require_positive_integer(findings, Map.get(command, field), "commands.#{id}.#{field}")

        true ->
          require_string(findings, Map.get(command, field), "commands.#{id}.#{field}", "#{field} is required")
      end
    end)
  end

  defp profile_group(raw_config, path, label) do
    case get_path(raw_config, path) do
      profiles when is_map(profiles) ->
        {normalize_map(profiles), []}

      nil ->
        {%{}, [finding("missing_profile_group", "error", "missing #{label}", label)]}

      _other ->
        {%{}, [finding("invalid_profile_group", "error", "#{label} must be a table", label)]}
    end
  end

  defp require_version(findings, 1), do: findings

  defp require_version(findings, other) do
    [
      finding("unsupported_config_version", "error", "config version must be integer 1", "version",
        nil,
        %{actual: other}
      )
      | findings
    ]
  end

  defp require_default_profile(findings, defaults, field, profiles) do
    value = Map.get(defaults, field)

    cond do
      not is_binary(value) or value == "" ->
        [
          finding(
            "missing_default_profile",
            "error",
            "default #{field} is required",
            "default_#{field}"
          )
          | findings
        ]

      not Map.has_key?(profiles, value) ->
        [
          finding(
            "unknown_default_profile",
            "error",
            "default #{field} references unknown profile #{value}",
            "default_#{field}"
          )
          | findings
        ]

      true ->
        findings
    end
  end

  defp require_profile_ref(findings, command_id, command, field, profiles) do
    value = Map.get(command, field)

    if is_binary(value) and Map.has_key?(profiles, value) do
      findings
    else
      [
        finding(
          "unknown_command_profile",
          "error",
          "command #{command_id} references unknown #{field} #{inspect(value)}",
          "commands.#{command_id}.#{field}"
        )
        | findings
      ]
    end
  end

  defp require_string(findings, value, path, message) do
    if is_binary(value) and value != "" do
      findings
    else
      [finding("missing_string", "error", message, path) | findings]
    end
  end

  defp require_string_list(findings, value, path) do
    if is_list(value) and Enum.all?(value, &(is_binary(&1) and &1 != "")) do
      findings
    else
      [finding("invalid_string_list", "error", "#{path} must be a list of strings", path) | findings]
    end
  end

  defp require_positive_integer(findings, value, path) do
    if is_integer(value) and value > 0 do
      findings
    else
      [finding("invalid_positive_integer", "error", "#{path} must be a positive integer", path) | findings]
    end
  end

  defp require_map(findings, value, path) do
    if is_map(value) do
      findings
    else
      [finding("invalid_table", "error", "#{path} must be a table", path) | findings]
    end
  end

  defp locked_run_spec_findings(_config, nil), do: []

  defp locked_run_spec_findings(config, locked_run_spec) when is_map(locked_run_spec) do
    started? =
      truthy?(Map.get(locked_run_spec, "locked")) or truthy?(Map.get(locked_run_spec, :locked)) or
        present?(Map.get(locked_run_spec, "started_at")) or present?(Map.get(locked_run_spec, :started_at))

    expected_digest =
      Map.get(locked_run_spec, "project_config_digest") ||
        Map.get(locked_run_spec, :project_config_digest)

    overrides =
      Map.get(locked_run_spec, "project_config_overrides") ||
        Map.get(locked_run_spec, :project_config_overrides) ||
        Map.get(locked_run_spec, "profile_overrides") ||
        Map.get(locked_run_spec, :profile_overrides) ||
        %{}

    cond do
      not started? ->
        []

      is_binary(expected_digest) and expected_digest != config.digest ->
        [
          finding(
            "locked_run_spec_config_digest_mismatch",
            "error",
            "locked RunSpec project_config_digest does not match current project config",
            "run_spec.project_config_digest",
            nil,
            %{expected: expected_digest, actual: config.digest}
          )
        ]

      is_map(overrides) and map_size(overrides) > 0 ->
        [
          finding(
            "locked_run_spec_project_config_override",
            "error",
            "project-local config cannot override locked RunSpec inputs after a run starts",
            "run_spec.project_config_overrides"
          )
        ]

      true ->
        []
    end
  end

  defp locked_run_spec_findings(_config, _locked_run_spec) do
    [
      finding(
        "invalid_locked_run_spec",
        "error",
        "locked_run_spec option must be a map",
        "locked_run_spec"
      )
    ]
  end

  defp resolved_profiles(nil), do: %{}

  defp resolved_profiles(config) do
    %{
      toolchain: sorted_keys(config.toolchain_profiles),
      policy: sorted_keys(config.policy_profiles),
      code_quality: sorted_keys(config.code_quality_profiles)
    }
  end

  defp resolved_commands(nil), do: []

  defp resolved_commands(config) do
    config.commands
    |> Map.values()
    |> Enum.sort_by(& &1["id"])
  end

  defp sorted_keys(map) when is_map(map), do: map |> Map.keys() |> Enum.sort()

  defp digest_config(config) do
    canonical =
      %{
        version: config.version,
        project_key: config.project_key,
        defaults: config.defaults,
        toolchain_profiles: config.toolchain_profiles,
        policy_profiles: config.policy_profiles,
        code_quality_profiles: config.code_quality_profiles,
        artifact_projection: config.artifact_projection,
        sample_repository: config.sample_repository,
        commands: config.commands
      }
      |> canonical_term()

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  defp canonical_term(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, nested_value} -> {to_string(key), canonical_term(nested_value)} end)
  end

  defp canonical_term(value) when is_list(value), do: Enum.map(value, &canonical_term/1)
  defp canonical_term(value), do: value

  defp redact_finding(finding) do
    Map.update(finding, :details, %{}, &redact_map/1)
  end

  defp redact_map(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      if secret_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact_map(nested_value)}
      end
    end)
  end

  defp redact_map(value) when is_list(value), do: Enum.map(value, &redact_map/1)
  defp redact_map(value), do: value

  defp secret_key?(key) do
    key = key |> to_string() |> String.downcase()
    Enum.any?(@secret_fragments, &String.contains?(key, &1))
  end

  defp normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {key, normalize_map(nested_value)} end)
  end

  defp normalize_map(value) when is_list(value), do: Enum.map(value, &normalize_map/1)
  defp normalize_map(value), do: value

  defp ensure_path(config, []), do: config

  defp ensure_path(config, [key | rest]) do
    child =
      case Map.get(config, key) do
        nested when is_map(nested) -> nested
        _missing_or_scalar -> %{}
      end

    Map.put(config, key, ensure_path(child, rest))
  end

  defp put_path(config, [key], value), do: Map.put(config, key, value)

  defp put_path(config, [key | rest], value) do
    child =
      case Map.get(config, key) do
        nested when is_map(nested) -> nested
        _missing_or_scalar -> %{}
      end

    Map.put(config, key, put_path(child, rest, value))
  end

  defp path_exists?(config, [key]), do: Map.has_key?(config, key)

  defp path_exists?(config, [key | rest]) do
    case Map.fetch(config, key) do
      {:ok, nested} when is_map(nested) -> path_exists?(nested, rest)
      {:ok, _scalar} -> true
      :error -> false
    end
  end

  defp get_path(config, path), do: Enum.reduce_while(path, config, &get_path_part/2)

  defp get_path_part(key, map) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:cont, value}
      :error -> {:halt, nil}
    end
  end

  defp get_path_part(_key, _value), do: {:halt, nil}

  defp finding(code, severity, message, path, line \\ nil, details \\ %{}) do
    %{
      code: code,
      severity: severity,
      message: message,
      path: path,
      line: line,
      matrix_ref: @matrix_ref,
      details: details
    }
  end

  defp error_findings?(findings), do: Enum.any?(findings, &(&1.severity == "error"))
  defp truthy?(value), do: value in [true, "true", "1", 1]
  defp present?(value), do: is_binary(value) and value != ""
end
