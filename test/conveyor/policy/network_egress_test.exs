defmodule Conveyor.Policy.NetworkEgressTest do
  use ExUnit.Case, async: true

  alias Conveyor.Policy.Engine
  alias Conveyor.Policy.NetworkEgress

  test "records station defaults" do
    assert NetworkEgress.station_defaults() == %{
             "scout" => "none_except_quality_endpoint",
             "implement" => "none_except_required_provider_api",
             "verify" => "none_except_approved_bootstrap",
             "gate" => "none_except_approved_bootstrap",
             "canary" => "none"
           }
  end

  test "blocks Conveyor Postgres, ledger, loopback, private, and internal service egress" do
    for host <- ["127.0.0.1", "postgres", "ledger", "10.1.2.3", "service.internal"] do
      decision =
        NetworkEgress.evaluate(
          station_key: "implement",
          network: "controlled",
          target_host: host,
          provider_required: true,
          approved_provider_hosts: [host]
        )

      assert decision["status"] == "blocked"
      assert decision["target_class"] == "internal"

      assert Enum.any?(decision["findings"], fn finding ->
               finding["code"] == "internal_service_egress_blocked" and
                 finding["action"] == "block_execution"
             end)
    end
  end

  test "allows only approved external provider egress for implement stations" do
    allowed =
      NetworkEgress.evaluate(
        station_key: "implement",
        network: "controlled",
        target_host: "api.openai.com",
        provider_required: true,
        approved_provider_hosts: ["api.openai.com"]
      )

    blocked =
      NetworkEgress.evaluate(
        station_key: "implement",
        network: "controlled",
        target_host: "example.com",
        provider_required: true,
        approved_provider_hosts: ["api.openai.com"]
      )

    assert allowed["status"] == "allowed"
    assert allowed["target_class"] == "external"
    assert blocked["status"] == "blocked"
    assert hd(blocked["findings"])["code"] == "unapproved_network_egress"
  end

  test "allows scout quality and verify bootstrap endpoints only when approved" do
    scout =
      NetworkEgress.evaluate(
        station_key: "scout",
        network: "controlled",
        target_url: "https://quality.example.com/check",
        approved_quality_hosts: ["quality.example.com"]
      )

    verify =
      NetworkEgress.evaluate(
        station_key: "verify",
        network: "controlled",
        target_host: "cache.example.com",
        bootstrap_approved: true,
        approved_bootstrap_hosts: ["cache.example.com"]
      )

    canary =
      NetworkEgress.evaluate(
        station_key: "canary",
        network: "controlled",
        target_host: "quality.example.com",
        approved_quality_hosts: ["quality.example.com"]
      )

    assert scout["status"] == "allowed"
    assert verify["status"] == "allowed"
    assert canary["status"] == "blocked"
    assert canary["reason"] == "canary stations never allow network egress"
  end

  test "Policy.Engine records blocked network decisions and allows approved external egress" do
    command = command_decision("controlled")
    profile = policy_profile()
    profiles_doc = %{"denylist_classes" => %{}}

    assert {:error, blocked} =
             Engine.evaluate(command, profile, profiles_doc,
               station_key: "implement",
               target_host: "127.0.0.1",
               provider_required: true,
               approved_provider_hosts: ["api.openai.com"]
             )

    assert blocked.status == "blocked"

    assert Enum.any?(blocked.findings, fn finding ->
             finding.code == "network_egress_blocked" and
               finding.network_decision["target_class"] == "internal"
           end)

    assert {:ok, allowed} =
             Engine.evaluate(command, profile, profiles_doc,
               station_key: "implement",
               target_host: "api.openai.com",
               provider_required: true,
               approved_provider_hosts: ["api.openai.com"]
             )

    assert allowed.status == "allowed"
    assert allowed.findings == []
  end

  defp command_decision(network) do
    %{
      schema_version: "conveyor.command_policy_decision@1",
      status: "allowed",
      command_id: "provider-call",
      executable: "curl",
      argv: ["https://api.openai.com/v1/models"],
      network: network
    }
  end

  defp policy_profile do
    %{
      "autonomy_ceiling" => "L1",
      "network_policy" => "deny_by_default",
      "allowed_command_families" => ["curl"],
      "denied_classes" => []
    }
  end
end
