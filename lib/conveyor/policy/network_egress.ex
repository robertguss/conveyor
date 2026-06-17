defmodule Conveyor.Policy.NetworkEgress do
  @moduledoc """
  Station-level network and egress policy decisions.

  This module never opens sockets. It classifies requested station egress before
  execution so the sandbox cannot use approved network modes to reach Conveyor
  Postgres, ledger, loopback, private networks, or other internal services.
  """

  @decision_schema "conveyor.network_egress_decision@1"
  @finding_schema "conveyor.network_egress_finding@1"
  @matrix_ref "conveyor-quality-ci-evals-vmr.13"

  @station_defaults %{
    "scout" => "none_except_quality_endpoint",
    "implement" => "none_except_required_provider_api",
    "verify" => "none_except_approved_bootstrap",
    "gate" => "none_except_approved_bootstrap",
    "canary" => "none"
  }

  @internal_names MapSet.new([
                    "localhost",
                    "host.docker.internal",
                    "postgres",
                    "conveyor-postgres",
                    "conveyor",
                    "ledger",
                    "repo",
                    "database"
                  ])

  def station_defaults, do: @station_defaults

  def evaluate(opts \\ []) do
    station_key = opts |> get(:station_key, "implement") |> to_string()
    network = opts |> get(:network, "disabled") |> to_string()
    target_host = target_host(opts)
    target_class = target_class(target_host)

    {status, reason, findings} =
      classify(%{
        station_key: station_key,
        network: network,
        target_host: target_host,
        target_class: target_class,
        opts: opts
      })

    %{
      "schema_version" => @decision_schema,
      "matrix_ref" => @matrix_ref,
      "category" => "network_egress",
      "status" => status,
      "station_key" => station_key,
      "station_default" => Map.get(@station_defaults, station_key, "none"),
      "network" => network,
      "target_host" => target_host,
      "target_class" => target_class,
      "reason" => reason,
      "findings" => findings
    }
  end

  defp classify(%{network: network, target_host: nil}) when network in ["disabled", "none"] do
    {"allowed", "network disabled and no egress target requested", []}
  end

  defp classify(%{target_class: "internal"} = attrs) do
    {"blocked", "internal Conveyor service egress is forbidden",
     [
       finding(
         "internal_service_egress_blocked",
         "sandbox egress cannot target Conveyor Postgres, ledger, loopback, private, or internal services",
         attrs
       )
     ]}
  end

  defp classify(%{network: network, target_host: target_host} = attrs)
       when network in ["disabled", "none"] and is_binary(target_host) do
    {"blocked", "network is disabled for this station command",
     [
       finding(
         "network_disabled_egress_blocked",
         "station command requested an egress target while network is disabled",
         attrs
       )
     ]}
  end

  defp classify(%{station_key: "scout"} = attrs) do
    approved_external(
      attrs,
      :approved_quality_hosts,
      "approved scout quality endpoint",
      "scout egress is limited to approved quality endpoints"
    )
  end

  defp classify(%{station_key: "implement"} = attrs) do
    if truthy?(get(attrs.opts, :provider_required, false)) do
      approved_external(
        attrs,
        :approved_provider_hosts,
        "approved implement provider API",
        "implement egress is limited to required approved provider APIs"
      )
    else
      blocked_unapproved(attrs, "implement station has no required provider API egress")
    end
  end

  defp classify(%{station_key: station_key} = attrs) when station_key in ["verify", "gate"] do
    if truthy?(get(attrs.opts, :bootstrap_approved, false)) do
      approved_external(
        attrs,
        :approved_bootstrap_hosts,
        "approved verify/gate bootstrap endpoint",
        "verify/gate egress is limited to approved bootstrap endpoints"
      )
    else
      blocked_unapproved(attrs, "#{station_key} station has no approved bootstrap egress")
    end
  end

  defp classify(%{station_key: "canary"} = attrs) do
    blocked_unapproved(attrs, "canary stations never allow network egress")
  end

  defp classify(attrs), do: blocked_unapproved(attrs, "station network egress is not approved")

  defp approved_external(attrs, approved_key, allowed_reason, blocked_reason) do
    approved_hosts = attrs.opts |> get(approved_key, []) |> Enum.map(&normalize_host/1)
    target_host = normalize_host(attrs.target_host)

    cond do
      attrs.target_class != "external" ->
        blocked_unapproved(attrs, blocked_reason)

      target_host in approved_hosts ->
        {"allowed", allowed_reason, []}

      true ->
        blocked_unapproved(attrs, blocked_reason)
    end
  end

  defp blocked_unapproved(attrs, reason) do
    {"blocked", reason,
     [
       finding(
         "unapproved_network_egress",
         "network egress requires explicit station policy approval for an external host",
         attrs
       )
     ]}
  end

  defp finding(code, message, attrs) do
    %{
      "schema_version" => @finding_schema,
      "category" => "network_egress",
      "severity" => "error",
      "code" => code,
      "message" => message,
      "station_key" => attrs.station_key,
      "network" => attrs.network,
      "target_host" => attrs.target_host,
      "target_class" => attrs.target_class,
      "action" => "block_execution"
    }
  end

  defp target_host(opts) do
    cond do
      present?(get(opts, :target_host, nil)) ->
        opts |> get(:target_host) |> normalize_host()

      present?(get(opts, :target_url, nil)) ->
        opts
        |> get(:target_url)
        |> to_string()
        |> URI.parse()
        |> Map.get(:host)
        |> normalize_host()

      true ->
        nil
    end
  end

  defp target_class(nil), do: "none"
  defp target_class(host), do: if(internal_host?(host), do: "internal", else: "external")

  defp internal_host?(host) do
    normalized = normalize_host(host)

    cond do
      normalized in @internal_names -> true
      String.ends_with?(normalized, ".internal") -> true
      String.ends_with?(normalized, ".local") -> true
      private_ip?(normalized) -> true
      true -> false
    end
  end

  defp private_ip?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {127, _, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {172, second, _, _}} when second >= 16 and second <= 31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {first, _, _, _, _, _, _, _}} when Bitwise.band(first, 0xFE00) == 0xFC00 -> true
      {:ok, {first, _, _, _, _, _, _, _}} when Bitwise.band(first, 0xFFC0) == 0xFE80 -> true
      _other -> false
    end
  end

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    host
    |> to_string()
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end

  defp get(map, key, default \\ nil)

  defp get(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp get(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when value in [1, "1", "true", "yes"], do: true
  defp truthy?(_value), do: false
end
