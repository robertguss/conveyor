defmodule Conveyor.Domain.ActiveResource do
  @moduledoc """
  Shared Ash/Postgres contract for Phase 0/1 active control-plane resources.

  The first domain slice keeps resources intentionally uniform. Later beads can
  specialize lifecycle actions and relationships without changing the immutable
  identity contract established here.
  """

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)

    quote bind_quoted: [table: table] do
      use Ash.Resource,
        otp_app: :conveyor,
        domain: Conveyor.Domain,
        data_layer: AshPostgres.DataLayer

      postgres do
        table(table)
        repo(Conveyor.Repo)
      end

      actions do
        defaults([:read, :destroy])

        create :create do
          primary?(true)
          accept([:external_id, :name, :status, :payload])
        end

        update :update do
          primary?(true)
          accept([:name, :status, :payload])
        end
      end

      attributes do
        uuid_primary_key(:id)

        attribute :external_id, :string do
          allow_nil?(false)
          public?(true)
          constraints(min_length: 1)
        end

        attribute :name, :string do
          allow_nil?(false)
          public?(true)
          constraints(min_length: 1)
        end

        attribute :status, :string do
          allow_nil?(false)
          public?(true)
          default("active")
          constraints(match: ~r/^(active|paused|archived)$/)
        end

        attribute :payload, :map do
          allow_nil?(false)
          public?(true)
          default(%{})
        end

        create_timestamp :inserted_at do
          public?(true)
        end

        update_timestamp :updated_at do
          public?(true)
        end
      end

      identities do
        identity(:unique_external_id, [:external_id])
      end
    end
  end
end

defmodule Conveyor.Domain.Resources do
  @moduledoc """
  Inventory of active Phase 0/1 Ash resources and their backing tables.
  """

  @schema_version "conveyor.domain_resource_contract@1"
  @immutable_fields [:id, :external_id, :inserted_at]
  @resource_specs [
    {Conveyor.Domain.Project, :projects},
    {Conveyor.Domain.ToolchainProfile, :toolchain_profiles},
    {Conveyor.Domain.CacheMount, :cache_mounts},
    {Conveyor.Domain.Plan, :plans},
    {Conveyor.Domain.Requirement, :requirements},
    {Conveyor.Domain.HumanDecision, :human_decisions},
    {Conveyor.Domain.HumanApproval, :human_approvals},
    {Conveyor.Domain.ExternalChange, :external_changes},
    {Conveyor.Domain.PatchEquivalence, :patch_equivalences},
    {Conveyor.Domain.PlanAudit, :plan_audits},
    {Conveyor.Domain.Epic, :epics},
    {Conveyor.Domain.Slice, :slices},
    {Conveyor.Domain.DiffPolicy, :diff_policies},
    {Conveyor.Domain.ReviewPolicy, :review_policies},
    {Conveyor.Domain.AgentBrief, :agent_briefs},
    {Conveyor.Domain.ContractLock, :contract_locks},
    {Conveyor.Domain.TestPack, :test_packs},
    {Conveyor.Domain.VerificationSuite, :verification_suites},
    {Conveyor.Domain.TestPackCalibration, :test_pack_calibrations},
    {Conveyor.Domain.ContextPack, :context_packs},
    {Conveyor.Domain.InstructionSource, :instruction_sources},
    {Conveyor.Domain.CodeQualityRun, :code_quality_runs},
    {Conveyor.Domain.RunPrompt, :run_prompts},
    {Conveyor.Domain.RunSpec, :run_specs},
    {Conveyor.Domain.WorkspaceMaterialization, :workspace_materializations},
    {Conveyor.Domain.AgentProfile, :agent_profiles},
    {Conveyor.Domain.RunAttempt, :run_attempts},
    {Conveyor.Domain.AgentSession, :agent_sessions},
    {Conveyor.Domain.PatchSet, :patch_sets},
    {Conveyor.Domain.RiskAssessment, :risk_assessments},
    {Conveyor.Domain.StationRun, :station_runs},
    {Conveyor.Domain.Evidence, :evidence},
    {Conveyor.Domain.ToolInvocation, :tool_invocations},
    {Conveyor.Domain.Review, :reviews},
    {Conveyor.Domain.GateResult, :gate_results},
    {Conveyor.Domain.Artifact, :artifacts},
    {Conveyor.Domain.RunBundle, :run_bundles},
    {Conveyor.Domain.ReviewerHealth, :reviewer_health},
    {Conveyor.Domain.GateHealth, :gate_health},
    {Conveyor.Domain.LedgerEvent, :ledger_events},
    {Conveyor.Domain.Policy, :policies},
    {Conveyor.Domain.RetentionPolicy, :retention_policies},
    {Conveyor.Domain.RunBudget, :run_budgets},
    {Conveyor.Domain.Incident, :incidents},
    {Conveyor.Domain.StationEffect, :station_effects},
    {Conveyor.Domain.CredentialLease, :credential_leases}
  ]

  def resource_specs, do: @resource_specs
  def resource_modules, do: Enum.map(@resource_specs, &elem(&1, 0))
  def table_names, do: Enum.map(@resource_specs, &elem(&1, 1))
  def immutable_fields, do: @immutable_fields

  def migration_log do
    %{
      schema_version: @schema_version,
      category: "domain_resource_migration",
      resource_count: length(@resource_specs),
      table_count: length(table_names()),
      resources:
        Enum.map(@resource_specs, fn {resource, table_name} ->
          %{resource: inspect(resource), table: Atom.to_string(table_name)}
        end),
      immutable_fields: Enum.map(@immutable_fields, &Atom.to_string/1)
    }
  end

  def guard_violation_log(resource, field) do
    %{
      schema_version: @schema_version,
      category: "domain_resource_guard",
      failure_category: "immutable_field_update_rejected",
      resource: inspect(resource),
      field: Atom.to_string(field),
      immutable_fields: Enum.map(@immutable_fields, &Atom.to_string/1)
    }
  end
