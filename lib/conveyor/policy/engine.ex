defmodule Conveyor.Policy.Engine do
  @moduledoc """
  Evaluates normalized command specs against Conveyor policy profiles.

  `Conveyor.Policy.CommandSpec` owns structural command normalization. This
  module owns profile semantics: command-family allowance, denylist checks,
  network defaults, and autonomy ceilings.
  """

  alias Conveyor.Domain.PayloadHelpers

  @decision_schema "conveyor.policy_engine_decision@1"
  @finding_schema "conveyor.policy_engine_finding@1"
  @matrix_ref "conveyor-quality-ci-evals-vmr.13"
  @default_profiles_path Path.join(["docs", "policy", "profiles.json"])
  @autonomy_order %{"L0" => 0, "L1" => 1, "L2" => 2}

  def fetch_profile(profile_name, opts \\ []) do
    profiles_doc = profiles_doc!(opts)
    profiles = Map.get(profiles_doc, "profiles", %{})
    profile_name = to_string(profile_name)

    case Map.get(profiles, profile_name) do
      profile when is_map(profile) ->
        {:ok, PayloadHelpers.normalize_map(profile), profiles_doc}

      _missing ->
        {:error,
         base_decision(profile_name, %{}, opts)
         |> Map.merge(%{
           status: "blocked",
           findings: [
             finding(
               "unknown_policy_profile",
               "policy profile is not defined",
               "profiles.#{profile_name}",
               %{profile: profile_name}
             )
           ]
         })}
    end
  rescue
    exception ->
      {:error,
       base_decision(to_string(profile_name), %{}, opts)
       |> Map.merge(%{
         status: "blocked",
         findings: [
           finding(
             "policy_profiles_unavailable",
             Exception.message(exception),
             "policy_profiles",
             %{}
           )
         ]
       })}
  end

  def allowed_families(profile) when is_map(profile) do
    profile
    |> Map.get("allowed_command_families", [])
    |> Enum.flat_map(&family_aliases/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def evaluate(command_decision, profile, profiles_doc, opts \\ [])
      when is_map(command_decision) and is_map(profile) and is_map(profiles_doc) do
    profile_name = profile_name(opts)

    findings =
      []
      |> add_autonomy_finding(profile, opts)
      |> add_network_finding(command_decision, profile)
      |> add_denylist_findings(command_decision, profile, profiles_doc)
      |> Enum.reverse()

    status = if Enum.any?(findings, &(&1.severity == "error")), do: "blocked", else: "allowed"

    decision =
      base_decision(profile_name, command_decision, opts)
      |> Map.merge(%{
        status: status,
        profile: profile_name,
        autonomy_level: autonomy_level(opts),
        autonomy_ceiling: Map.get(profile, "autonomy_ceiling"),
        network_policy: Map.get(profile, "network_policy"),
        allowed_command_families: allowed_families(profile),
        command_text: command_text(command_decision),
        findings: findings
      })

    if status == "allowed", do: {:ok, decision}, else: {:error, decision}
  end

  def command_block_decision(command_decision, opts \\ []) when is_map(command_decision) do
    findings =
      command_decision
      |> Map.get(:findings, Map.get(command_decision, "findings", []))
      |> Enum.map(&PayloadHelpers.normalize_map/1)

    base_decision(profile_name(opts), command_decision, opts)
    |> Map.merge(%{
      status: "blocked",
      profile: profile_name(opts),
      command_text: command_text(command_decision),
      findings: findings
    })
  end

  def observe_only?(opts) do
    opts
    |> Keyword.get(:adapter_mode, Keyword.get(opts, :mode, "execute"))
    |> to_string()
    |> then(&Enum.member?(["observe_only", "observe-only"], &1))
  end

  def observe_only_decision(command_decision, policy_decision, opts \\ []) do
    finding =
      finding(
        "observe_only_adapter_capped",
        "observe-only adapters may report intent but may not execute commands",
        "adapter_mode",
        %{adapter_mode: "observe_only", action: "cap_execution"}
      )

    policy_decision
    |> Map.merge(%{
      status: "capped",
      adapter_mode: "observe_only",
      command_text: command_text(command_decision),
      findings: [finding | Map.get(policy_decision, :findings, [])]
    })
    |> Map.put(:profile, profile_name(opts))
  end

  defp profiles_doc!(opts) do
    cond do
      Keyword.has_key?(opts, :profiles_doc) ->
        opts |> Keyword.fetch!(:profiles_doc) |> PayloadHelpers.normalize_map()

      Keyword.has_key?(opts, :policy_profiles_doc) ->
        opts |> Keyword.fetch!(:policy_profiles_doc) |> PayloadHelpers.normalize_map()

      true ->
        opts
        |> Keyword.get(:profiles_path, @default_profiles_path)
        |> File.read!()
        |> Jason.decode!()
        |> PayloadHelpers.normalize_map()
    end
  end

  defp add_autonomy_finding(findings, profile, opts) do
    requested = autonomy_level(opts)
    ceiling = Map.get(profile, "autonomy_ceiling", "L0")

    if autonomy_rank(requested) > autonomy_rank(ceiling) do
      [
        finding(
          "autonomy_ceiling_exceeded",
          "requested autonomy exceeds policy profile ceiling",
          "autonomy_level",
          %{requested: requested, ceiling: ceiling, action: "block_execution"}
        )
        | findings
      ]
    else
      findings
    end
  end

  defp add_network_finding(findings, command_decision, profile) do
    network =
      Map.get(command_decision, :network, Map.get(command_decision, "network", "disabled"))

    if Map.get(profile, "network_policy") == "deny_by_default" and network != "disabled" do
      [
        finding(
          "unapproved_network",
          "network access requires an explicit policy approval",
          "command.network",
          %{network: network, action: "block_execution"}
        )
        | findings
      ]
    else
      findings
    end
  end

  defp add_denylist_findings(findings, command_decision, profile, profiles_doc) do
    denied_classes =
      profile
      |> Map.get("denied_classes", [])
      |> MapSet.new()

    denylist_classes = Map.get(profiles_doc, "denylist_classes", %{})
    text = command_text(command_decision)

    Enum.reduce(denylist_classes, findings, fn {class_name, class_rule}, acc ->
      patterns = Map.get(class_rule, "blocked_patterns", [])

      if MapSet.member?(denied_classes, class_name) and denylist_match?(text, patterns) do
        [
          finding(
            "#{class_name}_blocked",
            Map.get(class_rule, "description", "command matches a denied policy class"),
            "command",
            %{
              denylist_class: class_name,
              matched_patterns: matching_patterns(text, patterns),
              action: "block_execution"
            }
          )
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp base_decision(profile_name, command_decision, opts) do
    %{
      schema_version: @decision_schema,
      matrix_ref: @matrix_ref,
      category: "runtime_policy",
      status: "blocked",
      profile: profile_name,
      adapter_mode: adapter_mode(opts),
      command_id: Map.get(command_decision, :command_id, Map.get(command_decision, "command_id")),
      command_ref: command_ref(command_decision),
      command_policy_decision: command_decision,
      findings: []
    }
  end

  defp finding(code, message, path, extra) do
    Map.merge(
      %{
        schema_version: @finding_schema,
        severity: "error",
        code: code,
        message: message,
        path: path,
        category: "runtime_policy"
      },
      extra
    )
  end

  defp family_aliases(family) do
    family
    |> to_string()
    |> String.trim()
    |> then(fn family ->
      [family, family |> String.split() |> List.first()]
    end)
  end

  defp denylist_match?(text, patterns), do: matching_patterns(text, patterns) != []

  defp matching_patterns(text, patterns) when is_list(patterns) do
    normalized_text = normalize_command_text(text)

    Enum.filter(patterns, fn pattern ->
      normalized_pattern = normalize_command_text(pattern)

      String.contains?(normalized_text, normalized_pattern) or
        ordered_terms_match?(normalized_text, String.split(normalized_pattern))
    end)
  end

  defp matching_patterns(_text, _patterns), do: []

  defp ordered_terms_match?(_text, []), do: false

  defp ordered_terms_match?(text, terms) do
    {_remaining, matched?} =
      Enum.reduce_while(terms, {text, true}, fn term, {remaining, _matched?} ->
        case :binary.match(remaining, term) do
          {index, length} ->
            {:cont,
             {binary_part(remaining, index + length, byte_size(remaining) - index - length), true}}

          :nomatch ->
            {:halt, {remaining, false}}
        end
      end)

    matched?
  end

  defp command_text(command_decision) do
    executable =
      Map.get(command_decision, :executable, Map.get(command_decision, "executable", ""))

    argv = Map.get(command_decision, :argv, Map.get(command_decision, "argv", []))

    [executable | List.wrap(argv)]
    |> Enum.map(&to_string/1)
    |> Enum.join(" ")
    |> String.trim()
  end

  defp normalize_command_text(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp command_ref(command_decision) do
    command_id = Map.get(command_decision, :command_id, Map.get(command_decision, "command_id"))
    if command_id, do: "cmd://#{command_id}", else: nil
  end

  defp profile_name(opts),
    do:
      opts
      |> Keyword.get(:profile, Keyword.get(opts, :policy_profile, "implement"))
      |> to_string()

  defp adapter_mode(opts), do: opts |> Keyword.get(:adapter_mode, "execute") |> to_string()
  defp autonomy_level(opts), do: opts |> Keyword.get(:autonomy_level, "L1") |> to_string()
  defp autonomy_rank(level), do: Map.get(@autonomy_order, to_string(level), 99)
end
