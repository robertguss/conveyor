defmodule Conveyor.Policy.DockerSandboxTest do
  use ExUnit.Case, async: true

  alias Conveyor.Policy.DockerSandbox

  test "declares restrictive Docker defaults and applies required constraints" do
    report = DockerSandbox.evaluate(host_capabilities: full_capabilities())
    defaults = report["defaults"]
    constraints = constraints_by_name(report)

    assert report["schema_version"] == "conveyor.docker_sandbox_report@1"
    assert report["matrix_ref"] == "conveyor-quality-ci-evals-vmr.13"
    assert report["status"] == "pass"
    assert defaults["user"] == "non-root"
    assert defaults["privileged"] == false
    assert defaults["network"] == "none"
    assert Enum.any?(defaults["forbidden_mounts"], &(&1["source"] == "/var/run/docker.sock"))
    assert Enum.any?(defaults["forbidden_mounts"], &(&1["source"] == "$HOME"))

    assert %{"mode" => "rw"} = Enum.find(defaults["mounts"], &(&1["source"] == "workspace"))
    assert %{"mode" => "ro"} = Enum.find(defaults["mounts"], &(&1["source"] == "contracts"))
    assert %{"mode" => "ro"} = Enum.find(defaults["mounts"], &(&1["source"] == "policies"))
    assert %{"mode" => "ro"} = Enum.find(defaults["mounts"], &(&1["source"] == ".conveyor"))

    for constraint <- [
          "non_root_user",
          "no_privileged",
          "no_docker_socket",
          "no_host_home_mount",
          "read_only_contract_mounts",
          "workspace_rw",
          "network_none",
          "no_new_privileges",
          "resource_limits"
        ] do
      assert constraints[constraint]["status"] == "applied"
      assert constraints[constraint]["required"] == true
    end
  end

  test "fails closed when a required sandbox constraint is unavailable" do
    capabilities = Map.put(full_capabilities(), "supports_network_none", false)
    report = DockerSandbox.evaluate(host_capabilities: capabilities)
    constraints = constraints_by_name(report)

    assert report["status"] == "fail"
    assert constraints["network_none"]["status"] == "failed"
    assert constraints["network_none"]["required"] == true

    assert Enum.any?(report["findings"], fn finding ->
             finding["code"] == "network_none_unavailable" and
               finding["action"] == "block_profile"
           end)
  end

  test "records unavailable optional seccomp and AppArmor as degraded constraints" do
    capabilities =
      full_capabilities()
      |> Map.put("supports_seccomp", false)
      |> Map.put("supports_apparmor", false)

    report = DockerSandbox.evaluate(host_capabilities: capabilities)

    assert report["status"] == "warn"

    assert Enum.all?(
             Enum.filter(report["findings"], &(&1["constraint"] in ["seccomp", "apparmor"])),
             &(&1["severity"] == "warning" and &1["action"] == "record_degraded_sandbox")
           )
  end

  test "fails selected profile when optional security options are required" do
    capabilities = Map.put(full_capabilities(), "supports_apparmor", false)

    report =
      DockerSandbox.evaluate(
        host_capabilities: capabilities,
        required_security_options: ["apparmor"]
      )

    assert report["status"] == "fail"

    assert Enum.any?(report["findings"], fn finding ->
             finding["code"] == "apparmor_unavailable" and finding["action"] == "block_profile"
           end)
  end

  test "doctor can emit structured sandbox capability reports" do
    report =
      Conveyor.Doctor.run(
        project_root: fixture("passing"),
        config_path: config_fixture(),
        probe: Map.put(pass_probe(), :docker, {:capabilities, full_capabilities()})
      )

    docker_check = Enum.find(report.checks, &(&1.key == "docker_sandbox"))

    assert report.status == "pass"
    assert docker_check.category == "docker_sandbox_constraints_available"
    assert docker_check.evidence.sandbox_report["host_capabilities"]["docker_available"] == true
  end

  test "doctor fails when required Docker sandbox capabilities are missing" do
    capabilities = Map.put(full_capabilities(), "supports_no_new_privileges", false)

    report =
      Conveyor.Doctor.run(
        project_root: fixture("passing"),
        config_path: config_fixture(),
        probe: Map.put(pass_probe(), :docker, {:capabilities, capabilities})
      )

    docker_check = Enum.find(report.checks, &(&1.key == "docker_sandbox"))

    assert report.status == "fail"
    assert docker_check.category == "docker_sandbox_constraints_unavailable"

    assert Enum.any?(docker_check.evidence.sandbox_report["findings"], fn finding ->
             finding["code"] == "no_new_privileges_unavailable"
           end)
  end

  defp constraints_by_name(report) do
    Map.new(report["applied_constraints"], &{&1["constraint"], &1})
  end

  defp full_capabilities do
    %{
      "docker_available" => true,
      "rootless" => true,
      "supports_non_root_user" => true,
      "supports_read_only_mounts" => true,
      "supports_network_none" => true,
      "supports_no_new_privileges" => true,
      "supports_resource_limits" => true,
      "supports_seccomp" => true,
      "supports_apparmor" => true
    }
  end

  defp pass_probe do
    %{
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
  end

  defp fixture(name) do
    Path.expand("../../support/fixtures/doctor/#{name}", __DIR__)
  end

  defp config_fixture do
    Path.expand("../../support/fixtures/config/valid.toml", __DIR__)
  end
end
