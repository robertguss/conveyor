defmodule Conveyor.Ledger do
  @moduledoc """
  Append-only ledger writer and committed outbox projection.

  The ledger is audit/timeline truth, not full event sourcing. State remains in
  Ash/Postgres resources; ledger rows capture durable transitions and outbox rows
  give observers a committed-only stream.
  """

  alias Conveyor.Repo

  @compile {:no_warn_undefined, {Conveyor.Repo, :query!, 3}}
  @compile {:no_warn_undefined, {Conveyor.Repo, :rollback, 1}}
  @compile {:no_warn_undefined, {Conveyor.Repo, :transaction, 1}}

  @schema_version "conveyor.ledger_outbox@1"
  @default_channel "timeline"
  @required_fields [:idempotency_key, :trace_id, :span_id, :stream_id, :event_type, :summary]

  def append_event(attrs, opts \\ []) when is_map(attrs) do
    channels = opts |> Keyword.get(:channels, [@default_channel]) |> normalize_channels()

    with {:ok, event} <- normalize_event(attrs) do
      Repo.transaction(fn ->
        case insert_event(event) do
          :ok ->
            outbox_entries = insert_outbox_entries(event, channels)
            {event, outbox_entries}

          {:duplicate, idempotency_key} ->
            Repo.rollback(duplicate_key_finding(idempotency_key))
        end
      end)
      |> case do
        {:ok, {event, outbox_entries}} -> {:ok, event, outbox_entries}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def committed_outbox(stream_id) when is_binary(stream_id) do
    result =
      Repo.query!(
        """
        SELECT
          o.id::text,
          o.ledger_event_id::text,
          o.channel,
          o.payload,
          o.committed_at
        FROM ledger_event_outbox o
        JOIN ledger_events e ON e.id = o.ledger_event_id
        WHERE e.stream_id = $1 AND o.committed_at IS NOT NULL
        ORDER BY o.committed_at, o.id
        """,
        [stream_id],
        log: false
      )

    Enum.map(result.rows, fn [id, ledger_event_id, channel, payload, committed_at] ->
      %{
        id: id,
        ledger_event_id: ledger_event_id,
        channel: channel,
        payload: decode_payload(payload),
        committed_at: committed_at
      }
    end)
  end

  def replay_timeline(stream_id) when is_binary(stream_id) do
    result =
      Repo.query!(
        """
        SELECT
          id::text,
          trace_id,
          span_id,
          event_type,
          summary,
          payload,
          occurred_at
        FROM ledger_events
        WHERE stream_id = $1
        ORDER BY occurred_at, inserted_at, id
        """,
        [stream_id],
        log: false
      )

    Enum.map(result.rows, fn [id, trace_id, span_id, event_type, summary, payload, occurred_at] ->
      %{
        id: id,
        trace_id: trace_id,
        span_id: span_id,
        event_type: event_type,
        summary: summary,
        payload: decode_payload(payload),
        occurred_at: occurred_at
      }
    end)
  end

  def structured_summary(event, outbox_entries) do
    %{
      schema_version: @schema_version,
      category: "ledger_outbox_summary",
      event_id: event.id,
      idempotency_key: event.idempotency_key,
      stream_id: event.stream_id,
      event_type: event.event_type,
      outbox_count: length(outbox_entries),
      outbox_channels: Enum.map(outbox_entries, & &1.channel)
    }
  end

  def duplicate_key_finding(idempotency_key) do
    %{
      schema_version: @schema_version,
      category: "ledger_duplicate_key",
      failure_category: "duplicate_idempotency_key",
      idempotency_key: idempotency_key
    }
  end

  defp normalize_event(attrs) do
    missing_fields =
      @required_fields
      |> Enum.reject(fn field ->
        present?(Map.get(attrs, field) || Map.get(attrs, Atom.to_string(field)))
      end)

    case missing_fields do
      [] ->
        now = timestamp()
        idempotency_key = fetch_string!(attrs, :idempotency_key)
        event_type = fetch_string!(attrs, :event_type)

        {:ok,
         %{
           id: Map.get(attrs, :id) || Map.get(attrs, "id") || Ecto.UUID.generate(),
           external_id:
             Map.get(attrs, :external_id) || Map.get(attrs, "external_id") || idempotency_key,
           name: Map.get(attrs, :name) || Map.get(attrs, "name") || event_type,
           status: Map.get(attrs, :status) || Map.get(attrs, "status") || "active",
           payload: Map.get(attrs, :payload) || Map.get(attrs, "payload") || %{},
           idempotency_key: idempotency_key,
           trace_id: fetch_string!(attrs, :trace_id),
           span_id: fetch_string!(attrs, :span_id),
           stream_id: fetch_string!(attrs, :stream_id),
           event_type: event_type,
           occurred_at: Map.get(attrs, :occurred_at) || Map.get(attrs, "occurred_at") || now,
           summary: fetch_string!(attrs, :summary),
           metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{},
           inserted_at: now,
           updated_at: now
         }}

      fields ->
        {:error,
         %{
           schema_version: @schema_version,
           category: "ledger_validation",
           failure_category: "missing_required_fields",
           missing_fields: Enum.map(fields, &Atom.to_string/1)
         }}
    end
  end

  defp insert_event(event) do
    result =
      Repo.query!(
        """
        INSERT INTO ledger_events (
          id,
          external_id,
          name,
          status,
          payload,
          idempotency_key,
          trace_id,
          span_id,
          stream_id,
          event_type,
          occurred_at,
          summary,
          metadata,
          inserted_at,
          updated_at
        )
        VALUES (
          $1::uuid,
          $2,
          $3,
          $4,
          $5::jsonb,
          $6,
          $7,
          $8,
          $9,
          $10,
          $11,
          $12,
          $13::jsonb,
          $14,
          $15
        )
        ON CONFLICT (idempotency_key) DO NOTHING
        """,
        [
          dump_uuid!(event.id),
          event.external_id,
          event.name,
          event.status,
          Jason.encode!(event.payload),
          event.idempotency_key,
          event.trace_id,
          event.span_id,
          event.stream_id,
          event.event_type,
          event.occurred_at,
          event.summary,
          Jason.encode!(event.metadata),
          event.inserted_at,
          event.updated_at
        ],
        log: false
      )

    case result.num_rows do
      1 -> :ok
      0 -> {:duplicate, event.idempotency_key}
    end
  end

  defp insert_outbox_entries(event, channels) do
    Enum.map(channels, fn channel ->
      id = Ecto.UUID.generate()
      now = timestamp()

      payload = %{
        "schema_version" => @schema_version,
        "ledger_event_id" => event.id,
        "idempotency_key" => event.idempotency_key,
        "stream_id" => event.stream_id,
        "event_type" => event.event_type,
        "summary" => event.summary,
        "trace_id" => event.trace_id,
        "span_id" => event.span_id,
        "payload" => event.payload
      }

      Repo.query!(
        """
        INSERT INTO ledger_event_outbox (
          id,
          ledger_event_id,
          channel,
          payload,
          committed_at,
          inserted_at,
          updated_at
        )
        VALUES ($1::uuid, $2::uuid, $3, $4::jsonb, $5, $6, $7)
        """,
        [dump_uuid!(id), dump_uuid!(event.id), channel, Jason.encode!(payload), now, now, now],
        log: false
      )

      %{id: id, ledger_event_id: event.id, channel: channel, payload: payload, committed_at: now}
    end)
  end

  defp normalize_channels(channels) do
    channels
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> [@default_channel]
      values -> Enum.uniq(values)
    end
  end

  defp fetch_string!(attrs, field),
    do: Map.get(attrs, field) || Map.fetch!(attrs, Atom.to_string(field))

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp decode_payload(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode_payload(payload), do: payload

  defp dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> raise ArgumentError, "expected UUID string, got: #{inspect(uuid)}"
    end
  end

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end
end
