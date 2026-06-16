defmodule Conveyor.Repo.Migrations.AddDomainResourceInvariants do
  use Ecto.Migration

  def up do
    create_unique_invariant_indexes()
    create_immutable_payload_function()
    create_immutable_payload_triggers()
  end

  def down do
    drop_immutable_payload_triggers()
    execute("DROP FUNCTION IF EXISTS conveyor_reject_payload_key_updates()")
    drop_unique_invariant_indexes()
  end

  defp create_unique_invariant_indexes do
    create unique_index(:requirements, ["(payload->>'project_id')", "(payload->>'stable_key')"],
             name: :requirements_project_stable_key_unique,
             where: "payload ? 'project_id' AND payload ? 'stable_key'"
           )

    create unique_index(
             :human_decisions,
             ["(payload->>'project_id')", "(payload->>'stable_key')"],
             name: :human_decisions_project_stable_key_unique,
             where: "payload ? 'project_id' AND payload ? 'stable_key'"
           )

    create unique_index(:slices, ["(payload->>'plan_id')", "(payload->>'position')"],
             name: :slices_plan_position_unique,
             where: "payload ? 'plan_id' AND payload ? 'position'"
           )

    create unique_index(:agent_briefs, ["(payload->>'brief_key')", "(payload->>'version')"],
             name: :agent_briefs_key_version_unique,
             where: "payload ? 'brief_key' AND payload ? 'version'"
           )

    create unique_index(:test_packs, ["(payload->>'test_pack_key')", "(payload->>'version')"],
             name: :test_packs_key_version_unique,
             where: "payload ? 'test_pack_key' AND payload ? 'version'"
           )

    create unique_index(:run_specs, ["(payload->>'run_spec_sha256')"],
             name: :run_specs_sha256_unique,
             where: "payload ? 'run_spec_sha256'"
           )

    create unique_index(:run_attempts, ["(payload->>'slice_id')", "(payload->>'attempt_number')"],
             name: :run_attempts_slice_attempt_number_unique,
             where: "payload ? 'slice_id' AND payload ? 'attempt_number'"
           )

    create unique_index(:run_attempts, ["(payload->>'slice_id')"],
             name: :run_attempts_one_active_per_slice_unique,
             where: "status = 'active' AND payload ? 'slice_id'"
           )

    create unique_index(:station_runs, ["(payload->>'idempotency_key')"],
             name: :station_runs_idempotency_key_unique,
             where: "payload ? 'idempotency_key'"
           )

    create unique_index(:station_effects, ["(payload->>'idempotency_key')"],
             name: :station_effects_idempotency_key_unique,
             where: "payload ? 'idempotency_key'"
           )

    create unique_index(:ledger_events, ["(payload->>'idempotency_key')"],
             name: :ledger_events_idempotency_key_unique,
             where: "payload ? 'idempotency_key'"
           )

    create unique_index(:artifacts, ["(payload->>'sha256')"],
             name: :artifacts_sha256_unique,
             where: "payload ? 'sha256'"
           )

    create unique_index(:gate_health, ["(payload->>'freshness_key')"],
             name: :gate_health_freshness_key_unique,
             where: "payload ? 'freshness_key'"
           )
  end

  defp drop_unique_invariant_indexes do
    for index_name <- [
          :requirements_project_stable_key_unique,
          :human_decisions_project_stable_key_unique,
          :slices_plan_position_unique,
          :agent_briefs_key_version_unique,
          :test_packs_key_version_unique,
          :run_specs_sha256_unique,
          :run_attempts_slice_attempt_number_unique,
          :run_attempts_one_active_per_slice_unique,
          :station_runs_idempotency_key_unique,
          :station_effects_idempotency_key_unique,
          :ledger_events_idempotency_key_unique,
          :artifacts_sha256_unique,
          :gate_health_freshness_key_unique
        ] do
      execute("DROP INDEX IF EXISTS #{index_name}")
    end
  end

  defp create_immutable_payload_function do
    execute("""
    CREATE OR REPLACE FUNCTION conveyor_reject_payload_key_updates()
    RETURNS trigger AS $$
    DECLARE
      argument_index integer;
      immutable_key text;
    BEGIN
      IF NEW.payload IS DISTINCT FROM OLD.payload THEN
        FOR argument_index IN 0..TG_NARGS - 1 LOOP
          immutable_key := TG_ARGV[argument_index];

          IF (OLD.payload ? immutable_key)
             AND ((NOT NEW.payload ? immutable_key)
                  OR OLD.payload -> immutable_key IS DISTINCT FROM NEW.payload -> immutable_key) THEN
            RAISE EXCEPTION 'immutable payload key "%" cannot be updated on "%"', immutable_key, TG_TABLE_NAME
              USING ERRCODE = '23514', CONSTRAINT = TG_NAME;
          END IF;
        END LOOP;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """)
  end

  defp create_immutable_payload_triggers do
    create_immutable_payload_trigger(:run_specs, :run_specs_immutable_payload_keys, [
      "run_spec_sha256",
      "base_commit",
      "contract_digests"
    ])

    create_immutable_payload_trigger(:agent_briefs, :agent_briefs_immutable_payload_keys, [
      "brief_key",
      "version",
      "contract_lock_id"
    ])

    create_immutable_payload_trigger(:test_packs, :test_packs_immutable_payload_keys, [
      "test_pack_key",
      "version"
    ])

    create_immutable_payload_trigger(:artifacts, :artifacts_immutable_payload_keys, [
      "sha256",
      "blob_uri"
    ])

    create_immutable_payload_trigger(:contract_locks, :contract_locks_immutable_payload_keys, [
      "lock_digest",
      "base_commit"
    ])
  end

  defp drop_immutable_payload_triggers do
    for {table_name, trigger_name} <- [
          {:run_specs, :run_specs_immutable_payload_keys},
          {:agent_briefs, :agent_briefs_immutable_payload_keys},
          {:test_packs, :test_packs_immutable_payload_keys},
          {:artifacts, :artifacts_immutable_payload_keys},
          {:contract_locks, :contract_locks_immutable_payload_keys}
        ] do
      execute("DROP TRIGGER IF EXISTS #{trigger_name} ON #{table_name}")
    end
  end

  defp create_immutable_payload_trigger(table_name, trigger_name, keys) do
    quoted_keys = keys |> Enum.map(&"'#{&1}'") |> Enum.join(", ")

    execute("""
    CREATE TRIGGER #{trigger_name}
    BEFORE UPDATE OF payload ON #{table_name}
    FOR EACH ROW EXECUTE FUNCTION conveyor_reject_payload_key_updates(#{quoted_keys})
    """)
  end
end
