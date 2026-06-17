defmodule Conveyor.AgentRunner do
  @moduledoc """
  Behaviour and capability contract for stochastic agent adapters.

  Adapters may be more capable than a run is allowed to be. Conveyor always
  derives the effective autonomy ceiling from declared adapter capabilities plus
  the current host policy and credential posture.
  """

  @snapshot_schema_version "conveyor.agent_profile_capability_snapshot@1"
  @snapshot_category "agent_profile_capability_snapshot"
  @event_envelope_version "conveyor.agent_event@1"
  @event_log_schema_version "conveyor.normalized_agent_event_log@1"
  @event_matrix_ref "conveyor-quality-ci-evals-vmr.13"
  @autonomy_levels ["L0", "L1", "L2", "L3", "L4"]

  @adapter_event_types [
    "session_started",
    "message_delta",
    "message_completed",
    "command_requested",
    "command_policy_decision",
    "command_started",
    "command_completed",
    "file_change_observed",
    "heartbeat",
    "final_response",
    "cancel_requested",
    "cancel_acknowledged",
    "adapter_error",
    "session_completed"
  ]

  @capability_keys [
    "streaming_events",
    "pre_exec_command_policy",
    "cancellation",
    "diff_capture",
    "cost_reporting",
    "mcp_support",
    "slash_commands",
    "structured_output",
    "session_resume"
  ]

  @level_requirements [
    {"L4",
     [
       "pre_exec_command_policy",
       "diff_capture",
       "structured_output",
       "streaming_events",
       "cancellation",
       "session_resume",
       "cost_reporting",
       "mcp_support",
       "slash_commands"
     ]},
    {"L3",
     [
       "pre_exec_command_policy",
       "diff_capture",
       "structured_output",
       "streaming_events",
       "cancellation",
       "session_resume",
       "cost_reporting",
       "mcp_support"
     ]},
    {"L2",
     [
       "pre_exec_command_policy",
       "diff_capture",
       "structured_output",
       "streaming_events",
       "cancellation",
       "session_resume"
     ]},
    {"L1", ["pre_exec_command_policy", "diff_capture", "structured_output"]},
    {"L0", []}
  ]

  @type adapter_session :: map()
  @type adapter_event :: map()
  @type capability_snapshot :: map()

  @callback capability_snapshot(profile :: map(), opts :: keyword()) :: capability_snapshot()
  @callback start_session(run_spec :: map(), profile :: map(), opts :: keyword()) ::
              {:ok, adapter_session()} | {:error, term()}
  @callback stream_events(session :: adapter_session(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}
  @callback request_command(
              session :: adapter_session(),
              command_request :: map(),
              opts :: keyword()
            ) ::
              {:ok, map()} | {:blocked, map()} | {:error, term()}
  @callback cancel(session :: adapter_session(), reason :: term()) :: :ok | {:error, term()}
  @callback capture_diff(session :: adapter_session(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback cost_report(session :: adapter_session(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback resume_session(session_ref :: map(), opts :: keyword()) ::
              {:ok, adapter_session()} | {:error, term()}

  def snapshot_schema_version, do: @snapshot_schema_version
  def event_envelope_version, do: @event_envelope_version
  def adapter_event_types, do: @adapter_event_types
  def capability_keys, do: @capability_keys
  def autonomy_levels, do: @autonomy_levels

  def capability_snapshot(profile, opts \\ []) when is_map(profile) and is_list(opts) do
    capabilities = profile |> get(:capabilities, %{}) |> normalize_capabilities!()
    theoretical_ceiling = theoretical_autonomy_ceiling(capabilities)

    requested_ceiling =
      opts
      |> Keyword.get(:requested_autonomy_ceiling, get(profile, :requested_autonomy_ceiling))
      |> fallback(get(profile, :autonomy_ceiling))
      |> fallback(get(profile, :autonomy_level))
      |> normalize_autonomy_level(theoretical_ceiling)

    host_policy_ceiling =
      opts
      |> Keyword.get(:host_policy_autonomy_ceiling, get(profile, :host_policy_autonomy_ceiling))
      |> fallback(Keyword.get(opts, :host_policy_ceiling, get(profile, :host_policy_ceiling)))
      |> normalize_autonomy_level(requested_ceiling)

    credential_ceiling =
      opts
      |> Keyword.get(:credential_autonomy_ceiling, get(profile, :credential_autonomy_ceiling))
      |> fallback(Keyword.get(opts, :credential_ceiling, get(profile, :credential_ceiling)))
      |> normalize_autonomy_level(requested_ceiling)

    effective_ceiling =
      minimum_autonomy_level([
        theoretical_ceiling,
        requested_ceiling,
        host_policy_ceiling,
        credential_ceiling
      ])

    known_limitations =
      profile
      |> get(:known_limitations, [])
      |> normalize_string_list!("known_limitations")

    %{
      "schema_version" => @snapshot_schema_version,
      "category" => @snapshot_category,
      "agent_profile_id" => fetch_profile_id!(profile),
      "adapter" => fetch_adapter!(profile),
      "capabilities" => capabilities,
      "negative_capabilities" => negative_capabilities(capabilities),
      "known_limitations" => known_limitations,
      "theoretical_autonomy_ceiling" => theoretical_ceiling,
      "requested_autonomy_ceiling" => requested_ceiling,
      "host_policy_autonomy_ceiling" => host_policy_ceiling,
      "credential_autonomy_ceiling" => credential_ceiling,
      "effective_autonomy_ceiling" => effective_ceiling,
      "limiting_factors" =>
        limiting_factors(%{
          theoretical_autonomy_ceiling: theoretical_ceiling,
          requested_autonomy_ceiling: requested_ceiling,
          host_policy_autonomy_ceiling: host_policy_ceiling,
          credential_autonomy_ceiling: credential_ceiling,
          effective_autonomy_ceiling: effective_ceiling
        })
    }
  end

  def normalize_capability_snapshot!(snapshot) when is_map(snapshot) do
    capabilities = snapshot |> get(:capabilities, %{}) |> normalize_capabilities!()
    theoretical_ceiling = theoretical_autonomy_ceiling(capabilities)

    requested_ceiling =
      snapshot
      |> get(:requested_autonomy_ceiling)
      |> normalize_autonomy_level(theoretical_ceiling)

    host_policy_ceiling =
      snapshot
      |> get(:host_policy_autonomy_ceiling)
      |> normalize_autonomy_level(requested_ceiling)

    credential_ceiling =
      snapshot
      |> get(:credential_autonomy_ceiling)
      |> normalize_autonomy_level(requested_ceiling)

    effective_ceiling =
      minimum_autonomy_level([
        theoretical_ceiling,
        requested_ceiling,
        host_policy_ceiling,
        credential_ceiling
      ])

    %{
      "schema_version" => @snapshot_schema_version,
      "category" => @snapshot_category,
      "agent_profile_id" => fetch_profile_id!(snapshot),
      "adapter" => fetch_adapter!(snapshot),
      "capabilities" => capabilities,
      "negative_capabilities" => negative_capabilities(capabilities),
      "known_limitations" =>
        snapshot
        |> get(:known_limitations, [])
        |> normalize_string_list!("known_limitations"),
      "theoretical_autonomy_ceiling" => theoretical_ceiling,
      "requested_autonomy_ceiling" => requested_ceiling,
      "host_policy_autonomy_ceiling" => host_policy_ceiling,
      "credential_autonomy_ceiling" => credential_ceiling,
      "effective_autonomy_ceiling" => effective_ceiling,
      "limiting_factors" =>
        limiting_factors(%{
          theoretical_autonomy_ceiling: theoretical_ceiling,
          requested_autonomy_ceiling: requested_ceiling,
          host_policy_autonomy_ceiling: host_policy_ceiling,
          credential_autonomy_ceiling: credential_ceiling,
          effective_autonomy_ceiling: effective_ceiling
        })
    }
  end

  def normalize_capability_snapshot!(_snapshot) do
    raise ArgumentError, "agent capability snapshot must be a map"
  end

  def normalize_adapter_events!(raw_events, context, opts \\ []) when is_list(opts) do
    start_sequence = Keyword.get(opts, :start_sequence, 1)

    raw_events
    |> Enum.to_list()
    |> Enum.with_index(start_sequence)
    |> Enum.map(fn {raw_event, sequence} ->
      normalize_adapter_event!(raw_event, context, sequence: sequence)
    end)
  end

  def normalize_adapter_event!(raw_event, context, opts \\ [])

  def normalize_adapter_event!(raw_event, context, opts)
      when is_map(raw_event) and is_map(context) and is_list(opts) do
    sequence = Keyword.fetch!(opts, :sequence)
    event_type = raw_event |> raw_event_type!() |> normalize_event_type!()
    trace_context = trace_context!(raw_event, context)
    adapter = required_context!(context, :adapter)
    adapter_session_id = required_context!(context, :adapter_session_id)

    %{
      "event_version" => @event_envelope_version,
      "event_type" => event_type,
      "run_spec_sha256" => required_context!(context, :run_spec_sha256),
      "run_attempt_id" => required_context!(context, :run_attempt_id),
      "agent_session_id" => required_context!(context, :agent_session_id),
      "adapter" => adapter,
      "adapter_session_id" => adapter_session_id,
      "seq" => sequence,
      "raw_ref" => raw_ref(raw_event, adapter, adapter_session_id, event_type, sequence),
      "trace_context" => trace_context,
      "payload" => normalized_event_payload(raw_event)
    }
  end

  def normalize_adapter_event!(_raw_event, _context, _opts) do
    raise ArgumentError, "adapter event and normalization context must be maps"
  end

  def normalized_event_log(events) when is_list(events) do
    sequences = Enum.map(events, &Map.fetch!(&1, "seq"))

    %{
      "schema_version" => @event_log_schema_version,
      "matrix_ref" => @event_matrix_ref,
      "event_count" => length(events),
      "event_types" => Enum.map(events, &Map.fetch!(&1, "event_type")),
      "first_seq" => List.first(sequences),
      "last_seq" => List.last(sequences),
      "events" => events
    }
  end

  def theoretical_autonomy_ceiling(capabilities) when is_map(capabilities) do
    normalized = normalize_capabilities!(capabilities)

    Enum.find_value(@level_requirements, fn {level, required_capabilities} ->
      if Enum.all?(required_capabilities, &Map.fetch!(normalized, &1)) do
        level
      end
    end)
  end

  def negative_capabilities(capabilities) when is_map(capabilities) do
    normalized = normalize_capabilities!(capabilities)
    Enum.reject(@capability_keys, &Map.fetch!(normalized, &1))
  end

  def autonomy_allows?(selected_level, ceiling_level) do
    autonomy_level_rank(selected_level) <= autonomy_level_rank(ceiling_level)
  end

  def autonomy_level_rank(level) do
    level = normalize_autonomy_level(level, nil)

    Enum.find_index(@autonomy_levels, &(&1 == level)) ||
      raise ArgumentError, "unknown autonomy level: #{inspect(level)}"
  end

  defp normalize_capabilities!(capabilities) when is_map(capabilities) do
    capabilities = Map.new(capabilities, fn {key, value} -> {to_string(key), value} end)

    Map.new(@capability_keys, fn capability ->
      value = Map.get(capabilities, capability, false)
      {capability, normalize_boolean!(capability, value)}
    end)
  end

  defp normalize_capabilities!(_capabilities) do
    raise ArgumentError, "agent capabilities must be a map"
  end

  defp raw_event_type!(raw_event) do
    get(raw_event, :event_type) || get(raw_event, :type) || get(raw_event, :kind) ||
      get(raw_event, :event) || raise ArgumentError, "adapter event is missing event_type"
  end

  defp normalize_event_type!(event_type) when is_atom(event_type) do
    event_type |> Atom.to_string() |> normalize_event_type!()
  end

  defp normalize_event_type!(event_type) when is_binary(event_type) do
    normalized =
      event_type
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    if normalized in @adapter_event_types do
      normalized
    else
      raise ArgumentError, "unknown adapter event type: #{inspect(event_type)}"
    end
  end

  defp normalize_event_type!(event_type) do
    raise ArgumentError,
          "adapter event type must be a string or atom, got: #{inspect(event_type)}"
  end

  defp trace_context!(raw_event, context) do
    raw_trace_context = get(raw_event, :trace_context, %{})
    context_trace_context = get(context, :trace_context, %{})

    merged_trace_context =
      context_trace_context
      |> normalize_string_key_map!("trace_context")
      |> Map.merge(normalize_string_key_map!(raw_trace_context, "trace_context"))

    trace_id =
      get(raw_event, :trace_id) || Map.get(merged_trace_context, "trace_id") ||
        get(context, :trace_id) || raise ArgumentError, "trace context is missing trace_id"

    span_id =
      get(raw_event, :span_id) || Map.get(merged_trace_context, "span_id") ||
        get(context, :span_id) || raise ArgumentError, "trace context is missing span_id"

    parent_span_id =
      get(raw_event, :parent_span_id) || Map.get(merged_trace_context, "parent_span_id") ||
        get(context, :parent_span_id)

    traceparent =
      get(raw_event, :traceparent) || Map.get(merged_trace_context, "traceparent") ||
        get(context, :traceparent) || generated_traceparent(trace_id, span_id)

    merged_trace_context
    |> Map.put("trace_id", trace_id)
    |> Map.put("span_id", span_id)
    |> maybe_put("parent_span_id", parent_span_id)
    |> maybe_put("traceparent", traceparent)
  end

  defp generated_traceparent(trace_id, span_id) do
    with true <- lowercase_hex?(trace_id, 32),
         true <- lowercase_hex?(span_id, 16) do
      "00-#{trace_id}-#{span_id}-01"
    else
      _ -> nil
    end
  end

  defp lowercase_hex?(value, length) when is_binary(value) and byte_size(value) == length do
    String.match?(value, ~r/^[0-9a-f]+$/)
  end

  defp lowercase_hex?(_value, _length), do: false

  defp raw_ref(raw_event, adapter, adapter_session_id, event_type, sequence) do
    get(raw_event, :raw_ref) || get(raw_event, :id) ||
      "#{adapter}:#{adapter_session_id}:#{String.pad_leading(to_string(sequence), 10, "0")}:#{event_type}"
  end

  defp normalized_event_payload(raw_event) do
    raw_event
    |> get(:payload, %{})
    |> normalize_payload_value()
  end

  defp normalize_payload_value(value) when is_map(value) do
    normalize_string_key_map!(value, "payload")
  end

  defp normalize_payload_value(nil), do: %{}
  defp normalize_payload_value(value), do: %{"value" => value}

  defp normalize_string_key_map!(nil, _field), do: %{}

  defp normalize_string_key_map!(map, field) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        {to_string(key), value}

      {key, _value} ->
        raise ArgumentError, "#{field} keys must be atoms or strings, got: #{inspect(key)}"
    end)
  end

  defp normalize_string_key_map!(_map, field), do: raise(ArgumentError, "#{field} must be a map")

  defp required_context!(context, key) do
    get(context, key) || raise ArgumentError, "event normalization context is missing #{key}"
  end

  defp normalize_boolean!(_capability, value) when is_boolean(value), do: value
  defp normalize_boolean!(_capability, nil), do: false

  defp normalize_boolean!(capability, value) do
    raise ArgumentError,
          "agent capability #{capability} must be true or false, got: #{inspect(value)}"
  end

  defp normalize_string_list!(values, field) when is_list(values) do
    values
    |> Enum.map(fn
      value when is_binary(value) and value != "" ->
        value

      value ->
        raise ArgumentError, "#{field} must contain non-empty strings, got: #{inspect(value)}"
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_string_list!(_values, field) do
    raise ArgumentError, "#{field} must be a list"
  end

  defp normalize_autonomy_level(nil, nil), do: raise(ArgumentError, "missing autonomy level")
  defp normalize_autonomy_level(nil, default), do: normalize_autonomy_level(default, nil)

  defp normalize_autonomy_level(level, _default) when is_binary(level) do
    if level in @autonomy_levels do
      level
    else
      raise ArgumentError, "unknown autonomy level: #{inspect(level)}"
    end
  end

  defp normalize_autonomy_level(level, default) when is_atom(level) do
    level |> Atom.to_string() |> String.upcase() |> normalize_autonomy_level(default)
  end

  defp normalize_autonomy_level(level, _default) do
    raise ArgumentError, "unknown autonomy level: #{inspect(level)}"
  end

  defp minimum_autonomy_level(levels) do
    Enum.min_by(levels, &autonomy_level_rank/1)
  end

  defp limiting_factors(ceilings) do
    theoretical_ceiling = ceilings.theoretical_autonomy_ceiling

    [
      factor("requested_autonomy", ceilings.requested_autonomy_ceiling, theoretical_ceiling),
      factor("host_policy", ceilings.host_policy_autonomy_ceiling, theoretical_ceiling),
      factor("credential_posture", ceilings.credential_autonomy_ceiling, theoretical_ceiling)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp factor(source, ceiling, theoretical_ceiling) do
    if autonomy_level_rank(ceiling) < autonomy_level_rank(theoretical_ceiling) do
      %{
        "source" => source,
        "ceiling" => ceiling,
        "reason" => "#{source}_below_theoretical_ceiling"
      }
    end
  end

  defp fetch_profile_id!(map) do
    get(map, :agent_profile_id) || get(map, :profile_id) || get(map, :external_id) ||
      raise ArgumentError, "missing agent profile id"
  end

  defp fetch_adapter!(map) do
    get(map, :adapter) || raise ArgumentError, "missing agent adapter"
  end

  defp fallback(nil, fallback), do: fallback
  defp fallback(value, _fallback), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
