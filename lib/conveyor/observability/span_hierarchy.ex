defmodule Conveyor.Observability.SpanHierarchy do
  @moduledoc """
  OpenTelemetry-compatible span hierarchy for Conveyor run-slice execution.

  Phase 0 keeps this independent of a concrete OpenTelemetry exporter. The
  emitted telemetry metadata uses the W3C trace context shape that exporters and
  adapters can map into protocol-specific headers later.
  """

  @schema_version "conveyor.span_hierarchy@1"
  @assertion_schema_version "conveyor.trace_propagation_assertion@1"
  @telemetry_event [:conveyor, :span, :emit]
  @trace_flags "01"

  @station_keys [
    "readiness",
    "baseline",
    "scout",
    "prompt",
    "implement",
    "adapter_session",
    "tool_command",
    "evidence",
    "review",
    "gate",
    "canary",
    "post_integration"
  ]

  @record_sets [
    :ledger_events,
    :station_runs,
    :tool_invocations,
    :artifacts,
    :reports,
    :adapter_events
  ]

  def schema_version, do: @schema_version
  def assertion_schema_version, do: @assertion_schema_version
  def telemetry_event, do: @telemetry_event
  def station_keys, do: @station_keys

  def build!(attrs) when is_map(attrs) do
    run_id = fetch_string!(attrs, :run_id)
    slice_id = fetch_string!(attrs, :slice_id)
    trace_id = attrs |> get_optional(:trace_id) |> normalize_trace_id(run_id, slice_id)
    run_span_id = attrs |> get_optional(:run_span_id) |> normalize_span_id(trace_id, "run_slice")

    root_span = %{
      name: "conveyor.run_slice",
      kind: "internal",
      trace_id: trace_id,
      span_id: run_span_id,
      parent_span_id: nil,
      traceparent: traceparent(trace_id, run_span_id),
      attributes: %{
        "conveyor.run_id" => run_id,
        "conveyor.slice_id" => slice_id
      }
    }

    station_spans =
      Enum.map(@station_keys, fn station_key ->
        span_id = normalize_span_id(nil, "#{trace_id}:#{station_key}")

        %{
          name: "conveyor.station.#{station_key}",
          kind: "internal",
          station_key: station_key,
          trace_id: trace_id,
          span_id: span_id,
          parent_span_id: run_span_id,
          traceparent: traceparent(trace_id, span_id),
          attributes: %{
            "conveyor.run_id" => run_id,
            "conveyor.slice_id" => slice_id,
            "conveyor.station" => station_key
          }
        }
      end)

    %{
      schema_version: @schema_version,
      category: "captured_span_tree",
      trace_id: trace_id,
      root_span: root_span,
      spans: [root_span | station_spans]
    }
  end

  def emit!(%{spans: spans} = span_tree) when is_list(spans) do
    Enum.each(spans, fn span ->
      :telemetry.execute(@telemetry_event, %{duration: 0}, span)
    end)

    span_tree
  end

  def propagation_report(%{trace_id: trace_id}, records) when is_map(records) do
    findings =
      records
      |> normalize_record_sets()
      |> Enum.flat_map(fn {record_set, entries} ->
        entries
        |> Enum.with_index()
        |> Enum.flat_map(fn {entry, index} ->
          trace_findings(trace_id, record_set, index, entry) ++
            traceparent_findings(record_set, index, entry)
        end)
      end)

    record_counts =
      @record_sets
      |> Map.new(fn record_set -> {record_set, records |> Map.get(record_set, []) |> length()} end)

    %{
      schema_version: @assertion_schema_version,
      category: "trace_propagation",
      status: if(findings == [], do: "ok", else: "failed"),
      trace_id: trace_id,
      record_counts: record_counts,
      finding_count: length(findings),
      findings: findings
    }
  end

  def traceparent(trace_id, span_id) do
    "00-#{trace_id}-#{span_id}-#{@trace_flags}"
  end

  defp normalize_record_sets(records) do
    Map.new(@record_sets, fn record_set ->
      {record_set, Map.get(records, record_set, [])}
    end)
  end

  defp trace_findings(expected_trace_id, record_set, index, entry) do
    case get_optional(entry, :trace_id) do
      ^expected_trace_id ->
        []

      nil ->
        [finding(record_set, index, "missing_trace_id", %{expected_trace_id: expected_trace_id})]

      actual_trace_id ->
        [
          finding(record_set, index, "trace_id_mismatch", %{
            expected_trace_id: expected_trace_id,
            actual_trace_id: actual_trace_id
          })
        ]
    end
  end

  defp traceparent_findings(:adapter_events, index, entry) do
    if traceparent_required?(entry) and not present?(get_optional(entry, :traceparent)) do
      [finding(:adapter_events, index, "missing_traceparent", %{})]
    else
      []
    end
  end

  defp traceparent_findings(_record_set, _index, _entry), do: []

  defp traceparent_required?(entry) do
    get_optional(entry, :protocol_allows_traceparent) in [true, "true"]
  end

  defp finding(record_set, index, finding_code, extra) do
    %{
      record_set: Atom.to_string(record_set),
      index: index,
      finding_code: finding_code
    }
    |> Map.merge(extra)
  end

  defp normalize_trace_id(nil, run_id, slice_id),
    do: digest_hex("trace:#{run_id}:#{slice_id}", 32)

  defp normalize_trace_id(trace_id, _run_id, _slice_id) when is_binary(trace_id) do
    case String.downcase(trace_id) do
      <<_::binary-size(32)>> = normalized -> normalized
      _invalid -> raise ArgumentError, "trace_id must be 32 lowercase hex characters"
    end
  end

  defp normalize_span_id(span_id, trace_id, label),
    do: normalize_span_id(span_id, "#{trace_id}:#{label}")

  defp normalize_span_id(nil, seed), do: digest_hex("span:#{seed}", 16)

  defp normalize_span_id(span_id, _seed) when is_binary(span_id) do
    case String.downcase(span_id) do
      <<_::binary-size(16)>> = normalized -> normalized
      _invalid -> raise ArgumentError, "span_id must be 16 lowercase hex characters"
    end
  end

  defp digest_hex(seed, bytes) do
    :crypto.hash(:sha256, seed)
    |> Base.encode16(case: :lower)
    |> binary_part(0, bytes)
  end

  defp fetch_string!(map, key) do
    value = get_optional(map, key)

    if present?(value) do
      value
    else
      raise ArgumentError, "missing required span hierarchy field: #{key}"
    end
  end

  defp get_optional(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp present?(value), do: is_binary(value) and value != ""
end
