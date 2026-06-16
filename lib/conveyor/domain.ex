defmodule Conveyor.Domain do
  @moduledoc """
  Root Ash domain for the control-plane resources.

  Phase 0 keeps the domain empty. Resource modules and migrations are introduced
  by the domain-state beads that depend on the application scaffold.
  """

  use Ash.Domain, otp_app: :conveyor

  resources do
    resource(Conveyor.Domain.Project)
    resource(Conveyor.Domain.ToolchainProfile)
    resource(Conveyor.Domain.CacheMount)
    resource(Conveyor.Domain.Plan)
    resource(Conveyor.Domain.Requirement)
    resource(Conveyor.Domain.HumanDecision)
    resource(Conveyor.Domain.HumanApproval)
    resource(Conveyor.Domain.ExternalChange)
    resource(Conveyor.Domain.PatchEquivalence)
    resource(Conveyor.Domain.PlanAudit)
    resource(Conveyor.Domain.Epic)
    resource(Conveyor.Domain.Slice)
    resource(Conveyor.Domain.DiffPolicy)
    resource(Conveyor.Domain.ReviewPolicy)
    resource(Conveyor.Domain.AgentBrief)
    resource(Conveyor.Domain.ContractLock)
    resource(Conveyor.Domain.TestPack)
    resource(Conveyor.Domain.VerificationSuite)
    resource(Conveyor.Domain.TestPackCalibration)
    resource(Conveyor.Domain.ContextPack)
    resource(Conveyor.Domain.InstructionSource)
    resource(Conveyor.Domain.CodeQualityRun)
    resource(Conveyor.Domain.RunPrompt)
    resource(Conveyor.Domain.RunSpec)
    resource(Conveyor.Domain.WorkspaceMaterialization)
    resource(Conveyor.Domain.AgentProfile)
    resource(Conveyor.Domain.RunAttempt)
    resource(Conveyor.Domain.AgentSession)
    resource(Conveyor.Domain.PatchSet)
    resource(Conveyor.Domain.RiskAssessment)
    resource(Conveyor.Domain.StationRun)
    resource(Conveyor.Domain.Evidence)
    resource(Conveyor.Domain.ToolInvocation)
    resource(Conveyor.Domain.Review)
    resource(Conveyor.Domain.GateResult)
    resource(Conveyor.Domain.Artifact)
    resource(Conveyor.Domain.RunBundle)
    resource(Conveyor.Domain.ReviewerHealth)
    resource(Conveyor.Domain.GateHealth)
    resource(Conveyor.Domain.LedgerEvent)
    resource(Conveyor.Domain.Policy)
    resource(Conveyor.Domain.RetentionPolicy)
    resource(Conveyor.Domain.RunBudget)
    resource(Conveyor.Domain.Incident)
    resource(Conveyor.Domain.StationEffect)
    resource(Conveyor.Domain.CredentialLease)
  end
end
