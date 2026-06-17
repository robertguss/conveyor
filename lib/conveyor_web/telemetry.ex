defmodule ConveyorWeb.Telemetry do
  @moduledoc false

  use Supervisor
  import Telemetry.Metrics

  @metric_schema_version "conveyor.metric_definitions@1"
  @cardinality_report_schema_version "conveyor.metric_cardinality_report@1"
  @allowed_conveyor_metric_tags [
    :project_id,
    :station,
    :adapter,
    :profile,
    :status,
    :failure_category,
    :policy_profile,
    :suite_kind
  ]
  @forbidden_conveyor_metric_labels [
    :raw_command,
    :command,
    :file_path,
    :path,
    :prompt,
    :error_message,
    :artifact_path,
    :model_summary
  ]
  @conveyor_metric_specs [
    %{
      key: :station_duration,
      name: "conveyor.station.duration",
      type: :summary,
      unit: {:native, :millisecond},
      tags: [:project_id, :station, :status, :failure_category],
      metadata_keys: [:project_id, :station, :status, :failure_category],
      description: "Station runtime grouped by bounded station, status, and failure category."
    },
    %{
      key: :station_status,
      name: "conveyor.station.status.count",
      type: :counter,
      tags: [:project_id, :station, :status, :failure_category],
      metadata_keys: [:project_id, :station, :status, :failure_category],
      description: "Terminal station status counts with bounded failure categories."
    },
    %{
      key: :policy_decision,
      name: "conveyor.policy.decision.count",
      type: :counter,
      tags: [:project_id, :policy_profile, :status, :failure_category],
      metadata_keys: [:project_id, :policy_profile, :status, :failure_category],
      description: "Policy allow/block/cap decisions without command text or paths."
    },
    %{
      key: :adapter_outcome,
      name: "conveyor.adapter.outcome.count",
      type: :counter,
      tags: [:project_id, :adapter, :profile, :status, :failure_category],
      metadata_keys: [:project_id, :adapter, :profile, :status, :failure_category],
      description: "Agent adapter outcomes grouped by bounded adapter and profile identifiers."
    },
    %{
      key: :gate_stage,
      name: "conveyor.gate.stage.count",
      type: :counter,
      tags: [:project_id, :station, :status, :failure_category, :suite_kind],
      metadata_keys: [:project_id, :station, :status, :failure_category, :suite_kind],
      description: "Gate stage pass/fail counts by bounded stage and suite kind."
    },
    %{
      key: :canary_false_negative,
      name: "conveyor.canary.false_negative.count",
      type: :counter,
      tags: [:project_id, :suite_kind, :status, :failure_category],
      metadata_keys: [:project_id, :suite_kind, :status, :failure_category],
      description: "Canary false-negative counts by bounded suite kind."
    },
    %{
      key: :budget_counter,
      name: "conveyor.budget.counter.value",
      type: :last_value,
      tags: [:project_id, :policy_profile, :status, :failure_category],
      metadata_keys: [:project_id, :policy_profile, :status, :failure_category],
      description: "Budget counter values without prompts, outputs, paths, or model summaries."
    }
  ]

  def metric_schema_version, do: @metric_schema_version
  def cardinality_report_schema_version, do: @cardinality_report_schema_version
  def allowed_conveyor_metric_tags, do: @allowed_conveyor_metric_tags
  def forbidden_conveyor_metric_labels, do: @forbidden_conveyor_metric_labels
  def conveyor_metric_specs, do: @conveyor_metric_specs

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.start.system_time", unit: {:native, :millisecond}),
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("conveyor.repo.query.total_time", unit: {:native, :millisecond}),
      summary("conveyor.repo.query.decode_time", unit: {:native, :millisecond}),
      summary("conveyor.repo.query.query_time", unit: {:native, :millisecond}),
      summary("conveyor.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("conveyor.repo.query.idle_time", unit: {:native, :millisecond})
    ] ++ Enum.map(@conveyor_metric_specs, &telemetry_metric/1)
  end

  def conveyor_metric_cardinality_report(specs \\ @conveyor_metric_specs) when is_list(specs) do
    findings =
      specs
      |> Enum.flat_map(&metric_findings/1)
      |> Enum.sort_by(fn finding -> {finding.metric, finding.finding_code, finding.label} end)

    %{
      schema_version: @cardinality_report_schema_version,
      category: "metric_cardinality",
      status: if(findings == [], do: "ok", else: "failed"),
      metric_count: length(specs),
      allowed_tags: @allowed_conveyor_metric_tags,
      forbidden_labels: @forbidden_conveyor_metric_labels,
      finding_count: length(findings),
      findings: findings
    }
  end

  defp periodic_measurements do
    []
  end

  defp telemetry_metric(%{type: :summary, name: name, tags: tags, unit: unit}) do
    summary(name, unit: unit, tags: tags)
  end

  defp telemetry_metric(%{type: :counter, name: name, tags: tags}) do
    counter(name, tags: tags)
  end

  defp telemetry_metric(%{type: :last_value, name: name, tags: tags}) do
    last_value(name, tags: tags)
  end

  defp metric_findings(%{} = spec) do
    metric = Map.fetch!(spec, :name)

    tag_findings =
      spec
      |> Map.get(:tags, [])
      |> Enum.flat_map(&label_findings(metric, :tag, &1))

    metadata_findings =
      spec
      |> Map.get(:metadata_keys, [])
      |> Enum.flat_map(&label_findings(metric, :metadata_key, &1))

    tag_findings ++ metadata_findings
  end

  defp label_findings(metric, source, label) do
    cond do
      label in @forbidden_conveyor_metric_labels ->
        [
          metric_finding(
            metric,
            source,
            label,
            "forbidden_metric_label",
            "high-cardinality or sensitive label source is excluded from Conveyor metrics"
          )
        ]

      label not in @allowed_conveyor_metric_tags ->
        [
          metric_finding(
            metric,
            source,
            label,
            "disallowed_metric_label",
            "metric labels must use the bounded Conveyor label allowlist"
          )
        ]

      true ->
        []
    end
  end

  defp metric_finding(metric, source, label, finding_code, next_action) do
    %{
      metric: metric,
      source: Atom.to_string(source),
      label: Atom.to_string(label),
      finding_code: finding_code,
      next_action: next_action
    }
  end
end
