defmodule Conveyor.Doctor do
  @moduledoc """
  Runtime prerequisite doctor for the Phase 0/1 control plane.

  The doctor is intentionally pre-flight only: it checks local prerequisites and
  project contracts without starting the Phoenix application or Oban.
  """

  @matrix_ref "conveyor-quality-ci-evals-vmr.13"
  @schema_version "conveyor.doctor.report@1"
  @failure_exit_code 4
  @required_commands ~w(plan_audit agents_md policy verify)
  @required_agents_sections [
    "NO FILE DELETION",
    "Compiler Checks",
    "MCP Agent Mail",
    "Beads"
  ]
  @secret_patterns [
    {"private_key", ~r/-----BEGIN (RSA |EC |OPENSSH |)?PRIVATE KEY-----/},
    {"api_key_assignment",
     ~r/\b(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|API_KEY|TOKEN)\s*=\s*["']?[^"'\s]+/},
    {"production_database_url", ~r/\bDATABASE_URL\s*=\s*["']?(?:ecto|postgres):\/\/[^"'\s]+/},
    {"aws_secret_assignment", ~r/\bAWS_SECRET_ACCESS_KEY\s*=\s*["']?[^"'\s]+/}
  ]
  @secret_scan_ignored_prefixes [
    "docs/fixtures/",
    "docs/policy/",
    "docs/schemas/",
    "tmp/"
  ]
  @secret_scan_ignored_basenames ["AGENTS.md"]

  def run(opts \\ []) do
    started_at = DateTime.utc_now()
    project_root = Keyword.get(opts, :project_root, File.cwd!())

    config_path =
      Keyword.get(
        opts,
        :config_path,
        Path.join(project_root, Conveyor.ProjectConfig.default_path())
      )

    probe = Keyword.get(opts, :probe, %{})

    {project_config, config_event, project_config_check} = project_config_check(config_path)

    checks =
      [
        runtime_check(probe),
        dependencies_check(project_root, probe),
        postgres_check(probe),
        oban_check(project_config, probe),
        docker_check(probe),
        git_check(project_root, probe),
        pi_image_check(project_config, probe),
        provider_credentials_check(probe),
        codescent_check(probe),
        sample_repo_check(project_root, probe),
        agents_md_check(project_root, probe),
        project_config_check,
        project_commands_check(project_config, probe),
        policy_profiles_check(project_root, project_config, probe),
        artifact_writable_check(project_root, project_config, probe),
        worker_mount_secret_check(project_root, project_config, probe)
      ]

    status = report_status(checks)

    %{
      schema_version: @schema_version,
      matrix_ref: @matrix_ref,
      status: status,
      exit_code: if(status == "fail", do: @failure_exit_code, else: 0),
      generated_at: DateTime.to_iso8601(started_at),
      project_root: Path.expand(project_root),
      config_path: Path.expand(config_path),
      runtime_versions: runtime_versions(),
      project_config_digest: project_config && project_config.digest,
      project_config_status: config_event && config_event.status,
      checks: checks,
      transcript: transcript(checks)
    }
  end

  def transcript(checks) do
    checks
    |> Enum.map(fn check ->
      [
        String.upcase(check.status),
        check.key,
        check.category,
        check.message,
        "NextAction=#{check.next_action}"
      ]
      |> Enum.join(" | ")
    end)
    |> Enum.join("\n")
  end

  def failure_exit_code, do: @failure_exit_code

  defp runtime_check(probe) do
    case probe_result(probe, :runtime) do
      :auto ->
        pass("runtime", "runtime_versions", "Elixir and OTP versions recorded", %{
          elixir: System.version(),
          otp: :erlang.system_info(:otp_release) |> to_string()
        })

      result ->
        check_from_probe("runtime", "runtime_versions", result, "runtime versions are available")
    end
  end

  defp dependencies_check(project_root, probe) do
    case probe_result(probe, :dependencies) do
      :auto ->
        if File.exists?(Path.join(project_root, "mix.lock")) do
          pass("dependencies", "dependencies_available", "mix.lock is present")
        else
          fail(
            "dependencies",
            "missing_gate_blocking_tool",
            "mix.lock is missing",
            "Run mix deps.get."
          )
        end

      result ->
        check_from_probe(
          "dependencies",
          "dependencies_available",
          result,
          "dependencies are available"
        )
    end
  end

  defp postgres_check(probe) do
    case probe_result(probe, :postgres) do
      :auto ->
        host = System.get_env("POSTGRES_HOST", "localhost")
        port = System.get_env("POSTGRES_PORT", "5432") |> String.to_integer()

        case :gen_tcp.connect(String.to_charlist(host), port, [], 1000) do
          {:ok, socket} ->
            :gen_tcp.close(socket)

            pass("postgres", "postgres_reachable", "Postgres accepts TCP connections", %{
              host: host,
              port: port
            })

          {:error, reason} ->
            fail(
              "postgres",
              "missing_postgres",
              "Postgres is not reachable at #{host}:#{port}: #{inspect(reason)}",
              "Start Postgres 16 or set POSTGRES_HOST and POSTGRES_PORT for the local service."
            )
        end

      result ->
        check_from_probe("postgres", "postgres_reachable", result, "Postgres is reachable")
    end
  end

  defp oban_check(project_config, probe) do
    case probe_result(probe, :oban) do
      :auto ->
        cond do
          is_nil(project_config) ->
            fail(
              "oban",
              "missing_project_config",
              "Oban check needs a valid project config",
              "Fix .conveyor/config.toml first."
            )

          Application.get_env(:conveyor, Conveyor.Oban)[:repo] == Conveyor.Repo ->
            pass("oban", "oban_configured", "Oban is configured with Conveyor.Repo")

          true ->
            fail(
              "oban",
              "oban_config_missing",
              "Oban repo configuration is missing",
              "Configure Conveyor.Oban with Conveyor.Repo."
            )
        end

      result ->
        check_from_probe("oban", "oban_configured", result, "Oban is configured")
    end
  end

  defp docker_check(probe) do
    case probe_result(probe, :docker) do
      :auto ->
        Conveyor.Policy.DockerSandbox.evaluate()
        |> docker_sandbox_check()

      {:capabilities, capabilities} ->
        [host_capabilities: capabilities]
        |> Conveyor.Policy.DockerSandbox.evaluate()
        |> docker_sandbox_check()

      {:sandbox_report, report} when is_map(report) ->
        docker_sandbox_check(report)

      result ->
        check_from_probe(
          "docker_rootless",
          "docker_rootless_available",
          result,
          "Docker rootless mode is available"
        )
    end
  end

  defp docker_sandbox_check(%{"status" => "pass"} = report) do
    pass(
      "docker_sandbox",
      "docker_sandbox_constraints_available",
      "Docker sandbox host capabilities satisfy required constraints",
      %{sandbox_report: report}
    )
  end

  defp docker_sandbox_check(%{"status" => "warn"} = report) do
    warn(
      "docker_sandbox",
      "docker_sandbox_constraints_degraded",
      "Docker sandbox host capabilities are available with degraded optional constraints",
      "Review optional Docker security options before running higher-risk stations.",
      %{sandbox_report: report}
    )
  end

  defp docker_sandbox_check(%{"status" => "fail"} = report) do
    fail(
      "docker_sandbox",
      "docker_sandbox_constraints_unavailable",
      "Required Docker sandbox constraints are unavailable",
      "Install or configure Docker sandbox capabilities required by the active policy profile.",
      %{sandbox_report: report}
    )
  end

  defp git_check(project_root, probe) do
    case probe_result(probe, :git) do
      :auto ->
        case System.find_executable("git") do
          nil ->
            fail(
              "git",
              "git_unavailable",
              "Git executable is missing",
              "Install Git before running Conveyor stations."
            )

          git ->
            result =
              System.cmd(
                git,
                [
                  "-c",
                  "safe.directory=#{Path.expand(project_root)}",
                  "-C",
                  project_root,
                  "rev-parse",
                  "--is-inside-work-tree"
                ],
                stderr_to_stdout: true
              )

            case result do
              {output, 0} ->
                if String.trim(output) == "true" do
                  pass("git", "git_available", "Project root is a Git worktree")
                else
                  fail(
                    "git",
                    "git_unavailable",
                    "Git worktree check failed: #{String.trim(output)}",
                    "Run doctor from a Git checkout."
                  )
                end

              {output, _code} ->
                fail(
                  "git",
                  "git_unavailable",
                  "Git worktree check failed: #{String.trim(output)}",
                  "Run doctor from a Git checkout."
                )
            end
        end

      result ->
        check_from_probe("git", "git_available", result, "Git is available")
    end
  end

  defp pi_image_check(project_config, probe) do
    case probe_result(probe, :pi_image) do
      :auto ->
        image = first_toolchain_image(project_config)

        cond do
          is_nil(image) ->
            warn(
              "pi_image",
              "pi_image_not_configured",
              "No toolchain image is configured",
              "Add a toolchain profile image when sandbox execution is enabled."
            )

          System.find_executable("docker") == nil ->
            warn(
              "pi_image",
              "pi_image_not_checked",
              "Docker is unavailable, so the pinned image was not checked",
              "Install Docker before running sandboxed stations."
            )

          true ->
            case System.cmd("docker", ["image", "inspect", image], stderr_to_stdout: true) do
              {_output, 0} ->
                pass("pi_image", "pi_image_available", "Pinned image is present locally", %{
                  image: image
                })

              {_output, _code} ->
                warn(
                  "pi_image",
                  "pi_image_missing",
                  "Pinned image is not present locally",
                  "Pull #{image} before running sandboxed stations.",
                  %{image: image}
                )
            end
        end

      result ->
        check_from_probe("pi_image", "pi_image_available", result, "Pinned image is available")
    end
  end

  defp provider_credentials_check(probe) do
    required? = truthy?(System.get_env("CONVEYOR_PROVIDER_CREDENTIALS_REQUIRED"))

    case probe_result(probe, :provider_credentials) do
      :auto ->
        present? =
          present?(System.get_env("OPENAI_API_KEY")) or
            present?(System.get_env("ANTHROPIC_API_KEY"))

        cond do
          present? ->
            pass(
              "provider_credentials",
              "provider_credentials_present",
              "Optional provider credentials are present"
            )

          required? ->
            fail(
              "provider_credentials",
              "missing_gate_blocking_credential",
              "Provider credentials are required but missing",
              "Set the required provider credentials or disable the gate-blocking provider adapter."
            )

          true ->
            warn(
              "provider_credentials",
              "optional_provider_credentials_missing",
              "Provider credentials are not configured",
              "No action needed for the hermetic tracer; configure credentials only for explicit live-adapter runs."
            )
        end

      result ->
        check_from_probe(
          "provider_credentials",
          "provider_credentials_present",
          result,
          "Provider credentials are configured"
        )
    end
  end

  defp codescent_check(probe) do
    required? = truthy?(System.get_env("CONVEYOR_CODESCENT_REQUIRED"))

    case probe_result(probe, :codescent) do
      :auto ->
        if System.find_executable("codescent") do
          pass("codescent", "codescent_available", "CodeScent adapter is available")
        else
          if required? do
            fail(
              "codescent",
              "missing_gate_blocking_tool",
              "CodeScent is required but missing",
              "Install CodeScent or disable the gate-blocking adapter profile."
            )
          else
            warn(
              "codescent",
              "optional_codescent_missing",
              "CodeScent is not configured",
              "No action needed unless a blocking CodeScent adapter profile is selected."
            )
          end
        end

      result ->
        check_from_probe("codescent", "codescent_available", result, "CodeScent is available")
    end
  end

  defp sample_repo_check(project_root, probe) do
    case probe_result(probe, :sample_repo) do
      :auto ->
        path = Path.join(project_root, "sample_apps/fastapi_tasks")

        case System.find_executable("git") do
          nil ->
            fail(
              "sample_repo",
              "sample_repo_status_unavailable",
              "Git executable is missing",
              "Install Git before checking sample app cleanliness."
            )

          git ->
            case System.cmd(
                   git,
                   [
                     "-c",
                     "safe.directory=#{Path.expand(project_root)}",
                     "-C",
                     project_root,
                     "status",
                     "--short",
                     "--",
                     "sample_apps/fastapi_tasks"
                   ],
                   stderr_to_stdout: true
                 ) do
              {"", 0} ->
                pass("sample_repo", "sample_repo_clean", "Sample repository paths are clean")

              {output, 0} ->
                fail(
                  "sample_repo",
                  "dirty_sample_repo",
                  "Sample repository paths are dirty",
                  "Commit or inspect sample app changes before running the tracer.",
                  %{status: String.trim(output), path: path}
                )

              {output, _code} ->
                fail(
                  "sample_repo",
                  "sample_repo_status_unavailable",
                  "Could not inspect sample repository status: #{String.trim(output)}",
                  "Run doctor from the Conveyor Git checkout."
                )
            end
        end

      result ->
        check_from_probe(
          "sample_repo",
          "sample_repo_clean",
          result,
          "Sample repository paths are clean"
        )
    end
  end

  defp agents_md_check(project_root, probe) do
    case probe_result(probe, :agents_md) do
      :auto ->
        path = Path.join(project_root, "AGENTS.md")

        if File.exists?(path) do
          text = File.read!(path)
          missing = Enum.reject(@required_agents_sections, &String.contains?(text, &1))

          if missing == [] do
            pass(
              "agents_md",
              "agents_md_lint_pass",
              "AGENTS.md contains required local guidance sections"
            )
          else
            fail(
              "agents_md",
              "agents_md_lint_fail",
              "AGENTS.md is missing required sections",
              "Regenerate or update AGENTS.md before running stations.",
              %{missing_sections: missing}
            )
          end
        else
          fail(
            "agents_md",
            "agents_md_lint_fail",
            "AGENTS.md is missing",
            "Generate AGENTS.md before running stations."
          )
        end

      result ->
        check_from_probe("agents_md", "agents_md_lint_pass", result, "AGENTS.md lint passes")
    end
  end

  defp project_config_check(config_path) do
    case Conveyor.ProjectConfig.load(config_path) do
      {:ok, config, event} ->
        {config, event,
         pass("project_config", "project_config_valid", "Project config loads successfully", %{
           digest: config.digest
         })}

      {:error, event} ->
        {nil, event,
         fail(
           "project_config",
           "project_config_invalid",
           "Project config did not load",
           "Fix .conveyor/config.toml findings.",
           %{findings: event.findings}
         )}
    end
  end

  defp project_commands_check(project_config, probe) do
    case probe_result(probe, :project_commands) do
      :auto ->
        missing =
          if project_config do
            Enum.reject(@required_commands, &Map.has_key?(project_config.commands, &1))
          else
            @required_commands
          end

        if missing == [] do
          pass(
            "project_commands",
            "project_commands_available",
            "Required project commands are available"
          )
        else
          fail(
            "project_commands",
            "project_commands_missing",
            "Required project commands are missing",
            "Add missing commands to .conveyor/config.toml.",
            %{missing_commands: missing}
          )
        end

      result ->
        check_from_probe(
          "project_commands",
          "project_commands_available",
          result,
          "Project commands are available"
        )
    end
  end

  defp policy_profiles_check(project_root, project_config, probe) do
    case probe_result(probe, :policy_profiles) do
      :auto ->
        registry_path = Path.join(project_root, "docs/policy/profiles.json")

        cond do
          is_nil(project_config) ->
            fail(
              "policy_profiles",
              "policy_profiles_unavailable",
              "Policy profiles need a valid project config",
              "Fix .conveyor/config.toml first."
            )

          not File.exists?(registry_path) ->
            fail(
              "policy_profiles",
              "policy_profiles_missing",
              "docs/policy/profiles.json is missing",
              "Restore the policy profile registry."
            )

          true ->
            case Jason.decode(File.read!(registry_path)) do
              {:ok, %{"profiles" => profiles}} when is_list(profiles) ->
                configured = project_config.policy_profiles |> Map.keys() |> MapSet.new()
                registry = profiles |> Enum.map(& &1["id"]) |> MapSet.new()
                policy_profile_alignment_check(configured, registry)

              {:ok, %{"profiles" => profiles}} when is_map(profiles) ->
                configured = project_config.policy_profiles |> Map.keys() |> MapSet.new()
                registry = profiles |> Map.keys() |> MapSet.new()
                policy_profile_alignment_check(configured, registry)

              _invalid ->
                fail(
                  "policy_profiles",
                  "policy_profiles_invalid",
                  "Policy registry JSON is invalid",
                  "Fix docs/policy/profiles.json."
                )
            end
        end

      result ->
        check_from_probe(
          "policy_profiles",
          "policy_profiles_aligned",
          result,
          "Policy profiles are aligned"
        )
    end
  end

  defp artifact_writable_check(project_root, project_config, probe) do
    case probe_result(probe, :artifact_writable) do
      :auto ->
        artifact_projection =
          if project_config do
            project_config.artifact_projection || %{}
          else
            %{}
          end

        root = Map.get(artifact_projection, "root", "tmp/conveyor_artifacts")
        root_path = Path.expand(root, project_root)

        with :ok <- File.mkdir_p(root_path),
             :ok <-
               File.write(
                 Path.join(root_path, ".doctor-write-probe"),
                 DateTime.utc_now() |> DateTime.to_iso8601()
               ) do
          pass(
            "artifact_writable",
            "artifact_directory_writable",
            "Artifact projection directory is writable",
            %{path: root_path}
          )
        else
          {:error, reason} ->
            fail(
              "artifact_writable",
              "artifact_directory_not_writable",
              "Artifact projection directory is not writable: #{inspect(reason)}",
              "Fix directory permissions for the configured artifact root.",
              %{path: root_path}
            )
        end

      result ->
        check_from_probe(
          "artifact_writable",
          "artifact_directory_writable",
          result,
          "Artifact directory is writable"
        )
    end
  end

  defp policy_profile_alignment_check(configured, registry) do
    missing = registry |> MapSet.difference(configured) |> MapSet.to_list() |> Enum.sort()

    if missing == [] do
      pass(
        "policy_profiles",
        "policy_profiles_aligned",
        "Project policy profiles align with registry"
      )
    else
      fail(
        "policy_profiles",
        "policy_profiles_mismatch",
        "Project config is missing policy profiles from the registry",
        "Add missing policy profiles to .conveyor/config.toml.",
        %{missing_profiles: missing}
      )
    end
  end

  defp worker_mount_secret_check(project_root, project_config, probe) do
    case probe_result(probe, :worker_mount_secrets) do
      :auto ->
        roots = worker_mount_roots(project_config)
        findings = secret_findings(project_root, roots)

        if findings == [] do
          pass(
            "worker_mount_secrets",
            "worker_mounts_secret_free",
            "Worker mount roots have no production-looking secrets"
          )
        else
          fail(
            "worker_mount_secrets",
            "production_secret_in_worker_mount",
            "Production-looking secrets were found in worker mount roots",
            "Remove or quarantine secret-like files before running workers.",
            %{findings: findings}
          )
        end

      result ->
        check_from_probe(
          "worker_mount_secrets",
          "worker_mounts_secret_free",
          result,
          "Worker mount roots are secret-free"
        )
    end
  end

  defp check_from_probe(key, pass_category, :pass, message), do: pass(key, pass_category, message)

  defp check_from_probe(key, _pass_category, {:pass, message}, _message),
    do: pass(key, "#{key}_pass", message)

  defp check_from_probe(key, _pass_category, {:warn, category, message, next_action}, _message),
    do: warn(key, category, message, next_action)

  defp check_from_probe(key, _pass_category, {:fail, category, message, next_action}, _message),
    do: fail(key, category, message, next_action)

  defp check_from_probe(key, _pass_category, :warn, message),
    do: warn(key, "#{key}_warning", message, "Inspect #{key}.")

  defp check_from_probe(key, _pass_category, :fail, _message),
    do: fail(key, "#{key}_failed", "#{key} check failed", "Inspect #{key}.")

  defp probe_result(probe, key) when is_map(probe), do: Map.get(probe, key, :auto)

  defp pass(key, category, message, evidence \\ %{}) do
    check(key, "pass", category, message, "None.", evidence)
  end

  defp warn(key, category, message, next_action, evidence \\ %{}) do
    check(key, "warn", category, message, next_action, evidence)
  end

  defp fail(key, category, message, next_action, evidence \\ %{}) do
    check(key, "fail", category, message, next_action, evidence)
  end

  defp check(key, status, category, message, next_action, evidence) do
    %{
      key: key,
      status: status,
      category: category,
      message: message,
      next_action: next_action,
      evidence: redact(evidence),
      matrix_ref: @matrix_ref
    }
  end

  defp report_status(checks) do
    cond do
      Enum.any?(checks, &(&1.status == "fail")) -> "fail"
      Enum.any?(checks, &(&1.status == "warn")) -> "warn"
      true -> "pass"
    end
  end

  defp runtime_versions do
    %{
      elixir: System.version(),
      otp: :erlang.system_info(:otp_release) |> to_string()
    }
  end

  defp first_toolchain_image(nil), do: nil

  defp first_toolchain_image(project_config) do
    project_config.toolchain_profiles
    |> Map.values()
    |> Enum.map(& &1["image"])
    |> Enum.find(&present?/1)
  end

  defp worker_mount_roots(nil), do: []

  defp worker_mount_roots(project_config) do
    project_config.commands
    |> Map.values()
    |> Enum.flat_map(&((&1["read_roots"] || []) ++ (&1["write_roots"] || [])))
    |> Enum.uniq()
  end

  defp secret_findings(project_root, roots) do
    roots
    |> Enum.flat_map(fn root -> secret_findings_for_root(project_root, root) end)
    |> Enum.take(20)
  end

  defp secret_findings_for_root(project_root, root) do
    path = Path.expand(root, project_root)

    cond do
      not String.starts_with?(path, Path.expand(project_root)) ->
        [%{path: root, category: "mount_outside_project"}]

      File.regular?(path) ->
        if ignored_secret_scan_path?(project_root, path) do
          []
        else
          secret_findings_for_file(project_root, path)
        end

      File.dir?(path) ->
        path
        |> Path.join("**/*")
        |> Path.wildcard()
        |> Enum.filter(&File.regular?/1)
        |> Enum.reject(&String.contains?(&1, "/.git/"))
        |> Enum.reject(&ignored_secret_scan_path?(project_root, &1))
        |> Enum.flat_map(&secret_findings_for_file(project_root, &1))

      true ->
        []
    end
  end

  defp secret_findings_for_file(project_root, path) do
    case File.read(path) do
      {:ok, contents} ->
        @secret_patterns
        |> Enum.filter(fn {_category, pattern} -> Regex.match?(pattern, contents) end)
        |> Enum.map(fn {category, _pattern} ->
          %{path: Path.relative_to(path, project_root), category: category}
        end)

      {:error, _reason} ->
        []
    end
  end

  defp ignored_secret_scan_path?(project_root, path) do
    relative = Path.relative_to(path, project_root)

    Path.basename(relative) in @secret_scan_ignored_basenames or
      Enum.any?(@secret_scan_ignored_prefixes, &String.starts_with?(relative, &1))
  end

  defp redact(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      if key |> to_string() |> String.downcase() |> secret_key?() do
        {key, "[REDACTED]"}
      else
        {key, redact(nested_value)}
      end
    end)
  end

  defp redact(value) when is_list(value), do: Enum.map(value, &redact/1)
  defp redact(value), do: value

  defp secret_key?(key) do
    Enum.any?(
      ~w(secret token password credential private_key api_key),
      &String.contains?(key, &1)
    )
  end

  defp truthy?(value), do: value in [true, "true", "1", 1]
  defp present?(value), do: is_binary(value) and value != ""
end
