defmodule Conveyor.Observability.SpanHierarchyTest do
  use ExUnit.Case, async: true

  alias Conveyor.Observability.SpanHierarchy
  alias ConveyorWeb.Telemetry

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @run_span_id "00f067aa0ba902b7"

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:telemetry)
    :ok
  end

  test "emits run_slice and station spans with OpenTelemetry trace context" do
    handler_id = "span-hierarchy-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      SpanHierarchy.telemetry_event(),
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:span, measurements, metadata})
      end,
      nil
    )

    try do
      span_tree =
        SpanHierarchy.build!(%{
          run_id: "run-001",
          slice_id: "slice-001",
          trace_id: @trace_id,
          run_span_id: @run_span_id
        })

      assert %{
               schema_version: "conveyor.span_hierarchy@1",
               category: "captured_span_tree",
               trace_id: @trace_id,
               root_span: %{name: "conveyor.run_slice", span_id: @run_span_id},
               spans: spans
             } = span_tree

      assert Enum.map(spans, & &1.name) == [
               "conveyor.run_slice"
               | Enum.map(SpanHierarchy.station_keys(), &"conveyor.station.#{&1}")
             ]

      assert Enum.all?(spans, &(&1.trace_id == @trace_id))
      assert hd(spans).traceparent == "00-#{@trace_id}-#{@run_span_id}-01"

      station_spans = tl(spans)
      assert Enum.all?(station_spans, &(&1.parent_span_id == @run_span_id))
      assert Enum.all?(station_spans, &String.starts_with?(&1.traceparent, "00-#{@trace_id}-"))

      assert ^span_tree = SpanHierarchy.emit!(span_tree)

      emitted_spans =
        for _ <- spans do
          assert_receive {:span, %{duration: 0}, emitted_span}
          emitted_span
        end

      assert Enum.map(emitted_spans, & &1.name) == Enum.map(spans, & &1.name)
    after
      :telemetry.detach(handler_id)
    end
  end

  test "reports trace propagation across ledger, station, tool, artifact, report, and adapter records" do
    span_tree =
      SpanHierarchy.build!(%{
        run_id: "run-002",
        slice_id: "slice-002",
        trace_id: @trace_id,
        run_span_id: @run_span_id
      })

    report =
      SpanHierarchy.propagation_report(span_tree, %{
        ledger_events: [%{trace_id: @trace_id}],
        station_runs: [%{"trace_id" => @trace_id}],
        tool_invocations: [%{trace_id: @trace_id}],
        artifacts: [%{trace_id: @trace_id}],
        reports: [%{trace_id: @trace_id}],
        adapter_events: [
          %{
            trace_id: @trace_id,
            protocol_allows_traceparent: true,
            traceparent: SpanHierarchy.traceparent(@trace_id, @run_span_id)
          },
          %{trace_id: @trace_id, protocol_allows_traceparent: false}
        ]
      })

    assert %{
             schema_version: "conveyor.trace_propagation_assertion@1",
             category: "trace_propagation",
             status: "ok",
             trace_id: @trace_id,
             finding_count: 0,
             findings: [],
             record_counts: %{
               ledger_events: 1,
               station_runs: 1,
               tool_invocations: 1,
               artifacts: 1,
               reports: 1,
               adapter_events: 2
             }
           } = report

    failed_report =
      SpanHierarchy.propagation_report(span_tree, %{
        ledger_events: [%{trace_id: "00000000000000000000000000000000"}],
        station_runs: [%{}],
        tool_invocations: [%{}],
        artifacts: [%{}],
        reports: [%{}],
        adapter_events: [%{trace_id: @trace_id, protocol_allows_traceparent: true}]
      })

    assert %{
             status: "failed",
             finding_count: 6,
             findings: findings
           } = failed_report

    assert has_finding?(findings, "ledger_events", "trace_id_mismatch")
    assert has_finding?(findings, "station_runs", "missing_trace_id")
    assert has_finding?(findings, "adapter_events", "missing_traceparent")
  end

  test "defines bounded Conveyor metrics without high-cardinality labels" do
    specs = Telemetry.conveyor_metric_specs()

    assert Enum.map(specs, & &1.key) == [
             :station_duration,
             :station_status,
             :policy_decision,
             :adapter_outcome,
             :gate_stage,
             :canary_false_negative,
             :budget_counter
           ]

    assert %{
             schema_version: "conveyor.metric_cardinality_report@1",
             category: "metric_cardinality",
             status: "ok",
             metric_count: 7,
             finding_count: 0,
             findings: []
           } = Telemetry.conveyor_metric_cardinality_report()

    allowed = MapSet.new(Telemetry.allowed_conveyor_metric_tags())
    forbidden = MapSet.new(Telemetry.forbidden_conveyor_metric_labels())

    for spec <- specs do
      assert MapSet.subset?(MapSet.new(spec.tags), allowed)
      assert MapSet.disjoint?(MapSet.new(spec.tags), forbidden)
      assert MapSet.disjoint?(MapSet.new(spec.metadata_keys), forbidden)
    end

    conveyor_metrics =
      Telemetry.metrics()
      |> Enum.map(&metric_name/1)
      |> Enum.filter(&String.starts_with?(&1, "conveyor."))

    assert "conveyor.station.duration" in conveyor_metrics
    assert "conveyor.policy.decision.count" in conveyor_metrics
    assert "conveyor.adapter.outcome.count" in conveyor_metrics
    assert "conveyor.gate.stage.count" in conveyor_metrics
    assert "conveyor.canary.false_negative.count" in conveyor_metrics
    assert "conveyor.budget.counter.value" in conveyor_metrics
  end

  test "metric cardinality report rejects commands paths prompts errors and summaries" do
    report =
      Telemetry.conveyor_metric_cardinality_report([
        %{
          key: :bad_metric,
          name: "conveyor.bad.metric",
          type: :counter,
          tags: [:project_id, :raw_command, :file_path],
          metadata_keys: [:status, :prompt, :error_message, :model_summary]
        }
      ])

    assert %{
             status: "failed",
             finding_count: 5,
             findings: findings
           } = report

    assert metric_finding?(findings, "tag", "raw_command", "forbidden_metric_label")
    assert metric_finding?(findings, "tag", "file_path", "forbidden_metric_label")
    assert metric_finding?(findings, "metadata_key", "prompt", "forbidden_metric_label")
    assert metric_finding?(findings, "metadata_key", "error_message", "forbidden_metric_label")
    assert metric_finding?(findings, "metadata_key", "model_summary", "forbidden_metric_label")
  end

  defp has_finding?(findings, record_set, finding_code) do
    Enum.any?(findings, fn finding ->
      match?(%{record_set: ^record_set, finding_code: ^finding_code}, finding)
    end)
  end

  defp metric_name(%{name: name}) when is_binary(name), do: name
  defp metric_name(%{name: name}) when is_list(name), do: Enum.join(name, ".")

  defp metric_finding?(findings, source, label, finding_code) do
    Enum.any?(findings, fn finding ->
      match?(
        %{source: ^source, label: ^label, finding_code: ^finding_code},
        finding
      )
    end)
  end
end
