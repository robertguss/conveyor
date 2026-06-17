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

  test "normalizes every adapter event into the Conveyor event envelope" do
    raw_events =
      Conveyor.AgentRunner.adapter_event_types()
      |> Enum.with_index(1)
      |> Enum.map(fn {event_type, index} ->
        %{
          type: event_type,
          raw_ref: "adapter-raw://session-abc/#{index}",
          payload: %{index: index, body: "payload #{index}"}
        }
      end)

    events =
      Conveyor.AgentRunner.normalize_adapter_events!(raw_events, event_context(),
        start_sequence: 41
      )

    assert Enum.map(events, & &1["event_type"]) == Conveyor.AgentRunner.adapter_event_types()
    assert Enum.map(events, & &1["seq"]) == Enum.to_list(41..54)

    for event <- events do
      assert event["event_version"] == Conveyor.AgentRunner.event_envelope_version()
      assert event["run_spec_sha256"] == "sha256:run-spec-agent-events"
      assert event["run_attempt_id"] == "run-attempt-agent-events"
      assert event["agent_session_id"] == "agent-session-agent-events"
      assert event["adapter"] == "codex"
      assert event["adapter_session_id"] == "codex-session-abc"
      assert event["raw_ref"] =~ "adapter-raw://session-abc/"

      assert event["trace_context"] == %{
               "parent_span_id" => "00f067aa0ba902b7",
               "span_id" => "18bf92f3577b34d1",
               "trace_id" => "4bf92f3577b34da6a3ce929d0e0e4736",
               "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-18bf92f3577b34d1-01"
             }
    end

    assert List.first(events)["payload"] == %{"body" => "payload 1", "index" => 1}
  end

  test "emits a structured normalized event log" do
    events =
      Conveyor.AgentRunner.normalize_adapter_events!(
        [
          %{event_type: :session_started},
          %{event_type: "message_delta"},
          %{event_type: "session_completed"}
        ],
        event_context()
      )

    assert Conveyor.AgentRunner.normalized_event_log(events) == %{
             "schema_version" => "conveyor.normalized_agent_event_log@1",
             "matrix_ref" => "conveyor-quality-ci-evals-vmr.13",
             "event_count" => 3,
             "event_types" => ["session_started", "message_delta", "session_completed"],
             "first_seq" => 1,
             "last_seq" => 3,
             "events" => events
           }
  end

  test "fake adapter declares deterministic CI capabilities without credentials" do
    snapshot =
      Conveyor.AgentRunner.FakeAdapter.capability_snapshot(%{
        agent_profile_id: "fake-implementer",
        role: "implementer"
      })

    assert snapshot["adapter"] == "fake"
    assert snapshot["effective_autonomy_ceiling"] == "L2"
    assert snapshot["capabilities"]["streaming_events"]
    assert snapshot["capabilities"]["structured_output"]
    assert snapshot["capabilities"]["cancellation"]
    assert "no provider credentials" in snapshot["known_limitations"]
  end

  test "fake adapter produces deterministic implementer and reviewer fixture replays" do
    for scenario <- Conveyor.AgentRunner.fake_scenarios(),
        role <- ["implementer", "reviewer"] do
      replay =
        Conveyor.AgentRunner.fake_scenario_replay_log!(scenario, fake_event_context(),
          role: role,
          start_sequence: 9
        )

      event_log = replay["event_log"]

      assert replay["schema_version"] == "conveyor.fake_agent_runner_replay@1"
      assert replay["scenario"] == scenario
      assert replay["role"] == role
      assert replay["credential_requirement"] == "none"
      assert event_log["schema_version"] == "conveyor.normalized_agent_event_log@1"
      assert event_log["matrix_ref"] == "conveyor-quality-ci-evals-vmr.13"
      assert event_log["first_seq"] == 9
      assert event_log["last_seq"] == 8 + event_log["event_count"]
      assert "session_started" in event_log["event_types"]
      assert "final_response" in event_log["event_types"]
      assert "session_completed" in event_log["event_types"]

      for event <- event_log["events"] do
        assert event["event_version"] == Conveyor.AgentRunner.event_envelope_version()
        assert event["run_spec_sha256"] == "sha256:run-spec-agent-events"
        assert event["run_attempt_id"] == "run-attempt-agent-events"
        assert event["agent_session_id"] == "agent-session-agent-events"
        assert event["adapter"] == "fake"
        assert event["adapter_session_id"] == "fake-session-replay"
        assert event["payload"]["role"] in [role, nil]
      end
    end
  end

  test "fake scenarios cover all deterministic outcomes" do
    summaries =
      Map.new(Conveyor.AgentRunner.fake_scenarios(), fn scenario ->
        replay = Conveyor.AgentRunner.fake_scenario_replay_log!(scenario, event_context())
        {scenario, replay["event_log"]["events"]}
      end)

    assert event_payload(summaries, "known_good_patch", "file_change_observed")["patch_label"] ==
             "known_good"

    assert event_payload(summaries, "labeled_bad_patch", "file_change_observed")[
             "patch_label"
           ] ==
             "bad_patch_missing_acceptance"

    assert event_payload(summaries, "malformed_output", "adapter_error")["failure_category"] ==
             "malformed_output"

    assert event_payload(summaries, "timeout", "adapter_error")["failure_category"] == "timeout"
    assert Enum.any?(summaries["cancellation"], &(&1["event_type"] == "cancel_acknowledged"))
    assert event_payload(summaries, "no_diff", "message_completed")["patch_label"] == "no_diff"
  end

  test "fake adapter callbacks replay scenarios without live provider state" do
    run_spec = %{"run_spec_sha256" => "sha256:fake-run-spec-callbacks"}
    profile = %{agent_profile_id: "fake-callbacks", scenario: "known_good_patch"}

    assert {:ok, first} =
             Conveyor.AgentRunner.FakeAdapter.start_session(run_spec, profile,
               role: "implementer"
             )

    assert {:ok, second} =
             Conveyor.AgentRunner.FakeAdapter.start_session(run_spec, profile,
               role: "implementer"
             )

    assert first.adapter_session_id == second.adapter_session_id
    assert first.credential_requirement == "none"
    assert {:ok, events} = Conveyor.AgentRunner.FakeAdapter.stream_events(first, [])

    assert Enum.map(events, & &1.event_type) == [
             "session_started",
             "file_change_observed",
             "final_response",
             "session_completed"
           ]

    assert {:ok, diff} = Conveyor.AgentRunner.FakeAdapter.capture_diff(first, [])
    assert diff["status"] == "changed"
    assert diff["diff_sha256"] == "sha256:fake-known-good-patch"
    assert {:ok, cost} = Conveyor.AgentRunner.FakeAdapter.cost_report(first, [])
    assert cost["total_usd"] == "0.00"
    assert cost["credential_requirement"] == "none"
    assert :ok = Conveyor.AgentRunner.FakeAdapter.cancel(first, :test_cancel)
  end

  test "adapter event normalization requires stable context and known event types" do
    assert_raise ArgumentError, ~r/missing run_attempt_id/, fn ->
      Conveyor.AgentRunner.normalize_adapter_events!(
        [%{event_type: "session_started"}],
        Map.delete(event_context(), :run_attempt_id)
      )
    end

    assert_raise ArgumentError, ~r/unknown adapter event type/, fn ->
      Conveyor.AgentRunner.normalize_adapter_events!(
        [%{event_type: "unrecognized_adapter_event"}],
        event_context()
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

  defp event_payload(summaries, scenario, event_type) do
    summaries
    |> Map.fetch!(scenario)
    |> Enum.find(&(&1["event_type"] == event_type))
    |> Map.fetch!("payload")
  end

  defp event_context do
    %{
      run_spec_sha256: "sha256:run-spec-agent-events",
      run_attempt_id: "run-attempt-agent-events",
      agent_session_id: "agent-session-agent-events",
      adapter: "codex",
      adapter_session_id: "codex-session-abc",
      trace_context: %{
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
        span_id: "18bf92f3577b34d1",
        parent_span_id: "00f067aa0ba902b7",
        traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-18bf92f3577b34d1-01"
      }
    }
  end

  defp fake_event_context do
    event_context()
    |> Map.put(:adapter, "fake")
    |> Map.put(:adapter_session_id, "fake-session-replay")
  end
end
