defmodule Conveyor.OperatorTasksTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Conveyor.OperatorTasks

  @expected_commands ~w(
    init
    doctor
    plan_audit
    seed_sample
    demo
    show
    run_slice
    verify
    gate_canary
    report
    replay
    contract_diff
    ci
  )

  @new_shell_commands @expected_commands -- ["doctor", "plan_audit"]

  test "registry covers every Phase 0/1 operator command shell" do
    assert OperatorTasks.command_ids() == @expected_commands

    for spec <- OperatorTasks.command_specs() do
      assert spec.task == "conveyor.#{spec.id}"
      assert spec.shortdoc != ""
      assert spec.description != ""
      assert spec.matrix_ref == "conveyor-quality-ci-evals-vmr.13"
      assert spec.json_capable == true
      assert spec.live_provider_required == false
      assert spec.provider_requirements == []
      assert is_integer(spec.exit_code)
      assert is_binary(spec.service_module)
    end
  end

  test "every command emits a structured provider-free smoke result" do
    for command <- @expected_commands do
      result = OperatorTasks.smoke_result(command)

      assert result.schema_version == "conveyor.operator_task.smoke@1"
      assert result.matrix_ref == "conveyor-quality-ci-evals-vmr.13"
      assert result.command == command
      assert result.task == "conveyor.#{command}"
      assert result.exit_code == 0
      assert result.json_capable == true
      assert result.live_provider_required == false
      assert result.provider_requirements == []
      assert result.provider_mode == "none"
      assert result.smoke_result == "pass"
    end
  end

  test "every operator command has help text and JSON output guidance" do
    for command <- @expected_commands do
      help = OperatorTasks.help!(command)

      assert help =~ "mix conveyor.#{command} --json"
      assert help =~ "--output PATH"
      assert help =~ "contact live providers"
    end
  end

  test "new Mix task shells are compiled and expose moduledocs" do
    for command <- @new_shell_commands do
      module = task_module!(command)
      spec = OperatorTasks.spec!(command)

      assert Code.ensure_loaded?(module)
      assert {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(module)
      assert moduledoc =~ "mix #{spec.task} --json"
      assert moduledoc =~ "never contacts live providers"
    end
  end

  test "task shells print JSON and can write structured smoke output" do
    output_path =
      Path.join([
        System.tmp_dir!(),
        "conveyor-operator-task-test",
        "#{System.unique_integer([:positive])}-init.json"
      ])

    json_output =
      capture_io(fn ->
        Mix.Tasks.Conveyor.Init.run(["--json", "--output", output_path])
      end)

    assert Jason.decode!(json_output)["command"] == "init"
    assert Jason.decode!(File.read!(output_path))["command"] == "init"
  end

  test "task shells reject unstable positional arguments" do
    assert_raise Mix.Error, ~r/unexpected arguments/, fn ->
      Mix.Tasks.Conveyor.Init.run(["extra"])
    end
  end

  defp task_module!(command) do
    command
    |> OperatorTasks.spec!()
    |> Map.fetch!(:task_module)
    |> then(&String.to_existing_atom("Elixir." <> &1))
  end
end
