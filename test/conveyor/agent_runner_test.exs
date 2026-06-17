defmodule Conveyor.AgentRunnerTest do
  use ExUnit.Case, async: true

  defmodule FullFeaturedAdapter do
    @behaviour Conveyor.AgentRunner

    @impl Conveyor.AgentRunner
    def capability_snapshot(profile, opts),
      do: Conveyor.AgentRunner.capability_snapshot(profile, opts)

    @impl Conveyor.AgentRunner
    def start_session(run_spec, profile, _opts) do
      {:ok, %{run_spec_sha256: run_spec["run_spec_sha256"], profile: profile}}
    end

    @impl Conveyor.AgentRunner
    def stream_events(session, _opts), do: {:ok, [Map.put(session, :event_type, "started")]}

    @impl Conveyor.AgentRunner
    def request_command(_session, command_request, _opts), do: {:ok, command_request}

    @impl Conveyor.AgentRunner
    def cancel(_session, _reason), do: :ok

    @impl Conveyor.AgentRunner
    def capture_diff(_session, _opts), do: {:ok, %{diff_sha256: "sha256:diff"}}

    @impl Conveyor.AgentRunner
    def cost_report(_session, _opts), do: {:ok, %{total_usd: "0.01"}}

    @impl Conveyor.AgentRunner
    def resume_session(session_ref, _opts), do: {:ok, session_ref}
  end

  test "capabilities deterministically map to an autonomy ceiling" do
    capabilities = %{
      structured_output: true,
      diff_capture: true,
      pre_exec_command_policy: true,
      streaming_events: false,
      cancellation: false,
      session_resume: false,
      cost_reporting: true,
      mcp_support: false,
      slash_commands: false
    }

    first =
      Conveyor.AgentRunner.capability_snapshot(%{
        agent_profile_id: "profile-l1",
        adapter: "pi",
        capabilities: capabilities,
        autonomy_ceiling: "L1",
        known_limitations: ["no session resume", "no MCP"]
      })

    second =
      Conveyor.AgentRunner.capability_snapshot(%{
        "agent_profile_id" => "profile-l1",
        "adapter" => "pi",
        "capabilities" => capabilities |> Enum.reverse() |> Map.new(),
        "autonomy_ceiling" => "L1",
        "known_limitations" => ["no MCP", "no session resume"]
      })

    assert first == second
    assert first["theoretical_autonomy_ceiling"] == "L1"
    assert first["effective_autonomy_ceiling"] == "L1"

    assert first["negative_capabilities"] == [
             "streaming_events",
             "cancellation",
             "mcp_support",
             "slash_commands",
             "session_resume"
           ]
  end

  test "AgentProfile resource stores the structured capability model" do
    attrs =
      Conveyor.Domain.AgentProfile.create_attrs!(%{
        agent_profile_id: "profile-store",
        adapter: "codex",
        name: "Codex supervised patch",
        autonomy_ceiling: "L1",
        capabilities: l1_capabilities(),
        known_limitations: ["no slash command bridge"],
        metadata: %{owner: "runtime"}
      })

    assert attrs.external_id == "profile-store"
    assert attrs.name == "Codex supervised patch"
    assert attrs.payload["schema_version"] == "conveyor.agent_profile@1"
    assert attrs.payload["autonomy_ceiling"] == "L1"
    assert attrs.payload["capability_snapshot"]["category"] == "agent_profile_capability_snapshot"
    assert attrs.payload["metadata"] == %{"owner" => "runtime"}
  end

  test "RunSpec records negative capabilities inside the signed payload" do
    snapshot =
      Conveyor.AgentRunner.capability_snapshot(%{
        agent_profile_id: "profile-runspec",
        adapter: "pi",
        autonomy_ceiling: "L1",
        capabilities: l1_capabilities(),
        known_limitations: ["no streaming events"]
      })

    unsigned_run_spec = Conveyor.Domain.RunSpec.build!(run_spec_attrs(%{autonomy_level: "L1"}))

    run_spec =
      Conveyor.Domain.RunSpec.build!(
        run_spec_attrs(%{
          autonomy_level: "L1",
          agent_profile_capability_snapshot: snapshot
        })
      )

    refute run_spec["run_spec_sha256"] == unsigned_run_spec["run_spec_sha256"]
    assert run_spec["agent_profile_capability_snapshot"] == snapshot
    assert run_spec["negative_agent_capabilities"] == snapshot["negative_capabilities"]
    assert run_spec["agent_profile_autonomy_ceiling"] == "L1"
  end

  test "adapter can run below its theoretical ceiling under weaker host policy" do
    snapshot =
      FullFeaturedAdapter.capability_snapshot(
        %{
          agent_profile_id: "profile-full",
          adapter: "pi",
          autonomy_ceiling: "L4",
          capabilities: full_capabilities()
        },
        host_policy_autonomy_ceiling: "L1",
        credential_autonomy_ceiling: "L0"
      )

    assert snapshot["theoretical_autonomy_ceiling"] == "L4"
    assert snapshot["host_policy_autonomy_ceiling"] == "L1"
    assert snapshot["credential_autonomy_ceiling"] == "L0"
    assert snapshot["effective_autonomy_ceiling"] == "L0"

    assert %{
             "source" => "credential_posture",
             "ceiling" => "L0",
             "reason" => "credential_posture_below_theoretical_ceiling"
           } in snapshot["limiting_factors"]
  end

  test "RunSpec rejects a selected level above the effective agent ceiling" do
    snapshot =
      Conveyor.AgentRunner.capability_snapshot(%{
        agent_profile_id: "profile-observe-only",
        adapter: "pi",
        capabilities: Map.put(l1_capabilities(), :pre_exec_command_policy, false),
        autonomy_ceiling: "L1"
      })

    assert snapshot["effective_autonomy_ceiling"] == "L0"

    assert_raise ArgumentError, ~r/exceeds agent profile ceiling L0/, fn ->
      Conveyor.Domain.RunSpec.build!(
        run_spec_attrs(%{
          autonomy_level: "L1",
          agent_profile_capability_snapshot: snapshot
        })
      )
    end
  end

  defp l1_capabilities do
    %{
      streaming_events: false,
      pre_exec_command_policy: true,
      cancellation: false,
      diff_capture: true,
      cost_reporting: false,
      mcp_support: false,
      slash_commands: false,
      structured_output: true,
      session_resume: false
    }
  end

  defp full_capabilities do
    Map.new(Conveyor.AgentRunner.capability_keys(), &{&1, true})
  end

  defp run_spec_attrs(overrides) do
    %{
      run_id: "run-agent-profile-demo",
      project_id: "project-conveyor",
      base_commit: "abc1234",
      slice_id: "slice-agent-profile",
      autonomy_level: "L1",
      contract_digests: digest_set(),
      stations: [
        %{
          station_key: "implement",
          intent: "Produce a patch under the adapter capability ceiling.",
          inputs: %{agent_profile: "profile-runspec"},
          outputs: %{patch_set: "expected"}
        }
      ]
    }
    |> Map.merge(overrides)
  end

  defp digest_set do
    Map.new(Conveyor.Domain.RunSpec.digest_keys(), fn key -> {key, "sha256:#{key}-v1"} end)
  end
end
