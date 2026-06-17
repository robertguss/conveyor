defmodule Conveyor.SandboxRunner do
  @moduledoc """
  Docker-backed workspace adapter for materialize/exec/destroy lifecycle steps.

  Docker is only the execution adapter. Command policy remains owned by
  `Conveyor.ToolExecutor`, and this module records workspace/container facts
  needed by later evidence and reproducibility checks.
  """

  alias Conveyor.Domain.PayloadHelpers
  alias Conveyor.Domain.WorkspaceMaterialization
  alias Conveyor.ToolExecutor

  @adapter_schema "conveyor.sandbox_runner_docker@1"
  @event_schema "conveyor.sandbox_runner_event@1"
  @log_schema "conveyor.sandbox_runner_log@1"
  @matrix_ref "conveyor-quality-ci-evals-vmr.13"
  @reproducibility_ref "conveyor-quality-ci-evals-vmr.11"
  @workspace_path "/workspace"
  @supported_purposes ~w(
    implement
    gate
    baseline
    acceptance_calibration
    canary
    post_integration
  )

  def supported_purposes, do: @supported_purposes

  def materialize(attrs, opts \\ []) when is_map(attrs) and is_list(opts) do
    started_at = timestamp(opts)
    purpose = purpose!(attrs)
    workspace_id = required_string!(attrs, :workspace_id)
    run_attempt_id = required_string!(attrs, :run_attempt_id)
    repo_path = required_string!(attrs, :repo_path)
    base_commit = required_string!(attrs, :base_commit)
    image_ref = required_string!(attrs, :image_ref)
    workspace_root = workspace_root(attrs, workspace_id, opts)
    container_name = container_name(attrs, workspace_id)
    docker = docker_runner(opts)
    git = git_runner(opts)

    with {:ok, _} <- ensure_workspace_parent(workspace_root, opts),
         {:ok, _git_output, _git_exit} <-
           git.(["worktree", "add", "--detach", workspace_root, base_commit],
             cd: repo_path,
             stderr_to_stdout: true
           ),
         {:ok, head_tree_digest} <- head_tree_digest(git, workspace_root, base_commit, opts),
         {:ok, create_output, _create_exit} <-
           docker.(docker_create_args(container_name, workspace_root, image_ref, opts),
             stderr_to_stdout: true
           ),
         container_id <- parse_container_id(create_output, container_name),
         {:ok, _start_output, _start_exit} <-
           docker.(["start", container_id], stderr_to_stdout: true) do
      workspace =
        %{
          "schema_version" => @adapter_schema,
          "adapter" => "docker",
          "purpose" => purpose,
          "workspace_id" => workspace_id,
          "run_attempt_id" => run_attempt_id,
          "repo_path" => repo_path,
          "root_path" => workspace_root,
          "base_commit" => base_commit,
          "head_tree_digest" => head_tree_digest,
          "container_id" => container_id,
          "container_name" => container_name,
          "container_image" => image_ref,
          "container_image_digest" => container_image_digest(attrs, image_ref),
          "workspace_path" => @workspace_path,
          "cleanup_policy" => cleanup_policy(attrs, opts),
          "cleanup_state" => "materialized",
          "materialized_at" => PayloadHelpers.iso8601(started_at)
        }

      {:ok,
       materialized_result(workspace, event("materialize", workspace, "completed", started_at))}
    else
      {:error, output, exit_code} ->
        {:error,
         failure_result(
           "materialize",
           purpose,
           workspace_id,
           output,
           exit_code,
           started_at
         )}

      {:error, reason} ->
        {:error,
         failure_result(
           "materialize",
           purpose,
           workspace_id,
           inspect(reason),
           nil,
           started_at
         )}
    end
  end

  def exec(workspace, command, opts \\ []) when is_map(workspace) and is_list(opts) do
    started_at = timestamp(opts)
    workspace = PayloadHelpers.normalize_map(workspace)
    docker = docker_runner(opts)

    tool_opts =
      opts
      |> Keyword.put(:project_root, workspace["root_path"])
      |> Keyword.put_new(:persist?, false)
      |> Keyword.put_new(:profile, workspace["purpose"])
      |> Keyword.put(:runner, docker_exec_runner(workspace, docker))

    result = ToolExecutor.execute(command, tool_opts)
    {status, payload} = result

    event =
      event("exec", workspace, payload.status, started_at, %{
        "command_ref" => payload.tool_invocation["command_ref"],
        "exit_code" => payload.exit_code,
        "output_sha256" => payload.output_sha256,
        "tool_status" => payload.tool_invocation["tool_status"]
      })

    {status,
     %{
       status: payload.status,
       workspace: Map.put(workspace, "last_exec_status", payload.status),
       tool_result: payload,
       log: lifecycle_log([event])
     }}
  end

  def destroy(workspace, opts \\ []) when is_map(workspace) and is_list(opts) do
    started_at = timestamp(opts)
    workspace = PayloadHelpers.normalize_map(workspace)

    status =
      opts
      |> Keyword.get(:execution_status, workspace["last_exec_status"] || "completed")
      |> to_string()

    cleanup_policy = cleanup_policy(workspace, opts)
    cleanup = cleanup_decision(status, cleanup_policy)
    docker = docker_runner(opts)
    remover = workspace_remover(opts)

    with {:ok, _output, _exit_code} <-
           docker.(["rm", "-f", workspace["container_id"]], stderr_to_stdout: true),
         {:ok, _remove_output} <- maybe_remove_workspace(cleanup, workspace["root_path"], remover) do
      cleaned_workspace =
        workspace
        |> Map.put("cleanup_policy", cleanup_policy)
        |> Map.put("cleanup_state", cleanup.state)
        |> Map.put("destroyed_at", PayloadHelpers.iso8601(started_at))

      event =
        event("destroy", cleaned_workspace, "completed", started_at, %{
          "execution_status" => status,
          "workspace_preserved" => cleanup.preserve_workspace
        })

      {:ok, %{workspace: cleaned_workspace, log: lifecycle_log([event])}}
    else
      {:error, output, exit_code} ->
        {:error,
         failure_result(
           "destroy",
           workspace["purpose"],
           workspace["workspace_id"],
           output,
           exit_code,
           started_at
         )}

      {:error, reason} ->
        {:error,
         failure_result(
           "destroy",
           workspace["purpose"],
           workspace["workspace_id"],
           inspect(reason),
           nil,
           started_at
         )}
    end
  end

  def lifecycle_log(events) when is_list(events) do
    %{
      "schema_version" => @log_schema,
      "matrix_ref" => @matrix_ref,
      "reproducibility_ref" => @reproducibility_ref,
      "adapter" => "docker",
      "events" => Enum.map(events, &PayloadHelpers.normalize_map/1)
    }
  end

  defp materialized_result(workspace, event) do
    %{
      workspace: workspace,
      workspace_materialization: workspace_materialization(workspace),
      workspace_materialization_attrs:
        WorkspaceMaterialization.create_attrs!(workspace_materialization(workspace)),
      log: lifecycle_log([event])
    }
  end

  defp workspace_materialization(workspace) do
    %{
      workspace_id: workspace["workspace_id"],
      run_attempt_id: workspace["run_attempt_id"],
      base_commit: workspace["base_commit"],
      path_digest: PayloadHelpers.sha256_binary(workspace["root_path"]),
      root_path: workspace["root_path"],
      container_image_digest: workspace["container_image_digest"],
      materialized_at: workspace["materialized_at"],
      metadata: %{
        adapter: "docker",
        purpose: workspace["purpose"],
        container_id: workspace["container_id"],
        container_name: workspace["container_name"],
        head_tree_digest: workspace["head_tree_digest"],
        cleanup_state: workspace["cleanup_state"],
        matrix_ref: @matrix_ref,
        reproducibility_ref: @reproducibility_ref
      }
    }
    |> PayloadHelpers.normalize_map()
  end

  defp docker_exec_runner(workspace, docker) do
    fn command_decision, env, _opts ->
      env_args = Enum.flat_map(env, fn {key, value} -> ["--env", "#{key}=#{value}"] end)

      args =
        ["exec", "--workdir", container_cwd(command_decision, workspace)]
        |> Kernel.++(env_args)
        |> Kernel.++([
          workspace["container_id"],
          Map.fetch!(command_decision, :executable)
        ])
        |> Kernel.++(Map.get(command_decision, :argv, []))

      case docker.(args, stderr_to_stdout: true) do
        {:ok, output, exit_code} -> {output, exit_code}
        {:error, output, exit_code} -> {output, exit_code}
      end
    end
  end

  defp docker_create_args(container_name, workspace_root, image_ref, opts) do
    limits = Keyword.get(opts, :limits, %{})

    [
      "create",
      "--name",
      container_name,
      "--network",
      "none",
      "--user",
      Keyword.get(opts, :container_user, "1000:1000"),
      "--security-opt",
      "no-new-privileges",
      "--workdir",
      @workspace_path,
      "--mount",
      "type=bind,src=#{workspace_root},dst=#{@workspace_path},rw",
      "--memory",
      Map.get(limits, "memory", Keyword.get(opts, :memory, "1024m")),
      "--cpus",
      Map.get(limits, "cpus", Keyword.get(opts, :cpus, "2")),
      image_ref,
      "sh",
      "-c",
      "sleep infinity"
    ]
  end

  defp container_cwd(command_decision, workspace) do
    cwd = Map.fetch!(command_decision, :cwd)
    root_path = workspace["root_path"]

    cond do
      cwd == root_path ->
        @workspace_path

      String.starts_with?(cwd, root_path <> "/") ->
        @workspace_path <> String.replace_prefix(cwd, root_path, "")

      true ->
        @workspace_path
    end
  end

  defp head_tree_digest(git, workspace_root, base_commit, opts) do
    resolver = Keyword.get(opts, :head_tree_digest_resolver)

    cond do
      is_function(resolver, 2) ->
        {:ok, resolver.(workspace_root, base_commit)}

      true ->
        case git.(["rev-parse", "HEAD^{tree}"], cd: workspace_root, stderr_to_stdout: true) do
          {:ok, output, 0} -> {:ok, "git-tree:#{String.trim(output)}"}
          {:error, output, exit_code} -> {:error, output, exit_code}
        end
    end
  end

  defp maybe_remove_workspace(%{preserve_workspace: true}, _path, _remover),
    do: {:ok, "preserved"}

  defp maybe_remove_workspace(%{preserve_workspace: false}, path, remover), do: remover.(path)

  defp cleanup_decision("completed", policy) do
    preserve? = truthy?(policy["preserve_successful"]) or truthy?(policy["preserve_always"])

    %{
      preserve_workspace: preserve?,
      state: if(preserve?, do: "preserved_successful_by_policy", else: "destroyed")
    }
  end

  defp cleanup_decision(_status, policy) do
    preserve? = truthy?(policy["preserve_failed"]) or truthy?(policy["preserve_always"])

    %{
      preserve_workspace: preserve?,
      state: if(preserve?, do: "preserved_failed_by_policy", else: "destroyed_after_failure")
    }
  end

  defp event(action, workspace, status, started_at, extra \\ %{}) do
    base =
      %{
        "schema_version" => @event_schema,
        "action" => action,
        "status" => status,
        "purpose" => workspace["purpose"],
        "workspace_id" => workspace["workspace_id"],
        "run_attempt_id" => workspace["run_attempt_id"],
        "container_id" => workspace["container_id"],
        "root_path" => workspace["root_path"],
        "head_tree_digest" => workspace["head_tree_digest"],
        "cleanup_state" => workspace["cleanup_state"],
        "occurred_at" => PayloadHelpers.iso8601(started_at)
      }

    Map.merge(base, extra)
  end

  defp failure_result(action, purpose, workspace_id, output, exit_code, started_at) do
    event =
      event(
        action,
        %{
          "purpose" => purpose,
          "workspace_id" => workspace_id,
          "run_attempt_id" => nil,
          "container_id" => nil,
          "root_path" => nil,
          "head_tree_digest" => nil,
          "cleanup_state" => "failed"
        },
        "failed",
        started_at,
        %{"output" => to_string(output), "exit_code" => exit_code}
      )

    %{
      status: "failed",
      exit_code: exit_code,
      output: to_string(output),
      log: lifecycle_log([event])
    }
  end

  defp ensure_workspace_parent(workspace_root, opts) do
    case Keyword.get(opts, :workspace_parent_creator, &File.mkdir_p/1).(
           Path.dirname(workspace_root)
         ) do
      :ok -> {:ok, "created"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_container_id(output, fallback) do
    output
    |> to_string()
    |> String.trim()
    |> case do
      "" -> fallback
      container_id -> container_id
    end
  end

  defp workspace_root(attrs, workspace_id, opts) do
    case value(attrs, :workspace_root) || Keyword.get(opts, :workspace_root) do
      root when is_binary(root) and root != "" ->
        Path.expand(root)

      _ ->
        opts
        |> Keyword.get(:workspace_base, Path.join(System.tmp_dir!(), "conveyor-sandbox-runner"))
        |> Path.join(workspace_id)
        |> Path.expand()
    end
  end

  defp container_name(attrs, workspace_id) do
    value(attrs, :container_name) || "conveyor-#{safe_id(workspace_id)}"
  end

  defp container_image_digest(attrs, image_ref) do
    value(attrs, :container_image_digest) || PayloadHelpers.sha256_binary(image_ref)
  end

  defp cleanup_policy(attrs, opts) do
    attrs_policy = value(attrs, :cleanup_policy)
    opts_policy = Keyword.get(opts, :cleanup_policy, %{})

    %{"preserve_failed" => false, "preserve_successful" => false, "preserve_always" => false}
    |> Map.merge(normalize_policy(attrs_policy))
    |> Map.merge(normalize_policy(opts_policy))
  end

  defp normalize_policy(policy) when is_map(policy), do: PayloadHelpers.normalize_map(policy)
  defp normalize_policy(_policy), do: %{}

  defp docker_runner(opts), do: Keyword.get(opts, :docker_runner, &run_docker/2)
  defp git_runner(opts), do: Keyword.get(opts, :git_runner, &run_git/2)

  defp workspace_remover(opts) do
    Keyword.get(opts, :workspace_remover, fn path ->
      case File.rm_rf(path) do
        {:ok, removed} -> {:ok, inspect(removed)}
        {:error, reason, _file} -> {:error, reason}
      end
    end)
  end

  defp run_docker(args, opts) do
    if System.find_executable("docker") do
      case System.cmd("docker", args, opts) do
        {output, 0} -> {:ok, output, 0}
        {output, exit_code} -> {:error, output, exit_code}
      end
    else
      {:error, "docker executable not found", nil}
    end
  end

  defp run_git(args, opts) do
    if System.find_executable("git") do
      case System.cmd("git", args, opts) do
        {output, 0} -> {:ok, output, 0}
        {output, exit_code} -> {:error, output, exit_code}
      end
    else
      {:error, "git executable not found", nil}
    end
  end

  defp purpose!(attrs) do
    purpose = required_string!(attrs, :purpose)

    if purpose in @supported_purposes do
      purpose
    else
      raise ArgumentError, "unsupported SandboxRunner purpose: #{purpose}"
    end
  end

  defp required_string!(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) and value != "" -> value
      value when value not in [nil, ""] -> to_string(value)
      _ -> raise ArgumentError, "missing required SandboxRunner field: #{key}"
    end
  end

  defp value(map, key) do
    PayloadHelpers.get(map, key)
  end

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "-")
  end

  defp timestamp(opts), do: Keyword.get(opts, :timestamp, DateTime.utc_now())

  defp truthy?(value) when value in [true, 1, "1", "true", "yes"], do: true
  defp truthy?(_value), do: false
end
