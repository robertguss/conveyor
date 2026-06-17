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
      service_module: "Conveyor.OperatorTasks.Deferred",
      shortdoc: "Render a Conveyor operator report",
      description:
        "Expose report generation output contracts before report rendering is implemented.",
      status: "deferred",
      exit_code: 0,
      next_actions: ["Wire to dossier/report rendering in the operator reporting track."]
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
  defp service_module!("Conveyor.OperatorTasks.Deferred"), do: Conveyor.OperatorTasks.Deferred

  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id) when is_binary(id), do: id
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
