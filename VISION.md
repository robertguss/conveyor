# Conveyor Vision

## Shared Contract

Conveyor is a deterministic conductor plus stochastic agents.

Phase 1 target autonomy level is L1.

Phase 1 produces PR-quality evidence but does not auto-merge or deploy.

The factory-kernel primitives must not be cut.

Phase 1 L1 target: assisted implementation that produces PR-quality evidence
but does not auto-merge or deploy.

The factory-kernel primitives that must not be cut are listed in this document.

Conveyor verification matrix item: conveyor-quality-ci-evals-vmr.13.

## Purpose

Conveyor turns agentic coding work into auditable, repeatable factory runs. It
does not try to make an agent trustworthy by assertion. It wraps agents in a
deterministic control plane that plans work, locks contracts, executes bounded
stations, records evidence, checks policy, and produces a human-reviewable run
bundle.

The product exists so a maintainer can ask for a small, well-scoped code change
and receive:

- A traceable plan and Slice contract.
- A bounded agent attempt under an explicit autonomy level.
- Independent conductor verification, not just agent self-report.
- A dossier and PR body that explain what changed, what passed, what failed,
  and what remains risky.
- A deterministic gate result that can block unsafe or unproven output.

## Product Contract

Phase 0 builds the foundation: the product contract, project configuration,
control-plane scaffold, doctor checks, schema vocabulary, and policy baseline.

Phase 1 proves the tracer bullet: one sterile FastAPI task app, one locked human
plan, one Slice, one agent implementation attempt, one reviewer pass, one gate,
and one projected run bundle.

The Phase 1 output is PR-quality evidence. A human remains responsible for
reviewing, merging, deploying, and handling production consequences.

## Non-Goals

Phase 0/1 does not provide autonomous production deployment.

Phase 0/1 does not auto-merge pull requests.

Phase 0/1 does not replace human product judgment, security review, or incident
ownership.

Phase 0/1 does not depend on live provider credentials for default CI, default
demo, or the hermetic tracer path.

Phase 0/1 does not support arbitrary unbounded agent command execution.

Phase 0/1 does not promise broad language/framework coverage. The tracer uses a
sterile FastAPI sample app and the control plane is planned as a Phoenix, Ash,
Oban, and Postgres application.

## Phase 0 and Phase 1 Cutline

Phase 0 establishes the contracts and minimum enforcement required for the
factory. Phase 1 proves those contracts through one L1 tracer run. Both phases
preserve the no-auto-merge and no-deploy boundary, and both keep the
factory-kernel primitives in scope.

## Phase 0 Cutline

Phase 0 must establish the words, contracts, and minimum enforcement points that
future implementation depends on. It includes:

- Vision, autonomy, safety, task, evidence, and architecture contracts.
- A project configuration model and generated AGENTS.md policy.
- A Phoenix/Ash/Oban/Postgres control-plane scaffold.
- Runtime prerequisite doctor checks.
- Baseline CI and verification matrix mapping.

Phase 0 may document deferred resources, but it must not create unused tables or
fake compatibility shims for future phases.

## Phase 1 Cutline

Phase 1 is a tracer bullet, not a platform launch. It must demonstrate one
end-to-end run with deterministic defaults:

- Human-authored plan and AgentBrief.
- Locked TestPack and acceptance calibration.
- Clean base workspace and clean gate workspace.
- Deterministic fake runner by default, with live adapters behind explicit
  configuration.
- Evidence, review, gate, canary freshness, and report projection.

The tracer can produce a patch and PR-ready dossier, but it stops before merge
or deploy.

## Evidence Requirements

Every successful run must produce machine evidence and human evidence. Machine
evidence must include stable identifiers, digests, command records, acceptance
coverage, policy decisions, review and gate results, and known risks. Human
evidence must include a dossier and PR body that are useful without opening a
LiveView.

Agent claims are inputs, not evidence. Evidence is created by the conductor from
locked contracts, clean workspaces, policy-mediated commands, and deterministic
checks.

## Trust Boundaries

The repository under change, agent output, tool output, generated patches, and
reviewer output are untrusted inputs. The conductor, locked contracts, policy
engine, artifact digests, gate composition, and human decisions form the trusted
control boundary.

No component may treat mutable workspace state as proof. Proof is recorded as
content-addressed artifacts and structured findings.

## Explicit Deferrals

The following are intentionally outside Phase 0/1:

- Autonomous merge, release, deployment, rollback, or production operations.
- Long-running multi-repo swarm scheduling.
- Hosted SaaS tenancy, billing, or organization administration.
- Broad adapter parity across every coding agent.
- Full object-storage backend beyond the local artifact projection seam.
- Advanced LiveView operator controls beyond the minimal planned surface.

## Factory-Kernel Primitives

The factory-kernel primitives that must not be cut are:

- PlanAudit with structured findings and readiness status.
- Requirement, acceptance, test, and Slice traceability.
- HumanDecision and HumanApproval records for scope and contract changes.
- AgentBrief as the locked implementation contract.
- ContractLock over plan, brief, tests, policy, AGENTS.md, and protected paths.
- Immutable RunSpec and versioned StationPlan.
- StationRun and StationEffect idempotency.
- Append-only LedgerEvent writer and transactional outbox.
- ToolExecutor and Policy.Engine for command execution.
- AgentRunner event envelope and capability-derived autonomy ceiling.
- PatchSet capture from a fresh base.
- Content-addressed artifacts and RunBundle root digest.
- EvidenceRecorder, RunCheck, Review, Gate, canary health, and replay hooks.

## Done Criteria

The Phase 0/1 contract is done when the root contract docs exist, the docs
validator passes, the no-auto-merge and L1-target statements are enforced, and
the verification matrix can cite this contract as coverage for
conveyor-phase0-foundations-hsh.1.

## Verification Mapping

This document is enforced by the Phase 0/1 docs contract check and mapped to
conveyor-quality-ci-evals-vmr.13. Missing sections or invariant phrases must be
reported as structured findings.
