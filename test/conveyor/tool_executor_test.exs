defmodule Conveyor.ToolExecutorTest do
  use ExUnit.Case, async: false

  alias Conveyor.Domain.PayloadHelpers
  alias Conveyor.Repo
  alias Conveyor.ToolExecutor

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "runs allowed structured commands and records a ToolInvocation transcript" do
    root = tmp_root("allowed")
    File.mkdir_p!(root)

    assert {:ok, result} =
             ToolExecutor.execute(
               echo_command(),
               base_opts(root, env: %{"SAFE_TOKEN" => "secret-value"})
             )

    payload = result.tool_invocation

    assert result.status == "completed"
    assert payload["schema_version"] == "conveyor.tool_invocation@1"
    assert payload["tool_status"] == "completed"
    assert payload["policy_profile"] == "implement"
    assert payload["command_spec"]["command_id"] == "echo-ok"
    assert payload["command_spec"]["env_keys"] == ["SAFE_TOKEN"]
    assert payload["env_keys"] == ["SAFE_TOKEN"]
    assert payload["network"] == "disabled"
    assert payload["exit_code"] == 0
    assert payload["output_sha256"] == PayloadHelpers.sha256_binary("conveyor-ok\n")
    assert payload["artifact_refs"] == [payload["output_refs"]["combined"]]
    refute inspect(payload) =~ "secret-value"
    assert result.tool_invocation_record.payload["tool_invocation_id"] == payload["tool_invocation_id"]

    assert %{
             "type" => "process_exit",
             "status" => "completed",
             "exit_code" => 0
           } = List.last(payload["transcript"]["events"])
  end

  test "blocks denylisted commands before process execution" do
    root = tmp_root("blocked")
    File.mkdir_p!(root)
    parent = self()

    assert {:error, result} =
             ToolExecutor.execute(
               %{
                 "id" => "dangerous-git",
                 "executable" => "git",
                 "argv" => ["reset", "--hard"],
                 "cwd" => ".",
                 "env_keys" => [],
                 "read_roots" => ["."],
                 "write_roots" => ["."],
                 "network" => "disabled",
                 "timeout_ms" => 30_000
               },
               base_opts(root,
                 executable_resolver: fn "git" -> "/usr/bin/git" end,
                 profiles_doc: default_profiles_doc(),
                 runner: fn _command, _env, _opts ->
                   send(parent, :runner_called)
                   {"should-not-run", 0}
                 end
               )
             )

    refute_received :runner_called
    assert result.status == "blocked"
    assert result.tool_invocation["tool_status"] == "blocked"
    assert result.tool_invocation_record.payload["tool_status"] == "blocked"
    refute Map.has_key?(result.tool_invocation, "exit_code")
    assert result.tool_invocation["policy_decision"]["status"] == "blocked"

    assert Enum.any?(result.tool_invocation["policy_decision"]["findings"], fn finding ->
             finding["code"] == "dangerous_git_blocked" and
               finding["action"] == "block_execution"
           end)

    assert List.last(result.transcript["events"])["type"] == "pre_exec_block"
  end

  test "marks observe-only adapters as capped and does not execute" do
    root = tmp_root("observe-only")
    File.mkdir_p!(root)
    parent = self()

    assert {:error, result} =
             ToolExecutor.execute(
               echo_command(),
               base_opts(root,
                 adapter_mode: :observe_only,
                 runner: fn _command, _env, _opts ->
                   send(parent, :runner_called)
                   {"should-not-run", 0}
                 end
               )
             )

    refute_received :runner_called
    assert result.status == "observe_only_capped"
    assert result.tool_invocation["tool_status"] == "observe_only_capped"
    assert result.tool_invocation_record.payload["tool_status"] == "observe_only_capped"
    assert result.tool_invocation["adapter_mode"] == "observe_only"
    assert result.policy_decision.status == "capped"

    assert Enum.any?(result.policy_decision.findings, fn finding ->
             finding.code == "observe_only_adapter_capped" and
               finding.action == "cap_execution"
           end)

    assert List.last(result.transcript["events"])["type"] == "observe_only_cap"
  end

  test "records nonzero command exits with output digest and transcript" do
    root = tmp_root("failed")
    File.mkdir_p!(root)

    assert {:error, result} =
             ToolExecutor.execute(
               %{
                 "id" => "shell-failure",
                 "executable" => "sh",
                 "argv" => ["-c", "printf failed >&2; exit 7"],
                 "cwd" => ".",
                 "env_keys" => [],
                 "read_roots" => ["."],
                 "write_roots" => [],
                 "network" => "disabled",
                 "timeout_ms" => 30_000
               },
               base_opts(root)
             )

    assert result.status == "failed"
    assert result.exit_code == 7
    assert result.tool_invocation["tool_status"] == "failed"
    assert result.tool_invocation["exit_code"] == 7
    assert result.output_sha256 == PayloadHelpers.sha256_binary("failed")
    assert result.transcript["output"]["bytes"] == 6
    assert List.last(result.transcript["events"])["type"] == "process_exit"
  end

  defp echo_command do
    %{
      "id" => "echo-ok",
      "executable" => "echo",
      "argv" => ["conveyor-ok"],
      "cwd" => ".",
      "env_keys" => ["SAFE_TOKEN"],
      "read_roots" => ["."],
      "write_roots" => [],
      "network" => "disabled",
      "timeout_ms" => 30_000
    }
  end

  defp base_opts(root, overrides \\ []) do
    [
      project_root: root,
      profile: "implement",
      profiles_doc: custom_profiles_doc(),
      run_attempt_id: "run-attempt-tool-executor",
      station_run_id: "station-run-tool-executor",
      agent_session_id: "agent-session-tool-executor"
    ]
    |> Keyword.merge(overrides)
  end

  defp custom_profiles_doc do
    %{
      "schema" => "conveyor.policy_profiles@1",
      "matrix_ref" => "conveyor-quality-ci-evals-vmr.13",
      "denylist_classes" => %{},
      "profiles" => %{
        "implement" => %{
          "autonomy_ceiling" => "L1",
          "allowed_command_families" => ["echo", "sh"],
          "network_policy" => "deny_by_default",
          "denied_classes" => []
        }
      }
    }
  end

  defp default_profiles_doc do
    "docs/policy/profiles.json"
    |> File.read!()
    |> Jason.decode!()
  end

  defp tmp_root(name) do
    Path.join([
      System.tmp_dir!(),
      "conveyor-tool-executor",
      "#{System.unique_integer([:positive])}-#{name}"
    ])
  end
end
