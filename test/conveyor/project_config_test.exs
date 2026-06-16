defmodule Conveyor.ProjectConfigTest do
  use ExUnit.Case, async: true

  alias Conveyor.ProjectConfig

  test "loads a valid config deterministically and exposes consumer commands" do
    assert {:ok, config, event} = ProjectConfig.load(fixture("valid.toml"))
    assert {:ok, config_again, event_again} = ProjectConfig.load(fixture("valid.toml"))

    assert config.digest == config_again.digest
    assert event.config_digest == event_again.config_digest
    assert event.status == "ok"
    assert event.schema_version == "conveyor.config.resolution@1"
    assert event.matrix_ref == "conveyor-quality-ci-evals-vmr.13"
    assert event.findings == []

    assert {:ok, verify} = ProjectConfig.command(config, "verify")
    assert verify["executable"] == "mix"
    assert verify["argv"] == ["test"]

    assert [%{"id" => "plan_audit"}] = ProjectConfig.commands_for(config, "plan_audit")
    assert [%{"id" => "agents_md"}] = ProjectConfig.commands_for(config, "agents_md")
    assert [%{"id" => "policy"}] = ProjectConfig.commands_for(config, "policy")
    assert [%{"id" => "verify"}] = ProjectConfig.commands_for(config, "verification")
  end

  test "rejects malformed config with actionable parse findings" do
    assert {:error, event} = ProjectConfig.load(fixture("malformed.toml"))

    assert event.status == "error"
    assert "invalid_value" in finding_codes(event)
    assert Enum.any?(event.findings, &(&1.line == 2 and &1.path == "project_key"))
  end

  test "rejects config with missing required command specs" do
    assert {:error, event} = ProjectConfig.load(fixture("missing_command.toml"))

    assert "missing_required_command" in finding_codes(event)

    assert Enum.any?(event.findings, fn finding ->
             finding.code == "missing_required_command" and finding.path == "commands.verify"
           end)
  end

  test "rejects duplicate profile fixtures" do
    assert {:error, event} = ProjectConfig.load(fixture("duplicate_profile.toml"))

    assert "duplicate_section" in finding_codes(event)
    assert Enum.any?(event.findings, &(&1.path == "policy.profiles.implement"))
  end

  test "does not let project config override a locked RunSpec after start" do
    assert {:ok, config, _event} = ProjectConfig.load(fixture("valid.toml"))

    assert {:error, digest_event} =
             ProjectConfig.load(fixture("valid.toml"),
               locked_run_spec: %{
                 "started_at" => "2026-06-16T00:00:00Z",
                 "project_config_digest" => "sha256:outdated"
               }
             )

    assert "locked_run_spec_config_digest_mismatch" in finding_codes(digest_event)

    assert {:error, override_event} =
             ProjectConfig.load(fixture("valid.toml"),
               locked_run_spec: %{
                 "started_at" => "2026-06-16T00:00:00Z",
                 "project_config_digest" => config.digest,
                 "project_config_overrides" => %{"policy_profile" => "release"}
               }
             )

    assert "locked_run_spec_project_config_override" in finding_codes(override_event)

    assert {:ok, _locked_config, locked_event} =
             ProjectConfig.load(fixture("valid.toml"),
               locked_run_spec: %{
                 "started_at" => "2026-06-16T00:00:00Z",
                 "project_config_digest" => config.digest
               }
             )

    assert locked_event.status == "ok"
  end

  defp fixture(name) do
    Path.expand("../support/fixtures/config/#{name}", __DIR__)
  end

  defp finding_codes(event), do: Enum.map(event.findings, & &1.code)
end
