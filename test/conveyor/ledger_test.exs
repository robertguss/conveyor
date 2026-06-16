defmodule Conveyor.LedgerTest do
  use ExUnit.Case, async: false

  alias Conveyor.Ledger
  alias Conveyor.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "append_event writes an immutable ledger event and committed outbox entry" do
    assert {:ok, event, outbox_entries} =
             Ledger.append_event(event_attrs("ledger-create-list"),
               channels: ["live_view", "telemetry"]
             )

    assert event.id
    assert event.idempotency_key == "ledger-create-list"
    assert event.trace_id == "trace-ledger-create-list"
    assert event.span_id == "span-ledger-create-list"
    assert event.stream_id == "run-ledger-create-list"

    assert [%{channel: "live_view"}, %{channel: "telemetry"}] = outbox_entries

    assert %{
             schema_version: "conveyor.ledger_outbox@1",
             category: "ledger_outbox_summary",
             event_id: event_id,
             idempotency_key: "ledger-create-list",
             stream_id: "run-ledger-create-list",
             event_type: "station.started",
             outbox_count: 2,
             outbox_channels: ["live_view", "telemetry"]
           } = Ledger.structured_summary(event, outbox_entries)

    assert event_id == event.id

    assert [%{payload: %{"idempotency_key" => "ledger-create-list"}} | _] =
             Ledger.committed_outbox("run-ledger-create-list")
  end

  test "duplicate idempotency keys are rejected with a structured finding" do
    assert {:ok, _event, _outbox_entries} = Ledger.append_event(event_attrs("ledger-duplicate"))

    assert {:error,
            %{
              schema_version: "conveyor.ledger_outbox@1",
              category: "ledger_duplicate_key",
              failure_category: "duplicate_idempotency_key",
              idempotency_key: "ledger-duplicate"
            }} = Ledger.append_event(event_attrs("ledger-duplicate"))
  end

  test "rolled-back transactions leave no committed outbox rows visible to observers" do
    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert {:ok, _event, _outbox_entries} =
                        Ledger.append_event(event_attrs("ledger-rollback"))

               assert [_inside_transaction] = Ledger.committed_outbox("run-ledger-rollback")

               Repo.rollback(:forced_rollback)
             end)

    assert [] = Ledger.committed_outbox("run-ledger-rollback")
  end

  test "R0 timeline replay rebuilds human-readable run timeline from ledger events" do
    assert {:ok, _event, _outbox_entries} =
             Ledger.append_event(event_attrs("ledger-replay-a", event_type: "station.started"))

    assert {:ok, _event, _outbox_entries} =
             Ledger.append_event(event_attrs("ledger-replay-b", event_type: "station.finished"))

    assert [
             %{event_type: "station.started", summary: "station.started for ledger-replay-a"},
             %{event_type: "station.finished", summary: "station.finished for ledger-replay-b"}
           ] = Ledger.replay_timeline("run-ledger-replay")
  end

  defp event_attrs(idempotency_key, opts \\ []) do
    event_type = Keyword.get(opts, :event_type, "station.started")
    stream_id = Keyword.get(opts, :stream_id, stream_id_for(idempotency_key))

    %{
      idempotency_key: idempotency_key,
      trace_id: "trace-#{idempotency_key}",
      span_id: "span-#{idempotency_key}",
      stream_id: stream_id,
      event_type: event_type,
      summary: "#{event_type} for #{idempotency_key}",
      payload: %{"idempotency_key" => idempotency_key},
      metadata: %{"test" => true}
    }
  end

  defp stream_id_for("ledger-replay-" <> _suffix), do: "run-ledger-replay"
  defp stream_id_for(idempotency_key), do: "run-#{idempotency_key}"
end
