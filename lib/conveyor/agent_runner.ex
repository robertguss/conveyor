defmodule Conveyor.AgentRunner do
  @moduledoc """
  Behaviour and capability contract for stochastic agent adapters.

  Adapters may be more capable than a run is allowed to be. Conveyor always
  derives the effective autonomy ceiling from declared adapter capabilities plus
  the current host policy and credential posture.
  """

  @snapshot_schema_version "conveyor.agent_profile_capability_snapshot@1"
  @snapshot_category "agent_profile_capability_snapshot"
  @autonomy_levels ["L0", "L1", "L2", "L3", "L4"]

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

  defp get(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
