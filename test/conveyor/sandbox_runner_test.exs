defmodule Conveyor.SandboxRunnerTest do
  use ExUnit.Case, async: true

  alias Conveyor.Domain.PatchSet
  alias Conveyor.SandboxRunner

  @timestamp ~U[2026-06-17 01:42:00Z]

  test "materializes every supported purpose with Docker workspace facts and structured logs" do
    for purpose <- SandboxRunner.supported_purposes() do
      probe = probe()

      assert {:ok, result} =
               SandboxRunner.materialize(materialize_attrs(purpose),
                 timestamp: @timestamp,
                 docker_runner: docker_runner(probe),
                 git_runner: git_runner(probe),
                 workspace_parent_creator: fn _path -> :ok end,
                 head_tree_digest_resolver: fn _path, commit -> "git-tree:#{commit}-tree" end
               )

      workspace = result.workspace

      assert workspace["purpose"] == purpose
      assert workspace["container_id"] == "container-#{purpose}"
      assert workspace["root_path"] =~ "/#{purpose}"
      assert workspace["head_tree_digest"] == "git-tree:#{purpose}-base-tree"
      assert workspace["cleanup_state"] == "materialized"

      assert result.workspace_materialization["metadata"]["container_id"] ==
               workspace["container_id"]

      assert result.workspace_materialization["metadata"]["head_tree_digest"] ==
               workspace["head_tree_digest"]

      assert result.workspace_materialization_attrs.payload["metadata"]["cleanup_state"] ==
               "materialized"

      assert [materialize_event] = result.log["events"]
      assert materialize_event["schema_version"] == "conveyor.sandbox_runner_event@1"
      assert materialize_event["action"] == "materialize"
      assert materialize_event["status"] == "completed"
      assert materialize_event["purpose"] == purpose
      assert materialize_event["container_id"] == "container-#{purpose}"
      assert materialize_event["head_tree_digest"] == "git-tree:#{purpose}-base-tree"

      assert {:git, ["worktree", "add", "--detach", _workspace_root, base_commit], _opts} =
               List.first(Agent.get(probe, & &1))

      assert base_commit == "#{purpose}-base"

      assert Enum.any?(Agent.get(probe, & &1), fn
               {:docker, ["create" | args], _opts} ->
                 "--network" in args and "none" in args and
                   "--security-opt" in args and
                   "no-new-privileges" in args

               _other ->
                 false
             end)
    end
  end

  test "exec runs normalized ToolExecutor commands through docker exec" do
    probe = probe()
    workspace = workspace("implement", cleanup_policy: %{"preserve_failed" => true})

    assert {:ok, result} =
             SandboxRunner.exec(workspace, echo_command(),
               timestamp: @timestamp,
               docker_runner: docker_runner(probe),
               project_root: workspace["root_path"],
               profile: "implement",
               profiles_doc: profiles_doc(),
               executable_resolver: fn "echo" -> "/bin/echo" end,
               run_attempt_id: "run-attempt-implement",
               station_run_id: "station-run-implement",
               agent_session_id: "agent-session-implement"
             )

    assert result.status == "completed"
    assert result.workspace["last_exec_status"] == "completed"
    assert result.tool_result.tool_invocation["command_spec"]["command_id"] == "echo-ok"
    assert result.tool_result.tool_invocation["tool_status"] == "completed"

    assert Enum.any?(Agent.get(probe, & &1), fn
             {:docker, ["exec", "--workdir", "/workspace", "container-implement", "echo", "ok"],
              _opts} ->
               true

             _other ->
               false
           end)

    assert [exec_event] = result.log["events"]
    assert exec_event["action"] == "exec"
    assert exec_event["status"] == "completed"
    assert exec_event["tool_status"] == "completed"
    assert exec_event["output_sha256"] == result.tool_result.output_sha256
  end

  test "apply_patch verifies PatchSet against a clean gate workspace" do
    probe = probe()
    diff_text = sample_diff()

    patch_set =
      PatchSet.capture!(%{
        patch_set_id: "patch-set-gate-001",
        run_attempt_id: "run-attempt-gate",
        station_run_id: "station-run-gate",
        base_commit: "gate-base",
        diff_text: diff_text,
        generated_at: @timestamp
      })

    assert {:ok, result} =
             SandboxRunner.apply_patch(workspace("gate"), patch_set,
               timestamp: @timestamp,
               git_runner: patch_apply_git_runner(probe),
               diff_text: diff_text
             )

    assert result.status == "applied"
    assert result.applies_cleanly == true
    assert result.patch_set["patch_status"] == "applied_to_clean_gate_workspace"
    assert result.patch_set["applies_cleanly"] == true
    assert result.patch_set["head_tree_digest"] == "git-tree:gate-base-tree"
    assert result.patch_set_summary.applies_cleanly == true
    assert result.patch_set_summary.head_tree_digest == "git-tree:gate-base-tree"

    assert %{
             "schema_version" => "conveyor.patch_set_apply_log@1",
             "category" => "patch_set_apply",
             "matrix_ref" => "conveyor-quality-ci-evals-vmr.13",
             "status" => "applied",
             "patch_set_id" => "patch-set-gate-001",
             "workspace_id" => "workspace-gate",
             "workspace_purpose" => "gate",
             "base_commit" => "gate-base",
             "head_tree_digest" => "git-tree:gate-base-tree",
             "diff_sha256" => diff_sha256,
             "applies_cleanly" => true
           } = result.log

    assert diff_sha256 == patch_set["diff_sha256"]

    assert [
             {:git, ["status", "--porcelain"], _status_opts},
             {:git, ["apply", "--check", "-"], check_opts},
             {:git, ["apply", "-"], apply_opts}
           ] = Agent.get(probe, & &1)

    assert check_opts[:input] == diff_text
    assert apply_opts[:input] == diff_text
  end

  test "apply_patch rejects dirty gate workspaces as evidence" do
    probe = probe()
    diff_text = sample_diff()

    patch_set =
      PatchSet.capture!(%{
        patch_set_id: "patch-set-dirty-001",
        run_attempt_id: "run-attempt-gate",
        station_run_id: "station-run-gate",
        base_commit: "gate-base",
        diff_text: diff_text,
        generated_at: @timestamp
      })

    assert {:error,
            %{
              schema_version: "conveyor.patch_set_apply_finding@1",
              category: "dirty_gate_workspace_not_evidence",
              action: "rematerialize_clean_gate_workspace",
              workspace_id: "workspace-gate",
              workspace_purpose: "gate",
              head_tree_digest: "git-tree:gate-base-tree"
            }} =
             SandboxRunner.apply_patch(workspace("gate"), patch_set,
               timestamp: @timestamp,
               git_runner: patch_apply_git_runner(probe, dirty_status: " M lib/conveyor.ex\n"),
               diff_text: diff_text
             )

    assert [{:git, ["status", "--porcelain"], _status_opts}] = Agent.get(probe, & &1)
  end

  test "destroy removes successful workspaces and preserves failed workspaces only when policy allows" do
    success_probe = probe()
    success_removals = probe()

    assert {:ok, success} =
             SandboxRunner.destroy(workspace("gate"),
               timestamp: @timestamp,
               docker_runner: docker_runner(success_probe),
               workspace_remover: remover(success_removals),
               execution_status: "completed"
             )

    assert success.workspace["cleanup_state"] == "destroyed"
    assert Agent.get(success_removals, & &1) == ["/tmp/conveyor-sandbox-test/gate"]

    preserve_probe = probe()
    preserve_removals = probe()

    assert {:ok, preserved} =
             SandboxRunner.destroy(
               workspace("canary", cleanup_policy: %{"preserve_failed" => true}),
               timestamp: @timestamp,
               docker_runner: docker_runner(preserve_probe),
               workspace_remover: remover(preserve_removals),
               execution_status: "failed"
             )

    assert preserved.workspace["cleanup_state"] == "preserved_failed_by_policy"
    assert Agent.get(preserve_removals, & &1) == []

    failed_probe = probe()
    failed_removals = probe()

    assert {:ok, failed_cleanup} =
             SandboxRunner.destroy(workspace("baseline"),
               timestamp: @timestamp,
               docker_runner: docker_runner(failed_probe),
               workspace_remover: remover(failed_removals),
               execution_status: "failed"
             )

    assert failed_cleanup.workspace["cleanup_state"] == "destroyed_after_failure"
    assert Agent.get(failed_removals, & &1) == ["/tmp/conveyor-sandbox-test/baseline"]

    assert Enum.all?([success, preserved, failed_cleanup], fn result ->
             [event] = result.log["events"]
             event["action"] == "destroy" and event["container_id"] =~ "container-"
           end)
  end

  defp materialize_attrs(purpose) do
    %{
      purpose: purpose,
      workspace_id: "workspace-#{purpose}",
      run_attempt_id: "run-attempt-#{purpose}",
      repo_path: "/repo/conveyor",
      base_commit: "#{purpose}-base",
      image_ref: "conveyor/toolchain:#{purpose}",
      container_image_digest: "sha256:image-#{purpose}",
      workspace_root: "/tmp/conveyor-sandbox-test/#{purpose}",
      cleanup_policy: %{"preserve_failed" => true}
    }
  end

  defp workspace(purpose, overrides \\ []) do
    %{
      "schema_version" => "conveyor.sandbox_runner_docker@1",
      "adapter" => "docker",
      "purpose" => purpose,
      "workspace_id" => "workspace-#{purpose}",
      "run_attempt_id" => "run-attempt-#{purpose}",
      "root_path" => "/tmp/conveyor-sandbox-test/#{purpose}",
      "base_commit" => "#{purpose}-base",
      "head_tree_digest" => "git-tree:#{purpose}-base-tree",
      "container_id" => "container-#{purpose}",
      "container_name" => "conveyor-workspace-#{purpose}",
      "container_image" => "conveyor/toolchain:#{purpose}",
      "container_image_digest" => "sha256:image-#{purpose}",
      "workspace_path" => "/workspace",
      "cleanup_policy" => %{
        "preserve_failed" => false,
        "preserve_successful" => false,
        "preserve_always" => false
      },
      "cleanup_state" => "materialized",
      "materialized_at" => DateTime.to_iso8601(@timestamp)
    }
    |> Map.merge(Map.new(overrides, fn {key, value} -> {to_string(key), value} end))
  end

  defp echo_command do
    %{
      "id" => "echo-ok",
      "executable" => "echo",
      "argv" => ["ok"],
      "cwd" => ".",
      "env_keys" => [],
      "read_roots" => ["."],
      "write_roots" => [],
      "network" => "disabled",
      "timeout_ms" => 30_000
    }
  end

  defp docker_runner(probe) do
    fn
      ["create" | _rest] = args, opts ->
        record(probe, {:docker, args, opts})

        purpose =
          args
          |> Enum.find(&String.starts_with?(&1, "conveyor/toolchain:"))
          |> String.split(":")
          |> List.last()

        {:ok, "container-#{purpose}\n", 0}

      ["exec" | _rest] = args, opts ->
        record(probe, {:docker, args, opts})
        {:ok, "ok\n", 0}

      args, opts ->
        record(probe, {:docker, args, opts})
        {:ok, "done\n", 0}
    end
  end

  defp git_runner(probe) do
    fn args, opts ->
      record(probe, {:git, args, opts})
      {:ok, "git-ok\n", 0}
    end
  end

  defp patch_apply_git_runner(probe, opts \\ []) do
    dirty_status = Keyword.get(opts, :dirty_status, "")

    fn
      ["status", "--porcelain"] = args, opts ->
        record(probe, {:git, args, opts})
        {:ok, dirty_status, 0}

      ["apply" | _rest] = args, opts ->
        record(probe, {:git, args, opts})
        {:ok, "patch-ok\n", 0}
    end
  end

  defp remover(probe) do
    fn path ->
      record(probe, path)
      {:ok, path}
    end
  end

  defp probe do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    agent
  end

  defp record(probe, entry) do
    Agent.update(probe, &(&1 ++ [entry]))
  end

  defp profiles_doc do
    %{
      "schema" => "conveyor.policy_profiles@1",
      "matrix_ref" => "conveyor-quality-ci-evals-vmr.13",
      "denylist_classes" => %{},
      "profiles" => %{
        "implement" => %{
          "autonomy_ceiling" => "L1",
          "allowed_command_families" => ["echo"],
          "network_policy" => "deny_by_default",
          "denied_classes" => []
        }
      }
    }
  end

  defp sample_diff do
    """
    diff --git a/lib/conveyor/example.ex b/lib/conveyor/example.ex
    index 1111111..2222222 100644
    --- a/lib/conveyor/example.ex
    +++ b/lib/conveyor/example.ex
    @@ -1 +1,2 @@
    -old line
    +new line
    +another line
    """
  end
end
