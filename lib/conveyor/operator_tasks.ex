defmodule Conveyor.OperatorTasks do
  @moduledoc """
  Registry and shared runner for Phase 0/1 operator-facing Mix tasks.

  The early operator surface must be scriptable before the underlying stations
  are fully implemented. Skeleton tasks therefore emit deterministic smoke
  results, document their service boundary, and never contact live providers.
  """

  @matrix_ref "conveyor-quality-ci-evals-vmr.13"

  @command_specs [
    %{
      id: "init",
      task: "conveyor.init",
      task_module: "Mix.Tasks.Conveyor.Init",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Prepare Conveyor project bootstrap inputs",
      description: "Validate the intended project bootstrap boundary before files are written.",
      status: "deferred",
      exit_code: 0,
      next_actions: ["Implement bootstrap writes in conveyor-phase0-foundations-hsh.4."]
    },
    %{
      id: "doctor",
      task: "conveyor.doctor",
      task_module: "Mix.Tasks.Conveyor.Doctor",
      service_module: "Conveyor.Doctor",
      shortdoc: "Check Conveyor runtime prerequisites",
      description: "Run local prerequisite checks and write structured operator evidence.",
      status: "implemented",
      exit_code: 0,
      next_actions: ["Run mix conveyor.doctor --json for the full local doctor report."]
    },
    %{
      id: "plan_audit",
      task: "conveyor.plan_audit",
      task_module: "Mix.Tasks.Conveyor.PlanAudit",
      service_module: "Conveyor.PlanAudit",
      shortdoc: "Audit an imported plan without provider access",
      description:
        "Expose the plan-audit station contract for deterministic operator smoke tests.",
      status: "implemented",
      exit_code: 0,
      next_actions: [
        "Run mix conveyor.plan_audit PATH --output tmp/plan_audit.json for a full audit."
      ]
    },
    %{
      id: "seed_sample",
      task: "conveyor.seed_sample",
      task_module: "Mix.Tasks.Conveyor.SeedSample",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Prepare sample app inputs for demos",
      description: "Expose a provider-free sample seeding command for onboarding flows.",
      status: "deferred",
      exit_code: 0,
      next_actions: ["Connect to sample repository bootstrap logic in the demo/onboarding bead."]
    },
    %{
      id: "demo",
      task: "conveyor.demo",
      task_module: "Mix.Tasks.Conveyor.Demo",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Run the deterministic Conveyor demo shell",
      description: "Declare the demo command contract without starting live stations.",
      status: "deferred",
      exit_code: 0,
      next_actions: [
        "Implement the deterministic demo flow in conveyor-operator-ui-reporting-auc.3."
      ]
    },
    %{
      id: "show",
      task: "conveyor.show",
      task_module: "Mix.Tasks.Conveyor.Show",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Show Conveyor run and project state",
      description: "Expose read-only reporting semantics for future run state views.",
      status: "deferred",
      exit_code: 0,
      next_actions: ["Wire to persisted run/project state after the reporting model lands."]
    },
    %{
      id: "run_slice",
      task: "conveyor.run_slice",
      task_module: "Mix.Tasks.Conveyor.RunSlice",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Start a bounded Conveyor run slice",
      description: "Declare run-slice invocation semantics without enqueueing Oban work.",
      status: "deferred",
      exit_code: 0,
      next_actions: [
        "Connect to RunSlice orchestration after conveyor-phase0-domain-state-9oy.10."
      ]
    },
    %{
      id: "verify",
      task: "conveyor.verify",
      task_module: "Mix.Tasks.Conveyor.Verify",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Verify recorded Conveyor evidence",
      description:
        "Expose verification command output without invoking external quality providers.",
      status: "deferred",
      exit_code: 0,
      next_actions: ["Connect to verification composition after run bundle schemas stabilize."]
    },
    %{
      id: "gate_canary",
      task: "conveyor.gate_canary",
      task_module: "Mix.Tasks.Conveyor.GateCanary",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Run gate-policy canary checks",
      description: "Declare canary gate semantics without contacting live review providers.",
      status: "deferred",
      exit_code: 0,
      next_actions: ["Connect to observed risk and gate review policy once dcv.3 lands."]
    },
    %{
      id: "report",
      task: "conveyor.report",
      task_module: "Mix.Tasks.Conveyor.Report",
      service_module: "Conveyor.OperatorTasks.Report",
      shortdoc: "Render a Conveyor operator report",
      description: "Regenerate canonical operator report artifacts from stored artifact records.",
      status: "implemented",
      exit_code: 0,
      next_actions: [
        "Run mix conveyor.report --artifact-manifest PATH --root PATH to regenerate a bundle."
      ]
    },
    %{
      id: "replay",
      task: "conveyor.replay",
      task_module: "Mix.Tasks.Conveyor.Replay",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Replay Conveyor evidence deterministically",
      description: "Declare replay semantics without reading live provider state.",
      status: "deferred",
      exit_code: 0,
      next_actions: ["Connect to artifact replay once canonical run bundles are implemented."]
    },
    %{
      id: "contract_diff",
      task: "conveyor.contract_diff",
      task_module: "Mix.Tasks.Conveyor.ContractDiff",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Diff Conveyor contracts and schemas",
      description: "Expose contract-diff command semantics for future schema/report comparisons.",
      status: "deferred",
      exit_code: 0,
      next_actions: [
        "Wire to schema and contract comparison services after contract locks mature."
      ]
    },
    %{
      id: "ci",
      task: "conveyor.ci",
      task_module: "Mix.Tasks.Conveyor.Ci",
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Run the Conveyor operator CI shell",
      description: "Declare the CI task contract without requiring network or live providers.",
      status: "deferred",
      exit_code: 0,
      next_actions: ["Connect to project verification lanes after command orchestration lands."]
    }
  ]

  def command_specs do
    Enum.map(@command_specs, &normalize_spec/1)
  end

  def command_ids do
    Enum.map(command_specs(), & &1.id)
  end

  def spec!(id) do
    normalized_id = normalize_id(id)

    command_specs()
    |> Enum.find(&(&1.id == normalized_id))
    |> case do
      nil -> raise ArgumentError, "unknown Conveyor operator command: #{normalized_id}"
      spec -> spec
    end
  end

  def smoke_result(id, opts \\ []) do
    spec = spec!(id)

    spec.service_module
    |> service_module!()
    |> apply(:run, [spec, opts])
  end

  def shortdoc!(id), do: spec!(id).shortdoc

  def help!("report") do
    "report"
    |> spec!()
    |> Conveyor.OperatorTasks.Report.help()
  end

  def help!(id) do
    spec = spec!(id)

    """
    #{spec.shortdoc}

        mix #{spec.task} --json
        mix #{spec.task} --output tmp/conveyor_operator/#{spec.id}.json

    #{spec.description}

    This Phase 0/1 operator shell is deterministic and provider-free. It emits
    a structured smoke result with stable exit-code metadata and does not
    contact live providers.

    Options:
      --json         Write the smoke result to stdout as JSON.
      --output PATH  Write the smoke result JSON to PATH.
      --help         Print this help text.
    """
  end

  def run_mix_task!("report", args) when is_list(args) do
    "report"
    |> spec!()
    |> Conveyor.OperatorTasks.Report.run_mix_task!(args)
  end

  def run_mix_task!(id, args) when is_list(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [json: :boolean, output: :string, help: :boolean]
      )

    cond do
      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      argv != [] ->
        Mix.raise("unexpected arguments: #{inspect(argv)}")

      Keyword.get(opts, :help, false) ->
        Mix.shell().info(help!(id))

      true ->
        result = smoke_result(id)

        opts
        |> Keyword.get(:output)
        |> maybe_write_json!(result)

        if Keyword.get(opts, :json, false) do
          Mix.shell().info(encode_json(result))
        else
          Mix.shell().info(render_human(result))
        end

        exit_code = result_exit_code(result)

        if exit_code != 0 do
          System.halt(exit_code)
        end
    end
  end

  def result_exit_code(result), do: Map.fetch!(result, :exit_code)

  def render_human(result) when is_map(result) do
    [
      "#{result.task}: #{result.status}",
      "exit_code: #{result.exit_code}",
      "json_capable: #{result.json_capable}",
      "live_provider_required: #{result.live_provider_required}",
      "service_module: #{result.service_module}"
    ]
    |> Enum.join("\n")
  end

  def encode_json(payload), do: Jason.encode!(payload, pretty: true) <> "\n"

  defp maybe_write_json!(nil, _result), do: :ok

  defp maybe_write_json!(path, result) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, encode_json(result))
  end

  defp normalize_spec(spec) do
    spec
    |> Map.put(:json_capable, true)
    |> Map.put(:live_provider_required, false)
    |> Map.put(:provider_requirements, [])
    |> Map.put(:matrix_ref, @matrix_ref)
  end

  defp service_module!("Conveyor.Doctor"), do: Conveyor.OperatorTasks.Deferred
  defp service_module!("Conveyor.PlanAudit"), do: Conveyor.OperatorTasks.Deferred
  defp service_module!("Conveyor.OperatorTasks.Report"), do: Conveyor.OperatorTasks.Report
  defp service_module!("Conveyor.OperatorTasks.Deferred"), do: Conveyor.OperatorTasks.Deferred

  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
