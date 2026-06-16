defmodule Conveyor.Repo.Migrations.AddPhaseDomainResources do
  use Ecto.Migration

  @tables [
    :projects,
    :toolchain_profiles,
    :cache_mounts,
    :plans,
    :requirements,
    :human_decisions,
    :human_approvals,
    :external_changes,
    :patch_equivalences,
    :plan_audits,
    :epics,
    :slices,
    :diff_policies,
    :review_policies,
    :agent_briefs,
    :contract_locks,
    :test_packs,
    :verification_suites,
    :test_pack_calibrations,
    :context_packs,
    :instruction_sources,
    :code_quality_runs,
    :run_prompts,
    :run_specs,
    :workspace_materializations,
    :agent_profiles,
    :run_attempts,
    :agent_sessions,
    :patch_sets,
    :risk_assessments,
    :station_runs,
    :evidence,
    :tool_invocations,
    :reviews,
    :gate_results,
    :artifacts,
    :run_bundles,
    :reviewer_health,
    :gate_health,
    :ledger_events,
    :policies,
    :retention_policies,
    :run_budgets,
    :incidents,
    :station_effects,
    :credential_leases
  ]

  def up do
    Enum.each(@tables, &create_resource_table/1)
  end

  def down do
    @tables
    |> Enum.reverse()
    |> Enum.each(fn table_name ->
      drop_if_exists table(table_name)
    end)
  end

  defp create_resource_table(table_name) do
    create table(table_name, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :external_id, :text, null: false
      add :name, :text, null: false
      add :status, :text, null: false, default: "active"
      add :payload, :map, null: false, default: fragment("'{}'::jsonb")

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(table_name, [:external_id])

    create constraint(table_name, :status_must_be_known,
             check: "status IN ('active', 'paused', 'archived')"
           )
  end
end
