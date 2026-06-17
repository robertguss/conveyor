defmodule Conveyor.Policy.DockerSandbox do
  @moduledoc """
  Docker sandbox defaults and host capability evaluation for station execution.

  Docker is treated as an execution convenience. The enforceable boundary is the
  conductor-owned policy report: defaults, host capabilities, applied
  constraints, and fail-closed findings when required constraints are missing.
  """

  @report_schema "conveyor.docker_sandbox_report@1"
  @defaults_schema "conveyor.docker_sandbox_defaults@1"
  @capabilities_schema "conveyor.docker_host_capabilities@1"
  @constraint_schema "conveyor.docker_sandbox_constraint@1"
  @finding_schema "conveyor.docker_sandbox_finding@1"
  @matrix_ref "conveyor-quality-ci-evals-vmr.13"

  @default_required_constraints ~w(
    non_root_user
    no_privileged
    no_docker_socket
    no_host_home_mount
    read_only_contract_mounts
    workspace_rw
    network_none
    no_new_privileges
    resource_limits
  )

  @capability_keys ~w(
    docker_available
    rootless
    supports_non_root_user
    supports_read_only_mounts
    supports_network_none
    supports_no_new_privileges
    supports_resource_limits
    supports_seccomp
    supports_apparmor
  )

  def default_profile(opts \\ []) do
    required_security_options =
      opts
      |> Keyword.get(:required_security_options, [])
      |> Enum.map(&to_string/1)

    required_constraints =
      @default_required_constraints
      |> Kernel.++(required_security_options)
      |> maybe_require_rootless(opts)
      |> Enum.uniq()

    %{
      "schema_version" => @defaults_schema,
      "profile" => opts |> Keyword.get(:profile, "phase1-default") |> to_string(),
      "runtime" => "docker",
      "rootless" => "preferred",
      "user" => "non-root",
      "privileged" => false,
      "network" => "none",
      "security_options" => ["no-new-privileges", "seccomp", "apparmor"],
      "required_constraints" => required_constraints,
      "forbidden_mounts" => [
        %{"source" => "/var/run/docker.sock", "reason" => "host Docker socket is never mounted"},
        %{"source" => "$HOME", "reason" => "host home directory is never mounted"}
      ],
      "mounts" => [
        %{"source" => "workspace", "target" => "/workspace", "mode" => "rw"},
        %{"source" => "contracts", "target" => "/workspace/contracts", "mode" => "ro"},
        %{"source" => "policies", "target" => "/workspace/docs/policy", "mode" => "ro"},
        %{"source" => ".conveyor", "target" => "/workspace/.conveyor", "mode" => "ro"}
      ],
      "limits" => %{
        "timeout_ms" => Keyword.get(opts, :timeout_ms, 30_000),
        "output_bytes" => Keyword.get(opts, :output_bytes, 1_048_576),
        "memory_mb" => Keyword.get(opts, :memory_mb, 1_024),
        "cpus" => Keyword.get(opts, :cpus, "2")
      }
    }
  end

  def evaluate(opts \\ []) do
    defaults = Keyword.get(opts, :defaults, default_profile(opts))

    capabilities =
      opts
      |> Keyword.get(:host_capabilities, :auto)
      |> host_capabilities()

    constraints = applied_constraints(defaults, capabilities)
    findings = findings(constraints)

    status =
      cond do
        Enum.any?(constraints, &(&1["status"] == "failed")) -> "fail"
        Enum.any?(constraints, &(&1["status"] == "warn")) -> "warn"
        true -> "pass"
      end

    %{
      "schema_version" => @report_schema,
      "matrix_ref" => @matrix_ref,
      "category" => "docker_sandbox",
      "status" => status,
      "profile" => defaults["profile"],
      "host_capabilities" => capabilities,
      "defaults" => defaults,
      "applied_constraints" => constraints,
      "findings" => findings
    }
  end

  def host_capabilities(:auto) do
    case System.find_executable("docker") do
      nil ->
        normalize_capabilities(%{"docker_available" => false})

      _docker ->
        docker_info_capabilities()
    end
  end

  def host_capabilities(capabilities) when is_map(capabilities),
    do: normalize_capabilities(capabilities)

  defp docker_info_capabilities do
    case System.cmd("docker", ["info", "--format", "{{json .SecurityOptions}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        security_options = decode_security_options(output)

        normalize_capabilities(%{
          "docker_available" => true,
          "rootless" => security_option?(security_options, "rootless"),
          "supports_non_root_user" => true,
          "supports_read_only_mounts" => true,
          "supports_network_none" => true,
          "supports_no_new_privileges" => true,
          "supports_resource_limits" => true,
          "supports_seccomp" => security_option?(security_options, "seccomp"),
          "supports_apparmor" => security_option?(security_options, "apparmor")
        })

      {_output, _exit_code} ->
        normalize_capabilities(%{"docker_available" => false})
    end
  end

  defp applied_constraints(defaults, capabilities) do
    required = MapSet.new(defaults["required_constraints"])

    [
      constraint(
        "non_root_user",
        "container user is non-root",
        capabilities["supports_non_root_user"],
        required
      ),
      constraint("rootless", "rootless Docker is preferred", capabilities["rootless"], required),
      constraint("no_privileged", "privileged containers are disabled", true, required),
      constraint("no_docker_socket", "host Docker socket is not mounted", true, required),
      constraint("no_host_home_mount", "host home directory is not mounted", true, required),
      constraint(
        "read_only_contract_mounts",
        "contracts, policies, and .conveyor mounts are read-only",
        read_only_contract_mounts?(defaults) && capabilities["supports_read_only_mounts"],
        required
      ),
      constraint(
        "workspace_rw",
        "workspace is the only read-write project mount",
        workspace_rw?(defaults),
        required
      ),
      constraint(
        "network_none",
        "container network is none by default",
        defaults["network"] == "none" && capabilities["supports_network_none"],
        required
      ),
      constraint(
        "no_new_privileges",
        "no-new-privileges is applied",
        capabilities["supports_no_new_privileges"],
        required
      ),
      constraint(
        "seccomp",
        "seccomp is applied when available",
        capabilities["supports_seccomp"],
        required
      ),
      constraint(
        "apparmor",
        "AppArmor is applied when available",
        capabilities["supports_apparmor"],
        required
      ),
      constraint(
        "resource_limits",
        "time, output, CPU, and memory limits are declared",
        limits_declared?(defaults) && capabilities["supports_resource_limits"],
        required
      )
    ]
  end

  defp constraint(name, message, available?, required) do
    required? = MapSet.member?(required, name)

    status =
      cond do
        available? -> "applied"
        required? -> "failed"
        true -> "warn"
      end

    %{
      "schema_version" => @constraint_schema,
      "constraint" => name,
      "status" => status,
      "required" => required?,
      "message" => message
    }
  end

  defp findings(constraints) do
    constraints
    |> Enum.reject(&(&1["status"] == "applied"))
    |> Enum.map(fn constraint ->
      %{
        "schema_version" => @finding_schema,
        "category" => "docker_sandbox",
        "severity" => if(constraint["status"] == "failed", do: "error", else: "warning"),
        "code" => "#{constraint["constraint"]}_unavailable",
        "message" => constraint["message"],
        "constraint" => constraint["constraint"],
        "required" => constraint["required"],
        "action" =>
          if(constraint["required"], do: "block_profile", else: "record_degraded_sandbox")
      }
    end)
  end

  defp normalize_capabilities(capabilities) do
    normalized = Map.new(capabilities, fn {key, value} -> {to_string(key), value} end)

    capability_values =
      Map.new(@capability_keys, fn key ->
        {key, truthy?(Map.get(normalized, key, false))}
      end)

    Map.put(capability_values, "schema_version", @capabilities_schema)
  end

  defp decode_security_options(output) do
    case Jason.decode(String.trim(output)) do
      {:ok, options} when is_list(options) -> options
      _invalid -> []
    end
  end

  defp security_option?(options, expected) do
    Enum.any?(options, fn option ->
      option
      |> to_string()
      |> String.downcase()
      |> String.contains?(expected)
    end)
  end

  defp read_only_contract_mounts?(defaults) do
    defaults["mounts"]
    |> Enum.filter(&(&1["source"] in ["contracts", "policies", ".conveyor"]))
    |> Enum.all?(&(&1["mode"] == "ro"))
  end

  defp workspace_rw?(defaults) do
    Enum.any?(defaults["mounts"], &(&1["source"] == "workspace" && &1["mode"] == "rw"))
  end

  defp limits_declared?(defaults) do
    limits = defaults["limits"] || %{}
    Enum.all?(["timeout_ms", "output_bytes", "memory_mb", "cpus"], &Map.has_key?(limits, &1))
  end

  defp maybe_require_rootless(required, opts) do
    if Keyword.get(opts, :require_rootless, false) do
      ["rootless" | required]
    else
      required
    end
  end

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when value in [1, "1", "true", "yes", "available"], do: true
  defp truthy?(_value), do: false
end
