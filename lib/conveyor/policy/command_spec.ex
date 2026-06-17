defmodule Conveyor.Policy.CommandSpec do
  @moduledoc """
  Normalizes structured command specs before any process launch.

  The module records a deterministic policy decision from conductor-owned input.
  It does not execute commands and it never materializes secret environment values.
  """

  @decision_schema "conveyor.command_policy_decision@1"
  @finding_schema "conveyor.command_policy_finding@1"
  @allowed_network_modes ~w(disabled loopback controlled)

  def normalize(command, opts \\ [])

  def normalize(command, opts) when is_binary(command) do
    project_root = project_root!(opts)

    if Keyword.get(opts, :allow_raw_shell, false) do
      command
      |> shell_command_spec(opts)
      |> normalize_structured(project_root, opts)
    else
      decision =
        base_decision(project_root)
        |> Map.merge(%{
          command_id: "raw_shell",
          original: "raw_shell_string",
          findings: [
            finding(
              "raw_shell_rejected",
              "raw shell strings require explicit allow_raw_shell policy",
              "command",
              %{action: "block_execution"}
            )
          ]
        })
        |> finalize_decision()

      {:error, decision}
    end
  end

  def normalize(command, opts) when is_map(command) do
    opts
    |> project_root!()
    |> then(&normalize_structured(command, &1, opts))
  end

  def normalize(command, opts) do
    project_root = project_root!(opts)

    decision =
      base_decision(project_root)
      |> Map.merge(%{
        command_id: "invalid",
        findings: [
          finding(
            "invalid_command_spec",
            "command spec must be a structured map or explicitly allowed raw shell string",
            "command",
            %{action: "block_execution", actual_type: inspect(command)}
          )
        ]
      })
      |> finalize_decision()

    {:error, decision}
  end

  defp normalize_structured(command, project_root, opts) do
    command = normalize_keys(command)
    command_id = string_field(command, "id", "command")
    executable = Map.get(command, "executable")
    argv = list_field(command, "argv")
    cwd_input = string_field(command, "cwd", ".")
    read_roots = list_field(command, "read_roots")
    write_roots = list_field(command, "write_roots")
    env_keys = list_field(command, "env_keys")
    network = string_field(command, "network", "disabled")
    timeout_ms = Map.get(command, "timeout_ms")

    {cwd, cwd_findings} = normalize_project_path(project_root, project_root, cwd_input, "cwd")

    {read_roots, read_findings} =
      normalize_roots(project_root, cwd || project_root, read_roots, "read_roots")

    {write_roots, write_findings} =
      normalize_roots(project_root, cwd || project_root, write_roots, "write_roots")

    {executable_path, executable_findings} = resolve_executable(executable, opts)
    family = executable_family(executable)

    findings =
      []
      |> add_required_string_finding(command_id, "id", command_id)
      |> add_required_string_finding(executable, "executable", command_id)
      |> add_string_list_finding(argv, "argv", command_id)
      |> add_string_list_finding(env_keys, "env_keys", command_id)
      |> add_string_list_finding(Map.get(command, "read_roots", []), "read_roots", command_id)
      |> add_string_list_finding(Map.get(command, "write_roots", []), "write_roots", command_id)
      |> add_positive_integer_finding(timeout_ms, "timeout_ms", command_id)
      |> add_network_finding(network, command_id)
      |> add_family_finding(family, opts, command_id)
      |> Kernel.++(cwd_findings)
      |> Kernel.++(read_findings)
      |> Kernel.++(write_findings)
      |> Kernel.++(executable_findings)

    decision =
      base_decision(project_root)
      |> Map.merge(%{
        command_id: command_id,
        executable: executable,
        executable_path: executable_path,
        executable_family: family,
        argv: argv,
        cwd: cwd,
        env_keys: env_keys,
        network: network,
        timeout_ms: timeout_ms,
        read_roots: read_roots,
        write_roots: write_roots,
        findings: findings
      })
      |> finalize_decision()

    if decision.status == "allowed", do: {:ok, decision}, else: {:error, decision}
  end

  defp shell_command_spec(command, opts) do
    executable = Keyword.get(opts, :shell_executable, "/bin/sh")

    %{
      "id" => "raw_shell",
      "executable" => executable,
      "argv" => ["-lc", command],
      "cwd" => ".",
      "env_keys" => [],
      "read_roots" => ["."],
      "write_roots" => [],
      "network" => "disabled",
      "timeout_ms" => Keyword.get(opts, :raw_shell_timeout_ms, 30_000)
    }
  end

  defp base_decision(project_root) do
    %{
      schema_version: @decision_schema,
      matrix_ref: "conveyor-quality-ci-evals-vmr.13",
      category: "pre_exec_command_policy",
      status: "blocked",
      project_root: project_root,
      findings: []
    }
  end

  defp finalize_decision(decision) do
    status =
      if Enum.any?(decision.findings, &(&1.severity == "error")) do
        "blocked"
      else
        "allowed"
      end

    Map.put(decision, :status, status)
  end

  defp normalize_project_path(project_root, base, input, field) when is_binary(input) do
    normalized = resolve_path(input, base)

    findings =
      if inside_root?(normalized, project_root) do
        []
      else
        [
          finding(
            "path_outside_project_root",
            "#{field} must resolve inside the project root",
            field,
            %{input: input, normalized_path: normalized, action: "block_execution"}
          )
        ]
      end

    {normalized, findings}
  end

  defp normalize_project_path(_project_root, _base, input, field) do
    {nil,
     [
       finding(
         "invalid_path",
         "#{field} must be a string path",
         field,
         %{input: inspect(input), action: "block_execution"}
       )
     ]}
  end

  defp normalize_roots(project_root, base, roots, field) when is_list(roots) do
    roots
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {root, index}, {normalized_roots, findings} ->
      {path, path_findings} =
        normalize_project_path(project_root, base, root, "#{field}[#{index}]")

      entry =
        if is_binary(path) do
          %{
            input: root,
            path: path,
            access: root_access(field)
          }
        end

      {[entry | normalized_roots], findings ++ path_findings}
    end)
    |> then(fn {roots, findings} -> {Enum.reverse(Enum.reject(roots, &is_nil/1)), findings} end)
  end

  defp normalize_roots(_project_root, _base, roots, field) do
    {[],
     [
       finding(
         "invalid_root_list",
         "#{field} must be a list of string paths",
         field,
         %{input: inspect(roots), action: "block_execution"}
       )
     ]}
  end

  defp resolve_executable(executable, opts) when is_binary(executable) do
    cond do
      String.trim(executable) == "" ->
        {nil, [finding("missing_executable", "executable is required", "executable")]}

      String.contains?(executable, "/") ->
        {Path.expand(executable), []}

      true ->
        resolver = Keyword.get(opts, :executable_resolver, &System.find_executable/1)

        case resolver.(executable) do
          path when is_binary(path) ->
            {Path.expand(path), []}

          _ ->
            {nil,
             [
               finding(
                 "executable_not_found",
                 "executable could not be resolved inside the container",
                 "executable",
                 %{executable: executable, action: "block_execution"}
               )
             ]}
        end
    end
  end

  defp resolve_executable(_executable, _opts) do
    {nil, [finding("missing_executable", "executable is required", "executable")]}
  end

  defp add_required_string_finding(findings, value, field, command_id) do
    if is_binary(value) and String.trim(value) != "" do
      findings
    else
      [
        finding(
          "missing_required_field",
          "#{field} is required",
          "commands.#{command_id}.#{field}",
          %{action: "block_execution"}
        )
        | findings
      ]
    end
  end

  defp add_string_list_finding(findings, values, field, command_id) do
    if is_list(values) and Enum.all?(values, &is_binary/1) do
      findings
    else
      [
        finding(
          "invalid_string_list",
          "#{field} must be a list of strings",
          "commands.#{command_id}.#{field}",
          %{action: "block_execution"}
        )
        | findings
      ]
    end
  end

  defp add_positive_integer_finding(findings, value, field, command_id) do
    if is_integer(value) and value > 0 do
      findings
    else
      [
        finding(
          "invalid_positive_integer",
          "#{field} must be a positive integer",
          "commands.#{command_id}.#{field}",
          %{action: "block_execution"}
        )
        | findings
      ]
    end
  end

  defp add_network_finding(findings, network, command_id) do
    if network in @allowed_network_modes do
      findings
    else
      [
        finding(
          "invalid_network_mode",
          "network must be one of #{Enum.join(@allowed_network_modes, ", ")}",
          "commands.#{command_id}.network",
          %{network: network, action: "block_execution"}
        )
        | findings
      ]
    end
  end

  defp add_family_finding(findings, family, opts, command_id) do
    allowed_families =
      opts
      |> Keyword.get(:allowed_families, [])
      |> Enum.map(&to_string/1)

    if family in allowed_families do
      findings
    else
      [
        finding(
          "disallowed_command_family",
          "command family is not configured for this policy profile",
          "commands.#{command_id}.executable",
          %{family: family, allowed_families: allowed_families, action: "block_execution"}
        )
        | findings
      ]
    end
  end

  defp finding(code, message, path, extra \\ %{}) do
    Map.merge(
      %{
        schema_version: @finding_schema,
        severity: "error",
        code: code,
        message: message,
        path: path,
        category: "pre_exec_command_policy"
      },
      extra
    )
  end

  defp project_root!(opts) do
    opts
    |> Keyword.get(:project_root, File.cwd!())
    |> Path.expand()
    |> resolve_path(".")
  end

  defp resolve_path(path, base) do
    path
    |> Path.expand(base)
    |> real_or_expanded_path()
  end

  defp real_or_expanded_path(path) do
    resolve_symlinks(path, 0)
  end

  defp resolve_symlinks(path, depth) when depth > 20, do: Path.expand(path)

  defp resolve_symlinks(path, depth) do
    case Path.split(Path.expand(path)) do
      [root | segments] -> resolve_segments(root, segments, depth)
      [] -> Path.expand(path)
    end
  end

  defp resolve_segments(path, [], _depth), do: path

  defp resolve_segments(path, [segment | rest], depth) do
    candidate = Path.join(path, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        target = File.read_link!(candidate)

        target_path =
          if Path.type(target) == :absolute do
            target
          else
            Path.expand(target, path)
          end

        resolved_target =
          if rest == [] do
            target_path
          else
            Path.join(target_path, Path.join(rest))
          end

        resolve_symlinks(resolved_target, depth + 1)

      {:ok, _stat} ->
        resolve_segments(candidate, rest, depth)

      {:error, _reason} ->
        Path.join([candidate | rest])
    end
  end

  defp inside_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp root_access("read_roots" <> _suffix), do: "read"
  defp root_access("write_roots" <> _suffix), do: "write"

  defp executable_family(executable) when is_binary(executable) do
    executable
    |> Path.basename()
    |> String.trim()
  end

  defp executable_family(_executable), do: nil

  defp normalize_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp string_field(map, field, default) do
    case Map.get(map, field, default) do
      value when is_binary(value) -> value
      _other -> default
    end
  end

  defp list_field(map, field) do
    case Map.get(map, field, []) do
      values when is_list(values) -> values
      other -> other
    end
  end
end
