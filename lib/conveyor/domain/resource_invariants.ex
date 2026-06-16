defmodule Conveyor.Domain.ResourceInvariants do
  @moduledoc """
  Database-backed identity, idempotency, and immutability invariants.

  The Phase 0 resources intentionally share a small physical table shape. These
  invariants name the JSON payload keys that must still be enforced by Postgres
  so retries, crashes, and concurrent writers cannot bypass Ash-level checks.
  """

  @schema_version "conveyor.domain_resource_invariants@1"

  @unique_identity_constraints [
    %{
      invariant: "requirement_stable_key",
      table: :requirements,
      constraint: :requirements_project_stable_key_unique,
      payload_keys: ["project_id", "stable_key"]
    },
    %{
      invariant: "human_decision_stable_key",
      table: :human_decisions,
      constraint: :human_decisions_project_stable_key_unique,
      payload_keys: ["project_id", "stable_key"]
    },
    %{
      invariant: "slice_plan_position",
      table: :slices,
      constraint: :slices_plan_position_unique,
      payload_keys: ["plan_id", "position"]
    },
    %{
      invariant: "agent_brief_version",
      table: :agent_briefs,
      constraint: :agent_briefs_key_version_unique,
      payload_keys: ["brief_key", "version"]
    },
    %{
      invariant: "test_pack_version",
      table: :test_packs,
      constraint: :test_packs_key_version_unique,
      payload_keys: ["test_pack_key", "version"]
    },
    %{
      invariant: "run_spec_digest",
      table: :run_specs,
      constraint: :run_specs_sha256_unique,
      payload_keys: ["run_spec_sha256"]
    },
    %{
      invariant: "run_attempt_number",
      table: :run_attempts,
      constraint: :run_attempts_slice_attempt_number_unique,
      payload_keys: ["slice_id", "attempt_number"]
    },
    %{
      invariant: "run_attempt_one_active_per_slice",
      table: :run_attempts,
      constraint: :run_attempts_one_active_per_slice_unique,
      payload_keys: ["slice_id"]
    },
    %{
      invariant: "station_run_idempotency",
      table: :station_runs,
      constraint: :station_runs_idempotency_key_unique,
      payload_keys: ["idempotency_key"]
    },
    %{
      invariant: "station_effect_idempotency",
      table: :station_effects,
      constraint: :station_effects_idempotency_key_unique,
      payload_keys: ["idempotency_key"]
    },
    %{
      invariant: "ledger_event_idempotency",
      table: :ledger_events,
      constraint: :ledger_events_idempotency_key_unique,
      payload_keys: ["idempotency_key"]
    },
    %{
      invariant: "artifact_digest_identity",
      table: :artifacts,
      constraint: :artifacts_sha256_unique,
      payload_keys: ["sha256"]
    },
    %{
      invariant: "gate_health_freshness_key",
      table: :gate_health,
      constraint: :gate_health_freshness_key_unique,
      payload_keys: ["freshness_key"]
    }
  ]

  @immutable_payload_keys %{
    run_specs: ["run_spec_sha256", "base_commit", "contract_digests"],
    agent_briefs: ["brief_key", "version", "contract_lock_id"],
    test_packs: ["test_pack_key", "version"],
    artifacts: ["sha256", "blob_uri"],
    contract_locks: ["lock_digest", "base_commit"]
  }

  def schema_version, do: @schema_version
  def unique_identity_constraints, do: @unique_identity_constraints
  def immutable_payload_keys, do: @immutable_payload_keys

  def constraint_names do
    Enum.map(@unique_identity_constraints, &Atom.to_string(&1.constraint))
  end

  def constraint_violation_finding(%{postgres: postgres}, invariant) when is_map(postgres) do
    %{
      schema_version: @schema_version,
      category: "domain_resource_constraint_violation",
      failure_category: "database_constraint_rejected_write",
      invariant: to_string(invariant),
      postgres_code: postgres |> Map.get(:code) |> maybe_to_string(),
      constraint: postgres |> Map.get(:constraint) |> maybe_to_string(),
      message: postgres |> Map.get(:message) |> maybe_to_string()
    }
  end

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)
end
