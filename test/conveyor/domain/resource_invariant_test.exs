defmodule Conveyor.Domain.ResourceInvariantTest do
  use ExUnit.Case, async: false

  alias Conveyor.Domain.ResourceInvariants
  alias Conveyor.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  test "declares the database-backed resource invariant contract" do
    constraints = ResourceInvariants.unique_identity_constraints()

    assert ResourceInvariants.schema_version() == "conveyor.domain_resource_invariants@1"
    assert length(constraints) == 13
    assert "run_specs_sha256_unique" in ResourceInvariants.constraint_names()

    assert ResourceInvariants.immutable_payload_keys().run_specs == [
             "run_spec_sha256",
             "base_commit",
             "contract_digests"
           ]

    assert ResourceInvariants.immutable_payload_keys().artifacts == ["sha256", "blob_uri"]
  end

  test "duplicate fixture inserts fail at the database boundary" do
    scope = unique_scope("duplicate")

    for fixture <- duplicate_fixtures(scope) do
      insert_resource!(
        fixture.table,
        "#{scope}-#{fixture.invariant}-a",
        fixture.payload_a,
        fixture.status_a
      )

      error =
        assert_raise Postgrex.Error, fn ->
          insert_resource!(
            fixture.table,
            "#{scope}-#{fixture.invariant}-b",
            fixture.payload_b,
            fixture.status_b
          )
        end

      assert error.postgres.code == :unique_violation
      assert error.postgres.constraint == Atom.to_string(fixture.constraint)

      assert %{
               schema_version: "conveyor.domain_resource_invariants@1",
               category: "domain_resource_constraint_violation",
               failure_category: "database_constraint_rejected_write",
               invariant: invariant,
               postgres_code: "unique_violation",
               constraint: constraint
             } = ResourceInvariants.constraint_violation_finding(error, fixture.invariant)

      assert invariant == fixture.invariant
      assert constraint == Atom.to_string(fixture.constraint)
    end
  end

  test "immutable digest, base, lock, and blob payload fields cannot be updated in place" do
    scope = unique_scope("immutable")

    for fixture <- immutable_update_fixtures(scope) do
      insert_resource!(fixture.table, "#{scope}-#{fixture.invariant}", fixture.payload, "active")

      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!(fixture.sql, [fixture.external_id, fixture.changed_value])
        end

      assert error.postgres.code == :check_violation
      assert error.postgres.constraint == fixture.constraint

      assert %{
               failure_category: "database_constraint_rejected_write",
               invariant: invariant,
               postgres_code: "check_violation",
               constraint: constraint
             } = ResourceInvariants.constraint_violation_finding(error, fixture.invariant)

      assert invariant == fixture.invariant
      assert constraint == fixture.constraint
    end
  end

  defp duplicate_fixtures(scope) do
    [
      %{
        invariant: "requirement_stable_key",
        table: :requirements,
        constraint: :requirements_project_stable_key_unique,
        payload_a: %{"project_id" => scope, "stable_key" => "REQ-001"},
        payload_b: %{"project_id" => scope, "stable_key" => "REQ-001"},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "human_decision_stable_key",
        table: :human_decisions,
        constraint: :human_decisions_project_stable_key_unique,
        payload_a: %{"project_id" => scope, "stable_key" => "DEC-001"},
        payload_b: %{"project_id" => scope, "stable_key" => "DEC-001"},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "slice_plan_position",
        table: :slices,
        constraint: :slices_plan_position_unique,
        payload_a: %{"plan_id" => "#{scope}-plan", "position" => 1},
        payload_b: %{"plan_id" => "#{scope}-plan", "position" => 1},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "agent_brief_version",
        table: :agent_briefs,
        constraint: :agent_briefs_key_version_unique,
        payload_a: %{"brief_key" => "#{scope}-brief", "version" => 1},
        payload_b: %{"brief_key" => "#{scope}-brief", "version" => 1},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "test_pack_version",
        table: :test_packs,
        constraint: :test_packs_key_version_unique,
        payload_a: %{"test_pack_key" => "#{scope}-pack", "version" => 1},
        payload_b: %{"test_pack_key" => "#{scope}-pack", "version" => 1},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "run_spec_digest",
        table: :run_specs,
        constraint: :run_specs_sha256_unique,
        payload_a: %{"run_spec_sha256" => "sha256:#{scope}"},
        payload_b: %{"run_spec_sha256" => "sha256:#{scope}"},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "run_attempt_number",
        table: :run_attempts,
        constraint: :run_attempts_slice_attempt_number_unique,
        payload_a: %{"slice_id" => "#{scope}-slice-attempt", "attempt_number" => 1},
        payload_b: %{"slice_id" => "#{scope}-slice-attempt", "attempt_number" => 1},
        status_a: "paused",
        status_b: "paused"
      },
      %{
        invariant: "run_attempt_one_active_per_slice",
        table: :run_attempts,
        constraint: :run_attempts_one_active_per_slice_unique,
        payload_a: %{"slice_id" => "#{scope}-slice-active", "attempt_number" => 1},
        payload_b: %{"slice_id" => "#{scope}-slice-active", "attempt_number" => 2},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "station_run_idempotency",
        table: :station_runs,
        constraint: :station_runs_idempotency_key_unique,
        payload_a: %{"idempotency_key" => "#{scope}-station-run"},
        payload_b: %{"idempotency_key" => "#{scope}-station-run"},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "station_effect_idempotency",
        table: :station_effects,
        constraint: :station_effects_idempotency_key_unique,
        payload_a: %{"idempotency_key" => "#{scope}-station-effect"},
        payload_b: %{"idempotency_key" => "#{scope}-station-effect"},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "ledger_event_idempotency",
        table: :ledger_events,
        constraint: :ledger_events_idempotency_key_unique,
        payload_a: %{"idempotency_key" => "#{scope}-ledger-event"},
        payload_b: %{"idempotency_key" => "#{scope}-ledger-event"},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "artifact_digest_identity",
        table: :artifacts,
        constraint: :artifacts_sha256_unique,
        payload_a: %{"sha256" => "sha256:#{scope}-artifact"},
        payload_b: %{"sha256" => "sha256:#{scope}-artifact"},
        status_a: "active",
        status_b: "active"
      },
      %{
        invariant: "gate_health_freshness_key",
        table: :gate_health,
        constraint: :gate_health_freshness_key_unique,
        payload_a: %{"freshness_key" => "#{scope}-gate"},
        payload_b: %{"freshness_key" => "#{scope}-gate"},
        status_a: "active",
        status_b: "active"
      }
    ]
  end

  defp immutable_update_fixtures(scope) do
    [
      %{
        invariant: "immutable_digest_field",
        table: :run_specs,
        constraint: "run_specs_immutable_payload_keys",
        external_id: "#{scope}-immutable_digest_field",
        payload: %{
          "run_spec_sha256" => "sha256:#{scope}-run-spec",
          "base_commit" => "#{scope}-base",
          "contract_digests" => %{"plan" => "sha256:#{scope}-plan"}
        },
        changed_value: "sha256:#{scope}-changed",
        sql:
          "UPDATE run_specs SET payload = jsonb_set(payload, '{run_spec_sha256}', to_jsonb($2::text), true) WHERE external_id = $1"
      },
      %{
        invariant: "immutable_base_field",
        table: :run_specs,
        constraint: "run_specs_immutable_payload_keys",
        external_id: "#{scope}-immutable_base_field",
        payload: %{
          "run_spec_sha256" => "sha256:#{scope}-run-spec-base",
          "base_commit" => "#{scope}-base",
          "contract_digests" => %{"plan" => "sha256:#{scope}-plan-base"}
        },
        changed_value: "#{scope}-changed-base",
        sql:
          "UPDATE run_specs SET payload = jsonb_set(payload, '{base_commit}', to_jsonb($2::text), true) WHERE external_id = $1"
      },
      %{
        invariant: "immutable_lock_field",
        table: :contract_locks,
        constraint: "contract_locks_immutable_payload_keys",
        external_id: "#{scope}-immutable_lock_field",
        payload: %{"lock_digest" => "sha256:#{scope}-lock", "base_commit" => "#{scope}-base"},
        changed_value: "sha256:#{scope}-lock-changed",
        sql:
          "UPDATE contract_locks SET payload = jsonb_set(payload, '{lock_digest}', to_jsonb($2::text), true) WHERE external_id = $1"
      },
      %{
        invariant: "immutable_blob_field",
        table: :artifacts,
        constraint: "artifacts_immutable_payload_keys",
        external_id: "#{scope}-immutable_blob_field",
        payload: %{"sha256" => "sha256:#{scope}-blob", "blob_uri" => "file://#{scope}/blob"},
        changed_value: "file://#{scope}/changed",
        sql:
          "UPDATE artifacts SET payload = jsonb_set(payload, '{blob_uri}', to_jsonb($2::text), true) WHERE external_id = $1"
      }
    ]
  end

  defp insert_resource!(table, external_id, payload, status) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    row =
      table
      |> base_row(external_id, payload, status, now)
      |> Map.merge(extra_columns(table, external_id, now))

    {1, nil} = Repo.insert_all(Atom.to_string(table), [row])
  end

  defp base_row(_table, external_id, payload, status, now) do
    %{
      id: Ecto.UUID.bingenerate(),
      external_id: external_id,
      name: external_id,
      status: status,
      payload: payload,
      inserted_at: now,
      updated_at: now
    }
  end

  defp extra_columns(:ledger_events, external_id, now) do
    %{
      idempotency_key: "#{external_id}-column",
      trace_id: "trace-#{external_id}",
      span_id: "span-#{external_id}",
      stream_id: "stream-#{external_id}",
      event_type: "test.domain_invariant",
      occurred_at: now,
      summary: external_id,
      metadata: %{}
    }
  end

  defp extra_columns(_table, _external_id, _now), do: %{}

  defp unique_scope(label) do
    "#{label}-#{System.unique_integer([:positive])}"
  end
end