end

defmodule Conveyor.Domain.Project do
  use Conveyor.Domain.ActiveResource, table: "projects"
end

defmodule Conveyor.Domain.ToolchainProfile do
  use Conveyor.Domain.ActiveResource, table: "toolchain_profiles"
end

defmodule Conveyor.Domain.CacheMount do
  use Conveyor.Domain.ActiveResource, table: "cache_mounts"
end

defmodule Conveyor.Domain.Plan do
  use Conveyor.Domain.ActiveResource, table: "plans"
end

defmodule Conveyor.Domain.Requirement do
  use Conveyor.Domain.ActiveResource, table: "requirements"
end

defmodule Conveyor.Domain.HumanDecision do
  use Conveyor.Domain.ActiveResource, table: "human_decisions"
end

defmodule Conveyor.Domain.HumanApproval do
  use Conveyor.Domain.ActiveResource, table: "human_approvals"
end

defmodule Conveyor.Domain.ExternalChange do
  use Conveyor.Domain.ActiveResource, table: "external_changes"
end

defmodule Conveyor.Domain.PatchEquivalence do
  use Conveyor.Domain.ActiveResource, table: "patch_equivalences"
end

defmodule Conveyor.Domain.PlanAudit do
  use Conveyor.Domain.ActiveResource, table: "plan_audits"
end

defmodule Conveyor.Domain.Epic do
  use Conveyor.Domain.ActiveResource, table: "epics"
end

defmodule Conveyor.Domain.Slice do
  use Conveyor.Domain.ActiveResource, table: "slices"
end

defmodule Conveyor.Domain.DiffPolicy do
  use Conveyor.Domain.ActiveResource, table: "diff_policies"
end

defmodule Conveyor.Domain.ReviewPolicy do
  use Conveyor.Domain.ActiveResource, table: "review_policies"
end

defmodule Conveyor.Domain.AgentBrief do
  use Conveyor.Domain.ActiveResource, table: "agent_briefs"
end

defmodule Conveyor.Domain.ContractLock do
  use Conveyor.Domain.ActiveResource, table: "contract_locks"