end

defmodule Conveyor.OperatorTasks.Report do
  @moduledoc """
  Provider-free service behind `mix conveyor.report`.

  The service projects stored artifact records through the canonical artifact
  projector. Projection is intentionally delegated so digest verification,
  report generation, secret quarantine, and RunBundle root calculation stay in
  one implementation.
  """

  alias Conveyor.Artifacts.Projector.LocalDisk
  alias Conveyor.OperatorTasks.Deferred

  @schema_version "conveyor.report_regeneration_log@1"
  @finding_schema "conveyor.report_regeneration_finding@1"
  @matrix_ref "conveyor-quality-ci-evals-vmr.13"
  @harness_ref "conveyor-quality-ci-evals-vmr.14"
  @command "report"
  @task "conveyor.report"

  @fixed_artifact_keys [
    :schema_version,
    :projection_schema_version,
    :artifact_role,
    :artifact_key,
    :projection_path,
    :content_type,
    :sensitivity,
    :quarantined,
    :sha256,
    :sha256_hex,
    :raw_sha256,
    :raw_sha256_hex,
    :redacted_sha256,
    :redacted_sha256_hex,
    :size_bytes,
    :blob_path,
    :redacted_blob_path,
    :redaction_report,
    :secret_findings,
    :ledger
  ]

  def run(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    if regeneration_opts?(opts) do
      opts
      |> Map.new()
      |> Map.put_new(:run_id, spec[:run_id])
      |> regenerate_result()
    else
      Deferred.run(spec, opts)
    end
  end

  def regenerate(attrs) when is_map(attrs) do
    with {:ok, backend} <- backend(attrs),
         {:ok, run_id} <- required_string(attrs, :run_id),
         {:ok, bundle_id} <- required_string(attrs, :bundle_id),
         {:ok, artifacts} <- stored_artifacts(attrs),
         {:ok, projection} <-
           LocalDisk.project_run(
             backend,
             attrs
             |> projection_attrs(run_id, bundle_id, artifacts)
           ) do
      {:ok, regeneration_log(projection, artifacts)}
    else
      {:error, finding} -> {:error, annotate_finding(finding)}
    end
  end

  def help(spec) do
    """
    #{spec.shortdoc}

        mix #{spec.task} --json
        mix #{spec.task} --output tmp/conveyor_operator/#{spec.id}.json
        mix #{spec.task} --artifact-manifest tmp/conveyor_operator/artifacts.json --root .

    #{spec.description}

    This Phase 0/1 operator shell is deterministic and provider-free. Without
    an artifact manifest it emits the standard smoke result. With
    --artifact-manifest it regenerates report artifacts from stored artifact
    records and verifies blob digests before writing projected files. It does
    not contact live providers.

    Options:
      --json                    Write the result to stdout as JSON.
      --output PATH             Write the result JSON to PATH.
      --artifact-manifest PATH  Read stored artifact records from JSON.
      --root PATH               Projection root for .conveyor output.
      --run-id ID               Override the manifest run_id.
      --bundle-id ID            Override the manifest bundle_id.
      --help                    Print this help text.
    """
  end

  def run_mix_task!(spec, args) when is_map(spec) and is_list(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          output: :string,
          help: :boolean,
          artifact_manifest: :string,
          root: :string,
          run_id: :string,
          bundle_id: :string
        ]
      )

    cond do
      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      argv != [] ->
        Mix.raise("unexpected arguments: #{inspect(argv)}")

      Keyword.get(opts, :help, false) ->
        Mix.shell().info(help(spec))

      Keyword.get(opts, :artifact_manifest) in [nil, ""] ->
        result = Deferred.run(spec)
        emit_result!(result, opts)

      true ->
        result =
          opts
          |> manifest_attrs!()
          |> regenerate_result()

        emit_result!(result, opts)
    end
  end

  defp regenerate_result(attrs) do
    case regenerate(attrs) do
      {:ok, log} -> log
      {:error, finding} -> Map.put_new(finding, :exit_code, 1)
    end
  end

  defp regeneration_opts?(opts) do
    Keyword.has_key?(opts, :artifacts) or Keyword.has_key?(opts, :artifact_manifest) or
      Keyword.has_key?(opts, :root)
  end

  defp manifest_attrs!(opts) do
    path = Keyword.fetch!(opts, :artifact_manifest)

    attrs =
      path
      |> File.read!()
      |> Jason.decode!()

    attrs
    |> put_cli_override(opts, :root)
    |> put_cli_override(opts, :run_id)
    |> put_cli_override(opts, :bundle_id)
  end

  defp projection_attrs(attrs, run_id, bundle_id, artifacts) do
    %{
      run_id: run_id,
      bundle_id: bundle_id,
      artifacts: artifacts,
      policy: Map.get(attrs, :policy, Map.get(attrs, "policy", %{}))
    }
    |> maybe_put(:created_at, Map.get(attrs, :created_at, Map.get(attrs, "created_at")))
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp put_cli_override(attrs, opts, key) do
    case Keyword.get(opts, key) do
      nil -> attrs
      value -> Map.put(attrs, key, value)
    end
  end

  defp emit_result!(result, opts) do
    opts
    |> Keyword.get(:output)
    |> maybe_write_json!(result)

    if Keyword.get(opts, :json, false) do
      Mix.shell().info(Conveyor.OperatorTasks.encode_json(result))
    else
      Mix.shell().info(render_human(result))
    end

    exit_code = Map.get(result, :exit_code, 0)

    if exit_code != 0 do
      System.halt(exit_code)
    end
  end

  defp maybe_write_json!(nil, _result), do: :ok

  defp maybe_write_json!(path, result) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Conveyor.OperatorTasks.encode_json(result))
  end

  defp render_human(%{schema_version: @schema_version} = result) do
    [
      "#{@task}: #{result.status}",
      "exit_code: #{result.exit_code}",
      "bundle_root_sha256: #{result.bundle_root_sha256}",
      "manifest_path: #{result.manifest_path}",
      "run_bundle_path: #{result.run_bundle_path}"
    ]
    |> Enum.join("\n")
  end

  defp render_human(%{schema_version: @finding_schema} = finding) do
    [
      "#{@task}: blocked",
      "exit_code: #{Map.get(finding, :exit_code, 1)}",
      "category: #{finding.category}",
      "action: #{finding.action}"
    ]
    |> Enum.join("\n")
  end

  defp render_human(result), do: Conveyor.OperatorTasks.render_human(result)

  defp backend(attrs) do
    cond do
      match?(%LocalDisk{}, Map.get(attrs, :backend)) ->
        {:ok, Map.fetch!(attrs, :backend)}

      match?(%LocalDisk{}, Map.get(attrs, "backend")) ->
        {:ok, Map.fetch!(attrs, "backend")}

      is_binary(Map.get(attrs, :root)) ->
        {:ok, LocalDisk.new(root: Map.fetch!(attrs, :root))}

      is_binary(Map.get(attrs, "root")) ->
        {:ok, LocalDisk.new(root: Map.fetch!(attrs, "root"))}

      true ->
        {:error, missing_input_finding(:root, "Provide :backend or :root for report projection.")}
    end
  end

  defp required_string(attrs, key) do
    value = Map.get(attrs, key, Map.get(attrs, to_string(key)))

    if is_binary(value) and value != "" do
      {:ok, value}
    else
      {:error, missing_input_finding(key, "Provide #{key} for report regeneration.")}
    end
  end

  defp stored_artifacts(attrs) do
    case Map.get(attrs, :artifacts, Map.get(attrs, "artifacts")) do
      artifacts when is_list(artifacts) and artifacts != [] ->
        normalize_artifact_records(artifacts)

      _ ->
        {:error,
         %{
           schema_version: @finding_schema,
           category: "report_regeneration_missing_artifacts",
           severity: "error",
           matrix_ref: @matrix_ref,
           harness_ref: @harness_ref,
           command: @command,
           task: @task,
           action: "provide_stored_artifact_records",
           message: "Report regeneration requires at least one stored artifact record."
         }}
    end
  end

  defp normalize_artifact_records(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, normalized} ->
      case normalize_artifact_record(artifact) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | normalized]}}
        {:error, finding} -> {:halt, {:error, finding}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp normalize_artifact_record(artifact) when is_map(artifact) do
    normalized =
      Enum.reduce(@fixed_artifact_keys, %{}, fn key, acc ->
        case Map.fetch(artifact, key) do
          {:ok, value} ->
            Map.put(acc, key, value)

          :error ->
            case Map.fetch(artifact, to_string(key)) do
              {:ok, value} -> Map.put(acc, key, value)
              :error -> acc
            end
        end
      end)
      |> Map.put_new(:ledger, [])
      |> Map.put_new(:redaction_report, empty_redaction_report(artifact))
      |> Map.put_new(:secret_findings, [])
      |> Map.put_new(:quarantined, false)
      |> Map.put_new(:sensitivity, "internal")

    case required_artifact_keys(normalized) do
      [] -> {:ok, normalized}
      missing -> {:error, missing_artifact_fields_finding(normalized, missing)}
    end
  end

  defp normalize_artifact_record(_artifact) do
    {:error,
     %{
       schema_version: @finding_schema,
       category: "report_regeneration_invalid_artifact_record",
       severity: "error",
       matrix_ref: @matrix_ref,
       harness_ref: @harness_ref,
       command: @command,
       task: @task,
       action: "provide_stored_artifact_records",
       message: "Stored artifact records must be maps."
     }}
  end

  defp required_artifact_keys(artifact) do
    [:artifact_key, :artifact_role, :projection_path, :blob_path, :sha256]
    |> Enum.reject(fn key ->
      value = Map.get(artifact, key)
      is_binary(value) and value != ""
    end)
  end

  defp missing_artifact_fields_finding(artifact, missing) do
    %{
      schema_version: @finding_schema,
      category: "report_regeneration_invalid_artifact_record",
      severity: "error",
      matrix_ref: @matrix_ref,
      harness_ref: @harness_ref,
      command: @command,
      task: @task,
      artifact_key: Map.get(artifact, :artifact_key),
      missing_fields: Enum.map(missing, &Atom.to_string/1),
      action: "provide_complete_stored_artifact_records",
      message: "Stored artifact records are missing fields needed for digest verification."
    }
  end

  defp empty_redaction_report(artifact) do
    artifact_key = Map.get(artifact, :artifact_key, Map.get(artifact, "artifact_key"))
    artifact_role = Map.get(artifact, :artifact_role, Map.get(artifact, "artifact_role"))
    sha256 = Map.get(artifact, :sha256, Map.get(artifact, "sha256"))

    %{
      schema_version: "conveyor.redaction_report@1",
      artifact_key: artifact_key,
      artifact_role: artifact_role,
      finding_count: 0,
      findings: [],
      raw_sha256: sha256,
      redacted_sha256: sha256,
      redacted: false
    }
  end

  defp missing_input_finding(field, message) do
    %{
      schema_version: @finding_schema,
      category: "report_regeneration_missing_input",
      severity: "error",
      matrix_ref: @matrix_ref,
      harness_ref: @harness_ref,
      command: @command,
      task: @task,
      missing_field: to_string(field),
      action: "provide_report_regeneration_input",
      message: message
    }
  end

  defp annotate_finding(%{schema_version: @finding_schema} = finding) do
    finding
    |> Map.put_new(:regeneration_status, "blocked")
    |> Map.put_new(:verification_stage, "pre_projection")
    |> Map.put_new(:exit_code, 1)
  end

  defp annotate_finding(finding) when is_map(finding) do
    finding
    |> Map.put_new(:command, @command)
    |> Map.put_new(:task, @task)
    |> Map.put_new(:matrix_ref, @matrix_ref)
    |> Map.put_new(:harness_ref, @harness_ref)
    |> Map.put_new(:regeneration_status, "blocked")
    |> Map.put_new(:verification_stage, "pre_projection")
    |> Map.put_new(:exit_code, 1)
  end

  defp regeneration_log(projection, source_artifacts) do
    %{
      schema_version: @schema_version,
      category: "report_regeneration",
      matrix_ref: @matrix_ref,
      harness_ref: @harness_ref,
      vmr_refs: [@matrix_ref, @harness_ref],
      command: @command,
      task: @task,
      service_module: "Conveyor.OperatorTasks.Report",
      status: "pass",
      exit_code: 0,
      run_id: projection.run_id,
      bundle_id: projection.bundle_id,
      bundle_root_sha256: projection.bundle_root_sha256,
      manifest_path: projection.manifest_path,
      run_bundle_path: projection.run_bundle_path,
      source_artifact_count: Enum.count(source_artifacts),
      projected_artifact_count: Enum.count(projection.artifacts),
      projected_artifact_roles: Enum.map(projection.artifacts, & &1["artifact_role"]),
      generated_reports: projection.human_report_generation,
      redaction_report: projection.redaction_report,
      ledger_event_count: Enum.count(projection.ledger),
      verification: %{
        digest_verification: "before_projection",
        verified_blob_count: Enum.count(source_artifacts),
        generated_artifacts_verified: projection.human_report_generation != nil
      },
      manifest_root_digest: projection.manifest["root_digest"]
    }
  end
end

defmodule Conveyor.OperatorTasks.Deferred do
  @moduledoc """
  Provider-free service used by operator command shells until station services land.
  """

  @schema_version "conveyor.operator_task.smoke@1"

  def run(spec, opts \\ []) when is_map(spec) and is_list(opts) do
    %{
      schema_version: @schema_version,
      matrix_ref: spec.matrix_ref,
      command: spec.id,
      task: spec.task,
      task_module: spec.task_module,
      service_module: spec.service_module,
      status: spec.status,
      exit_code: spec.exit_code,
      json_capable: spec.json_capable,
      live_provider_required: spec.live_provider_required,
      provider_requirements: spec.provider_requirements,
      provider_mode: "none",
      smoke_result: "pass",
      mode: Keyword.get(opts, :mode, "metadata"),
      message: spec.description,
      next_actions: spec.next_actions
    }
  end
end
