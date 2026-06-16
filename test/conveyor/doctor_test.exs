defmodule Conveyor.DoctorTest do
  use ExUnit.Case, async: true

  alias Conveyor.Doctor

  @pass_probe %{
    runtime: :pass,
    dependencies: :pass,
    postgres: :pass,
    oban: :pass,
    docker: :pass,
    git: :pass,
    pi_image: :pass,
    provider_credentials: :pass,
    codescent: :pass,
    sample_repo: :pass,
    agents_md: :pass,
    project_commands: :pass,
    policy_profiles: :pass,
    artifact_writable: :pass,
    worker_mount_secrets: :pass
  }

  test "returns a passing structured report with versions and transcript" do
    report =
      Doctor.run(
        project_root: fixture("passing"),
        config_path: config_fixture(),
        probe: @pass_probe
      )

    assert report.schema_version == "conveyor.doctor.report@1"
    assert report.matrix_ref == "conveyor-quality-ci-evals-vmr.13"
    assert report.status == "pass"
    assert report.exit_code == 0
    assert report.runtime_versions.elixir
    assert report.runtime_versions.otp
    assert length(report.checks) == 16
    assert report.transcript =~ "PASS | runtime"
  end

  test "missing Postgres is a blocking failure with exit code 4" do
    report =
      failing_report(
        :postgres,
        {:fail, "missing_postgres", "Postgres is down", "Start Postgres 16."}
      )

    assert report.status == "fail"
    assert report.exit_code == Doctor.failure_exit_code()
    assert failing_category(report, "missing_postgres").next_action == "Start Postgres 16."
  end

  test "missing rootless Docker is a blocking failure" do
    report =
      failing_report(
        :docker,
        {:fail, "no_docker_rootless", "Docker rootless is unavailable",
         "Install rootless Docker."}
      )

    assert report.status == "fail"
    assert failing_category(report, "no_docker_rootless").key == "docker_rootless"
  end

  test "dirty sample repo is a labeled blocking failure" do
    report =
      failing_report(
        :sample_repo,
        {:fail, "dirty_sample_repo", "Sample repo has changes",
         "Commit or inspect sample changes."}
      )

    assert report.status == "fail"

    assert failing_category(report, "dirty_sample_repo").next_action ==
             "Commit or inspect sample changes."
  end

  test "AGENTS.md lint failure is labeled and blocking" do
    report =
      failing_report(
        :agents_md,
        {:fail, "agents_md_lint_fail", "AGENTS.md is incomplete", "Regenerate AGENTS.md."}
      )

    assert report.status == "fail"
    assert failing_category(report, "agents_md_lint_fail").key == "agents_md"
  end

  test "missing gate-blocking tool is labeled and blocking" do
    report =
      failing_report(
        :codescent,
        {:fail, "missing_gate_blocking_tool", "CodeScent is required", "Install CodeScent."}
      )

    assert report.status == "fail"
    assert failing_category(report, "missing_gate_blocking_tool").key == "codescent"
  end

  test "optional adapters warn without failing the doctor" do
    probe =
      @pass_probe
      |> Map.put(
        :provider_credentials,
        {:warn, "optional_provider_credentials_missing", "No provider credentials",
         "No action needed."}
      )
      |> Map.put(
        :codescent,
        {:warn, "optional_codescent_missing", "No CodeScent", "No action needed."}
      )

    report =
      Doctor.run(project_root: fixture("passing"), config_path: config_fixture(), probe: probe)

    assert report.status == "warn"
    assert report.exit_code == 0
    assert Enum.any?(report.checks, &(&1.category == "optional_provider_credentials_missing"))
    assert Enum.any?(report.checks, &(&1.category == "optional_codescent_missing"))
  end

  defp failing_report(key, failure) do
    probe = Map.put(@pass_probe, key, failure)
    Doctor.run(project_root: fixture("passing"), config_path: config_fixture(), probe: probe)
  end

  defp failing_category(report, category) do
    Enum.find(report.checks, &(&1.category == category))
  end

  defp fixture(name) do
    Path.expand("../support/fixtures/doctor/#{name}", __DIR__)
  end

  defp config_fixture do
    Path.expand("../support/fixtures/config/valid.toml", __DIR__)
  end
end