end

defmodule Conveyor.Domain.TestPack do
  use Conveyor.Domain.ActiveResource, table: "test_packs"
end

defmodule Conveyor.Domain.VerificationSuite do
  use Conveyor.Domain.ActiveResource, table: "verification_suites"
end

defmodule Conveyor.Domain.TestPackCalibration do
  use Conveyor.Domain.ActiveResource, table: "test_pack_calibrations"
end

defmodule Conveyor.Domain.ContextPack do
  use Conveyor.Domain.ActiveResource, table: "context_packs"
end

defmodule Conveyor.Domain.InstructionSource do
  use Conveyor.Domain.ActiveResource, table: "instruction_sources"
end

defmodule Conveyor.Domain.CodeQualityRun do
  use Conveyor.Domain.ActiveResource, table: "code_quality_runs"
end

defmodule Conveyor.Domain.RunPrompt do
  use Conveyor.Domain.ActiveResource, table: "run_prompts"
end

defmodule Conveyor.Domain.RunSpec do
  use Conveyor.Domain.ActiveResource, table: "run_specs"
end

defmodule Conveyor.Domain.WorkspaceMaterialization do
  use Conveyor.Domain.ActiveResource, table: "workspace_materializations"
end

defmodule Conveyor.Domain.AgentProfile do
  use Conveyor.Domain.ActiveResource, table: "agent_profiles"
end

defmodule Conveyor.Domain.RunAttempt do
  use Conveyor.Domain.ActiveResource, table: "run_attempts"
end

defmodule Conveyor.Domain.AgentSession do
  use Conveyor.Domain.ActiveResource, table: "agent_sessions"
end

defmodule Conveyor.Domain.PatchSet do
  use Conveyor.Domain.ActiveResource, table: "patch_sets"
end

defmodule Conveyor.Domain.RiskAssessment do
  use Conveyor.Domain.ActiveResource, table: "risk_assessments"
end

defmodule Conveyor.Domain.StationRun do
  use Conveyor.Domain.ActiveResource, table: "station_runs"
end

defmodule Conveyor.Domain.Evidence do
  use Conveyor.Domain.ActiveResource, table: "evidence"
end

defmodule Conveyor.Domain.ToolInvocation do
  use Conveyor.Domain.ActiveResource, table: "tool_invocations"
end

defmodule Conveyor.Domain.Review do
  use Conveyor.Domain.ActiveResource, table: "reviews"
end

defmodule Conveyor.Domain.GateResult do
  use Conveyor.Domain.ActiveResource, table: "gate_results"
end

defmodule Conveyor.Domain.Artifact do
  use Conveyor.Domain.ActiveResource, table: "artifacts"
end

defmodule Conveyor.Domain.RunBundle do
  use Conveyor.Domain.ActiveResource, table: "run_bundles"
end

defmodule Conveyor.Domain.ReviewerHealth do
  use Conveyor.Domain.ActiveResource, table: "reviewer_health"
end

defmodule Conveyor.Domain.GateHealth do
  use Conveyor.Domain.ActiveResource, table: "gate_health"
end

defmodule Conveyor.Domain.LedgerEvent do
  use Conveyor.Domain.ActiveResource, table: "ledger_events"
end

defmodule Conveyor.Domain.Policy do
  use Conveyor.Domain.ActiveResource, table: "policies"
end

defmodule Conveyor.Domain.RetentionPolicy do
  use Conveyor.Domain.ActiveResource, table: "retention_policies"
end

defmodule Conveyor.Domain.RunBudget do
  use Conveyor.Domain.ActiveResource, table: "run_budgets"
end

defmodule Conveyor.Domain.Incident do
  use Conveyor.Domain.ActiveResource, table: "incidents"
end

defmodule Conveyor.Domain.StationEffect do
  use Conveyor.Domain.ActiveResource, table: "station_effects"
end

defmodule Conveyor.Domain.CredentialLease do
  use Conveyor.Domain.ActiveResource, table: "credential_leases"
end
