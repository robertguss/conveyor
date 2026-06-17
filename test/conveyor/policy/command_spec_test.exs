defmodule Conveyor.Policy.CommandSpecTest do
  use ExUnit.Case, async: true

  alias Conveyor.Policy.CommandSpec

  test "normalizes structured command specs and records an allow decision" do
    root = tmp_root("allowed")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "tmp/out"))

    assert {:ok, decision} =
             CommandSpec.normalize(valid_command(), policy_opts(root, allowed_families: ["mix"]))

    assert decision.schema_version == "conveyor.command_policy_decision@1"
    assert decision.status == "allowed"
    assert decision.command_id == "verify"
    assert decision.executable_path == "/container/bin/mix"
    assert decision.executable_family == "mix"
    assert decision.cwd == root
    assert decision.network == "disabled"
    assert decision.env_keys == ["PHX_SECRET_KEY_BASE"]
    assert decision.findings == []

    assert [%{access: "read", path: read_root}] = decision.read_roots
    assert read_root == Path.join(root, "lib")

    assert [%{access: "write", path: write_root}] = decision.write_roots
    assert write_root == Path.join(root, "tmp/out")
  end

  test "rejects raw shell strings unless explicitly allowed" do
    root = tmp_root("raw-shell")

    assert {:error,
            %{
              status: "blocked",
              command_id: "raw_shell",
              findings: [%{code: "raw_shell_rejected", action: "block_execution"}]
            }} = CommandSpec.normalize("mix test && curl https://example.test", policy_opts(root))

    assert {:ok, decision} =
             CommandSpec.normalize(
               "mix test",
               policy_opts(root,
                 allow_raw_shell: true,
                 allowed_families: ["sh"],
                 shell_executable: "/bin/sh"
               )
             )

    assert decision.status == "allowed"
    assert decision.executable == "/bin/sh"
    assert decision.argv == ["-lc", "mix test"]
  end

  test "rejects cwd and roots that resolve outside the project through symlinks" do
    root = tmp_root("path-escape")
    outside = tmp_root("outside")
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(root, "safe"))
    File.ln_s!(outside, Path.join(root, "escape"))

    command =
      valid_command()
      |> Map.put("cwd", ".")
      |> Map.put("write_roots", ["../outside", "escape"])

    assert {:error, decision} =
             CommandSpec.normalize(command, policy_opts(root, allowed_families: ["mix"]))

    assert decision.status == "blocked"
    assert Enum.any?(decision.findings, &(&1.code == "path_outside_project_root"))

    escaped_paths =
      decision.findings
      |> Enum.filter(&(&1.code == "path_outside_project_root"))
      |> Enum.map(& &1.normalized_path)

    assert Enum.any?(escaped_paths, &String.starts_with?(&1, outside))
  end

  test "rejects executable families that are not configured for the policy profile" do
    root = tmp_root("family")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "tmp/out"))

    command = Map.put(valid_command(), "executable", "bash")

    assert {:error, decision} =
             CommandSpec.normalize(
               command,
               policy_opts(root, allowed_families: ["mix"], executable_path: "/bin/bash")
             )

    assert decision.status == "blocked"

    assert Enum.any?(decision.findings, fn finding ->
             finding.code == "disallowed_command_family" and finding.family == "bash"
           end)
  end

  test "reports unresolved executable and invalid network as structured findings" do
    root = tmp_root("findings")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "tmp/out"))

    command =
      valid_command()
      |> Map.put("executable", "missing-tool")
      |> Map.put("network", "public")

    assert {:error, decision} =
             CommandSpec.normalize(
               command,
               policy_opts(root, allowed_families: ["missing-tool"], executable_path: nil)
             )

    assert decision.status == "blocked"
    assert decision.executable_path == nil

    assert Enum.any?(decision.findings, fn finding ->
             finding.schema_version == "conveyor.command_policy_finding@1" and
               finding.code == "executable_not_found" and
               finding.action == "block_execution"
           end)

    assert Enum.any?(decision.findings, &(&1.code == "invalid_network_mode"))
  end

  defp valid_command do
    %{
      "id" => "verify",
      "executable" => "mix",
      "argv" => ["test"],
      "cwd" => "lib/..",
      "env_keys" => ["PHX_SECRET_KEY_BASE"],
      "read_roots" => ["lib"],
      "write_roots" => ["tmp/out"],
      "network" => "disabled",
      "timeout_ms" => 30_000
    }
  end

  defp policy_opts(root, overrides \\ []) do
    executable_path = Keyword.get(overrides, :executable_path, "/container/bin/mix")

    [
      project_root: root,
      allowed_families: Keyword.get(overrides, :allowed_families, []),
      allow_raw_shell: Keyword.get(overrides, :allow_raw_shell, false),
      shell_executable: Keyword.get(overrides, :shell_executable, "/bin/sh"),
      executable_resolver: fn
        _executable -> executable_path
      end
    ]
  end

  defp tmp_root(name) do
    Path.join([
      System.tmp_dir!(),
      "conveyor-command-spec",
      "#{System.unique_integer([:positive])}-#{name}"
    ])
  end
end
