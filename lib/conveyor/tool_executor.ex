defmodule Conveyor.ToolExecutor do
  @moduledoc """
  Policy-mediated command execution boundary for station commands.

  This module is the only Phase 0 wrapper that should launch station commands.
  It normalizes command specs, evaluates the active policy profile, executes only
  allowed structured commands, and returns a `ToolInvocation` payload plus a
  structured transcript for every attempt.
  """

  alias Conveyor.Domain.PayloadHelpers
  alias Conveyor.Domain.ToolInvocation
  alias Conveyor.Policy.CommandSpec
  alias Conveyor.Policy.Engine

  @transcript_schema "conveyor.tool_invocation_transcript@1"
  @output_preview_bytes 4_096

  def execute(command, opts \\ []) when is_list(opts) do
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now())
    started_native_ms = System.monotonic_time(:millisecond)
    profile_name = profile_name(opts)

    case Engine.fetch_profile(profile_name, opts) do
      {:ok, profile, profiles_doc} ->
        command_opts = command_opts(profile, opts)

        case CommandSpec.normalize(command, command_opts) do
          {:ok, command_decision} ->
            evaluate_allowed_command(
              command_decision,
              profile,
              profiles_doc,
              opts,
              started_at,
              started_native_ms
            )

          {:error, command_decision} ->
            policy_decision = Engine.command_block_decision(command_decision, opts)
            blocked_result(command_decision, policy_decision, opts, started_at, started_native_ms)
        end

      {:error, policy_decision} ->
        command_decision = fallback_command_decision(command)
        blocked_result(command_decision, policy_decision, opts, started_at, started_native_ms)
    end
  end

  defp evaluate_allowed_command(
         command_decision,
         profile,
         profiles_doc,
         opts,
         started_at,
         started_native_ms
       ) do
    case Engine.evaluate(command_decision, profile, profiles_doc, opts) do
      {:ok, policy_decision} ->
        if Engine.observe_only?(opts) do
          capped_decision = Engine.observe_only_decision(command_decision, policy_decision, opts)

          observe_only_result(
            command_decision,
            capped_decision,
            opts,
            started_at,
            started_native_ms
          )
        else
          execute_process(command_decision, policy_decision, opts, started_at, started_native_ms)
        end

      {:error, policy_decision} ->
        blocked_result(command_decision, policy_decision, opts, started_at, started_native_ms)
    end
  end

  defp execute_process(command_decision, policy_decision, opts, started_at, started_native_ms) do
    env = env_pairs(Map.get(command_decision, :env_keys, []), Keyword.get(opts, :env, %{}))
    runner = Keyword.get(opts, :runner, &run_system_command/3)

    {output, exit_code} =
      try do
        case runner.(command_decision, env, opts) do
          {:ok, output, exit_code} -> {to_string(output), exit_code}
          {:error, output, exit_code} -> {to_string(output), exit_code}
          {output, exit_code} -> {to_string(output), exit_code}
        end
      rescue
        exception -> {Exception.message(exception), nil}
      end

    status = if exit_code == 0, do: "completed", else: "failed"

    result =
      build_result(command_decision, policy_decision, opts, %{
        status: status,
        output: output,
        exit_code: exit_code,
        started_at: started_at,
        started_native_ms: started_native_ms
      })

    if status == "completed", do: {:ok, result}, else: {:error, result}
  end

  defp blocked_result(command_decision, policy_decision, opts, started_at, started_native_ms) do
    result =
      build_result(command_decision, policy_decision, opts, %{
        status: "blocked",
        output: "",
        exit_code: nil,
        started_at: started_at,
        started_native_ms: started_native_ms
      })

    {:error, result}
  end

  defp observe_only_result(command_decision, policy_decision, opts, started_at, started_native_ms) do
    result =
      build_result(command_decision, policy_decision, opts, %{
        status: "observe_only_capped",
        output: "",
        exit_code: nil,
        started_at: started_at,
        started_native_ms: started_native_ms
      })

    {:error, result}
  end

  defp build_result(command_decision, policy_decision, opts, run) do
    completed_at = DateTime.utc_now()
    duration_ms = max(System.monotonic_time(:millisecond) - run.started_native_ms, 0)
    tool_invocation_id = tool_invocation_id(command_decision, opts)
    output_sha256 = PayloadHelpers.sha256_binary(run.output)
    output_refs = output_refs(tool_invocation_id, run.status, run.output)

    transcript =
      transcript(%{
        tool_invocation_id: tool_invocation_id,
        command_ref: command_ref(command_decision),
        command_decision: command_decision,
        policy_decision: policy_decision,
        status: run.status,
        started_at: run.started_at,
        completed_at: completed_at,
        duration_ms: duration_ms,
        output: run.output,
        output_sha256: output_sha256,
        output_refs: output_refs,
        exit_code: run.exit_code,
        opts: opts
      })

    payload =
      ToolInvocation.build!(%{
        tool_invocation_id: tool_invocation_id,
        run_attempt_id: required_opt!(opts, :run_attempt_id),
        station_run_id: required_opt!(opts, :station_run_id),
        agent_session_id: required_opt!(opts, :agent_session_id),
        command_ref: command_ref(command_decision),
        started_at: run.started_at,
        completed_at: completed_at,
        exit_code: run.exit_code,
        artifact_refs: Map.values(output_refs),
        tool_status: run.status,
        policy_profile: profile_name(opts),
        adapter_mode: adapter_mode(opts),
        command_spec: command_spec(command_decision),
        cwd: Map.get(command_decision, :cwd, Map.get(command_decision, "cwd")),
        env_keys: Map.get(command_decision, :env_keys, Map.get(command_decision, "env_keys", [])),
        network: Map.get(command_decision, :network, Map.get(command_decision, "network")),
        timeout_ms:
          Map.get(command_decision, :timeout_ms, Map.get(command_decision, "timeout_ms")),
        duration_ms: duration_ms,
        output_refs: output_refs,
        output_sha256: output_sha256,
        policy_decision: policy_decision,
        transcript: transcript,
        metadata: %{
          "matrix_ref" => "conveyor-quality-ci-evals-vmr.13",
          "policy_controlled" => true,
          "output_bytes" => byte_size(run.output)
        }
      })

    attrs = ToolInvocation.create_attrs!(payload)
    record = maybe_persist(attrs, opts)

    %{
      status: run.status,
      exit_code: run.exit_code,
      tool_invocation: payload,
      tool_invocation_attrs: attrs,
      tool_invocation_record: record,
      transcript: transcript,
      output_sha256: output_sha256,
      output_refs: output_refs,
      policy_decision: policy_decision
    }
  end

  defp maybe_persist(attrs, opts) do
    if Keyword.get(opts, :persist?, true) do
      case Ash.create(ToolInvocation, attrs, action: :create) do
        {:ok, record} ->
          record

        {:error, error} ->
          raise ArgumentError, "failed to persist ToolInvocation: #{inspect(error)}"
      end
    end
  end

  defp transcript(attrs) do
    %{
      "schema_version" => @transcript_schema,
      "tool_invocation_id" => attrs.tool_invocation_id,
      "command_ref" => attrs.command_ref,
      "status" => attrs.status,
      "policy_profile" => profile_name(attrs.opts),
      "adapter_mode" => adapter_mode(attrs.opts),
      "started_at" => attrs.started_at,
      "completed_at" => attrs.completed_at,
      "duration_ms" => attrs.duration_ms,
      "events" => transcript_events(attrs),
      "output" => %{
        "refs" => attrs.output_refs,
        "sha256" => attrs.output_sha256,
        "bytes" => byte_size(attrs.output),
        "preview" =>
          binary_part(attrs.output, 0, min(byte_size(attrs.output), @output_preview_bytes)),
        "truncated" => byte_size(attrs.output) > @output_preview_bytes
      }
    }
  end

  defp transcript_events(attrs) do
    [
      %{
        "type" => "policy_decision",
        "status" =>
          Map.get(attrs.policy_decision, :status, Map.get(attrs.policy_decision, "status")),
        "command_policy_status" =>
          Map.get(attrs.command_decision, :status, Map.get(attrs.command_decision, "status")),
        "findings_count" => length(Map.get(attrs.policy_decision, :findings, []))
      },
      %{
        "type" => terminal_event_type(attrs.status),
        "status" => attrs.status,
        "exit_code" => attrs.exit_code,
        "output_sha256" => attrs.output_sha256,
        "output_bytes" => byte_size(attrs.output)
      }
    ]
  end

  defp terminal_event_type("completed"), do: "process_exit"
  defp terminal_event_type("failed"), do: "process_exit"
  defp terminal_event_type("blocked"), do: "pre_exec_block"
  defp terminal_event_type("observe_only_capped"), do: "observe_only_cap"

  defp run_system_command(command_decision, env, _opts) do
    System.cmd(
      Map.fetch!(command_decision, :executable_path),
      Map.get(command_decision, :argv, []),
      cd: Map.fetch!(command_decision, :cwd),
      env: env,
      stderr_to_stdout: true
    )
  end

  defp command_opts(profile, opts) do
    [
      project_root: Keyword.get(opts, :project_root, File.cwd!()),
      allowed_families: Engine.allowed_families(profile),
      allow_raw_shell: Keyword.get(opts, :allow_raw_shell, false),
      raw_shell_timeout_ms: Keyword.get(opts, :raw_shell_timeout_ms, 30_000),
      shell_executable: Keyword.get(opts, :shell_executable, "/bin/sh"),
      executable_resolver: Keyword.get(opts, :executable_resolver, &System.find_executable/1)
    ]
  end

  defp command_spec(command_decision) do
    %{
      "command_id" => Map.get(command_decision, :command_id),
      "executable" => Map.get(command_decision, :executable),
      "executable_path" => Map.get(command_decision, :executable_path),
      "executable_family" => Map.get(command_decision, :executable_family),
      "argv" => Map.get(command_decision, :argv, []),
      "cwd" => Map.get(command_decision, :cwd),
      "env_keys" => Map.get(command_decision, :env_keys, []),
      "network" => Map.get(command_decision, :network),
      "timeout_ms" => Map.get(command_decision, :timeout_ms),
      "read_roots" => Map.get(command_decision, :read_roots, []),
      "write_roots" => Map.get(command_decision, :write_roots, [])
    }
  end

  defp fallback_command_decision(command) do
    command_id =
      if is_map(command) do
        Map.get(command, "id") || Map.get(command, :id) || "command"
      else
        "command"
      end

    %{
      schema_version: "conveyor.command_policy_decision@1",
      status: "blocked",
      command_id: command_id,
      executable:
        if(is_map(command), do: Map.get(command, "executable") || Map.get(command, :executable)),
      argv:
        if(is_map(command),
          do: Map.get(command, "argv") || Map.get(command, :argv) || [],
          else: []
        ),
      findings: []
    }
  end

  defp env_pairs(env_keys, env) do
    Enum.flat_map(env_keys, fn key ->
      case PayloadHelpers.get(env, key) do
        nil -> []
        value -> [{key, to_string(value)}]
      end
    end)
  end

  defp output_refs(_tool_invocation_id, status, "")
       when status in ["blocked", "observe_only_capped"],
       do: %{}

  defp output_refs(tool_invocation_id, _status, _output) do
    %{"combined" => "artifact://tool-invocations/#{tool_invocation_id}/combined-output"}
  end

  defp tool_invocation_id(command_decision, opts) do
    Keyword.get(opts, :tool_invocation_id) ||
      "tool-invocation-#{Map.get(command_decision, :command_id, "command")}-#{System.unique_integer([:positive])}"
  end

  defp command_ref(command_decision),
    do: "cmd://#{Map.get(command_decision, :command_id, "command")}"

  defp required_opt!(opts, key) do
    Keyword.fetch!(opts, key)
  rescue
    KeyError -> raise ArgumentError, "missing required ToolExecutor option: #{key}"
  end

  defp profile_name(opts),
    do:
      opts
      |> Keyword.get(:profile, Keyword.get(opts, :policy_profile, "implement"))
      |> to_string()

  defp adapter_mode(opts), do: opts |> Keyword.get(:adapter_mode, "execute") |> to_string()
end
