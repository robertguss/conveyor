defmodule Conveyor.Repo.Migrations.AddLedgerEventOutbox do
  use Ecto.Migration

  def up do
    alter table(:ledger_events) do
      add :idempotency_key, :text
      add :trace_id, :text
      add :span_id, :text
      add :stream_id, :text
      add :event_type, :text
      add :occurred_at, :utc_datetime_usec
      add :summary, :text
      add :metadata, :map, null: false, default: fragment("'{}'::jsonb")
    end

    execute """
    UPDATE ledger_events
    SET
      idempotency_key = external_id,
      trace_id = 'legacy-trace',
      span_id = 'legacy-span',
      stream_id = 'legacy-stream',
      event_type = name,
      occurred_at = inserted_at,
      summary = name
    WHERE idempotency_key IS NULL
    """

    alter table(:ledger_events) do
      modify :idempotency_key, :text, null: false
      modify :trace_id, :text, null: false
      modify :span_id, :text, null: false
      modify :stream_id, :text, null: false
      modify :event_type, :text, null: false
      modify :occurred_at, :utc_datetime_usec, null: false
      modify :summary, :text, null: false
    end

    create unique_index(:ledger_events, [:idempotency_key])
    create index(:ledger_events, [:stream_id, :occurred_at])
    create index(:ledger_events, [:trace_id, :span_id])

    create table(:ledger_event_outbox, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false

      add :ledger_event_id,
          references(:ledger_events, type: :uuid, on_delete: :restrict),
          null: false

      add :channel, :text, null: false
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")
      add :committed_at, :utc_datetime_usec, null: false
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ledger_event_outbox, [:ledger_event_id])
    create index(:ledger_event_outbox, [:channel, :committed_at])
  end

  def down do
    drop_if_exists table(:ledger_event_outbox)

    drop_if_exists index(:ledger_events, [:trace_id, :span_id])
    drop_if_exists index(:ledger_events, [:stream_id, :occurred_at])
    drop_if_exists index(:ledger_events, [:idempotency_key])

    alter table(:ledger_events) do
      remove :metadata
      remove :summary
      remove :occurred_at
      remove :event_type
      remove :stream_id
      remove :span_id
      remove :trace_id
      remove :idempotency_key
    end
  end
end
