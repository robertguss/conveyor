defmodule Conveyor.CodeQualityAdapterTest do
  use ExUnit.Case, async: true

  alias Conveyor.CodeQualityAdapter

  test "noop profile emits advisory ContextPack and gate quality refs" do
    event = CodeQualityAdapter.run_profile("sample_noop", CodeQualityAdapter.Noop.profile())

    assert event.schema_version == "conveyor.code_quality_adapter.run@1"
    assert event.matrix_ref == "conveyor-quality-ci-evals-vmr.13"
    assert event.adapter == "noop"
    assert event.status == "advisory_pass"
    assert event.blocks_gate == false

    assert event.quality_refs.context_pack.schema_version == "conveyor.context_pack.quality_ref@1"
    assert event.quality_refs.context_pack.profile_id == "sample_noop"
    assert event.quality_refs.context_pack.required == false

    assert event.quality_refs.gate.schema_version == "conveyor.gate.quality_ref@1"
    assert event.quality_refs.gate.profile_id == "sample_noop"
    assert event.quality_refs.gate.required == false
    assert event.quality_refs.gate.advisory == true

    assert Enum.any?(event.findings, &(&1.code == "noop_quality_adapter"))
  end

  test "local Python advisory mode reports missing local tool without blocking the gate" do
    event =
      CodeQualityAdapter.run_profile(
        "sample_local_python",
        CodeQualityAdapter.LocalPython.profile(),
        tool_resolver: fn _tool -> nil end
      )

    assert event.adapter == "local_python"
    assert event.mode == "advisory"
    assert event.status == "advisory_warning"
    assert event.blocks_gate == false

    assert Enum.any?(event.findings, fn finding ->
             finding.code == "missing_quality_tool" and finding.severity == "warn" and
               finding.blocks_gate == false
           end)
  end

  test "blocking CodeScent mode turns missing requirements into gate-blocking findings" do
    event =
      CodeQualityAdapter.run_profile("codescent", CodeQualityAdapter.CodeScent.profile(),
        tool_resolver: fn _tool -> nil end,
        env: %{}
      )

    assert event.adapter == "codescent"
    assert event.mode == "blocking"
    assert event.status == "blocked"
    assert event.blocks_gate == true

    assert Enum.any?(event.findings, fn finding ->
             finding.code == "missing_quality_tool" and finding.severity == "error" and
               finding.blocks_gate == true
           end)

    assert Enum.any?(event.findings, fn finding ->
             finding.code == "missing_quality_credential" and finding.severity == "error" and
               finding.blocks_gate == true
           end)
  end
end
