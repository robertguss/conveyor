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

    assert config.sample_repository["default_code_quality_profile"] == "sample_noop"

    assert config.sample_repository["local_advisory_code_quality_profile"] ==
             "sample_local_python"

    assert config.sample_repository["quality_ref_consumers"] == ["context_pack", "gate"]

    assert config.code_quality_profiles["sample_noop"]["adapter"] == "noop"
    assert config.code_quality_profiles["sample_noop"]["mode"] == "advisory"
    assert config.code_quality_profiles["sample_noop"]["blocking"] == false

    assert config.code_quality_profiles["sample_local_python"]["adapter"] == "local_python"
    assert config.code_quality_profiles["sample_local_python"]["required_tools"] == ["python3"]
    assert config.code_quality_profiles["sample_local_python"]["blocking"] == false

    assert config.code_quality_profiles["codescent"]["adapter"] == "codescent"
    assert config.code_quality_profiles["codescent"]["blocking"] == true
    assert config.code_quality_profiles["codescent"]["required_tools"] == ["codescent"]
    assert config.code_quality_profiles["codescent"]["required_env_keys"] == ["CODESCENT_API_KEY"]
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

  test "rejects blocking quality adapters without explicit requirements" do
    assert {:error, event} =
             ProjectConfig.load(fixture("blocking_quality_missing_requirements.toml"))

    assert "blocking_quality_requirements_not_explicit" in finding_codes(event)

    assert Enum.any?(event.findings, fn finding ->
             finding.code == "blocking_quality_requirements_not_explicit" and
               finding.path == "code_quality.profiles.codescent_blocking.required_tools"
           end)

    assert Enum.any?(event.findings, fn finding ->
             finding.code == "blocking_quality_requirements_not_explicit" and
               finding.path == "code_quality.profiles.codescent_blocking.required_env_keys"
           end)
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
