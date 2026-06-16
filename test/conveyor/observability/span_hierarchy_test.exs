defmodule Conveyor.Observability.SpanHierarchyTest do
  use ExUnit.Case, async: true

  alias Conveyor.Observability.SpanHierarchy

  @trace_id "4bf92f3577b34da6a3ce929d0e0e4736"
  @run_span_id "00f067aa0ba902b7"

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

  defp has_finding?(findings, record_set, finding_code) do
    Enum.any?(findings, fn finding ->
      match?(%{record_set: ^record_set, finding_code: ^finding_code}, finding)
    end)
  end
end
