# Conveyor Architecture

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

This document maps the planned Phase 0/1 Conveyor architecture: a deterministic
control plane around stochastic agents, with policy, evidence, and gate
boundaries that keep Phase 1 at L1.

## Architecture Contract

Conveyor is planned as a Phoenix, Ash, Oban, and Postgres control-plane
application. Phoenix provides the operator surface, Ash models the domain and
state transitions, Oban runs durable stations, and Postgres stores contracts,
ledger events, station state, and artifact metadata.

The system is a deterministic conductor plus stochastic agents: Conveyor owns
state, policy, evidence, and gates; agents provide bounded implementation or
review attempts.

## System Shape

Primary components:

- Operator surface: Mix tasks, static reports, and minimal LiveView.
- Plan audit kernel: normalized plan import, scoring, findings, and readiness.
- Domain state: Project, Plan, Requirement, HumanDecision, Epic, Slice,
  AgentBrief, RunAttempt, StationRun, StationEffect, PatchSet, Review, Gate, and
  artifact resources.
- Durable execution: Oban station topology and RunSlice orchestration.
- Agent runtime: AgentRunner behavior, AgentProfile capability model, fake
  runner, sandbox runner, and live adapters behind explicit configuration.
- Policy layer: command grammar, Policy.Engine, ToolExecutor, sandbox profiles,
  budgets, and credential scoping.
- Evidence layer: content-addressed artifacts, EvidenceRecorder, RunCheck,
  dossier generation, provenance, RunBundle, and replay hooks.
- Gate layer: deterministic stage composition, reviewer aggregation, canary
  health, and fail-closed behavior.

## Control Plane Components

The control plane components are Phoenix operator surfaces, Ash resources and
state machines, Oban station workers, Postgres persistence, Policy.Engine,
ToolExecutor, AgentRunner adapters, artifact projection, RunCheck, Review, Gate,
and canary health.

## Phase 1 Linear StationPlan

The Phase 1 tracer uses one linear StationPlan:

1. Readiness.
2. Baseline health.
3. Acceptance calibration.
4. ContextScout.
5. PromptBuilder.
6. Agent implementation.
7. RecordEvidence.
8. RunReviewer.
9. RunGate.
10. Canary freshness.
11. ProjectArtifacts/report projection.
12. Optional post-integration checks when a human provides an integrated ref.
13. Retrospective.

Each station records idempotent inputs, outputs, policy profile, effects, and
structured findings.

## Station Flow

Station flow is deterministic. Every station reads locked inputs, applies policy
and idempotency rules, writes structured outputs, and records findings. Stochastic
agent behavior is isolated inside the implementation or review station and then
checked by conductor-owned stations.

## Data Model

Phase 0/1 active resources:

- Project and repository configuration.
- Plan, Requirement, HumanDecision, Epic, Slice, and AgentBrief.
- DiffPolicy, VerificationSuite, TestPack, ContractLock, RunSpec, and
  StationPlan.
- RunAttempt, StationRun, StationEffect, AgentSession, PatchSet, ToolInvocation,
  Review, GateResult, GateHealth, and RunBudget.
- ArtifactBlob, ArtifactManifest, RunBundle, Evidence, Dossier, and retention
  metadata.

Deferred resources may be documented, but unused tables should not be created
for future phases.

## State and Idempotency

RunSpec is immutable after execution starts. StationPlan is versioned. Station
effects use idempotency keys so retries cannot duplicate artifacts, ledger
events, or irreversible-looking effects.

State machines must guard Plan, Slice, and RunAttempt transitions. Illegal
transitions produce structured findings and ledger entries where applicable.

## Ledger and Outbox

LedgerEvent is append-only. It records material state transitions, station
results, policy decisions, gate outcomes, and human decisions.

The transactional outbox carries side effects from database commits to external
work such as station execution or report projection. Oban uniqueness is not the
only idempotency protection.

## Agent Runtime

AgentRunner adapters emit normalized events for session lifecycle, message
deltas, command requests, policy decisions, command results, file observations,
heartbeats, cancellation, errors, and completion.

The deterministic fake runner is the default for tests and demo. Live adapters
are optional and must be capped by capability and policy. Adapter raw output is
stored as untrusted input.

## Policy and Sandbox

ToolExecutor is the only component allowed to execute policy-mediated station
commands. Policy.Engine decides before execution and records the decision.

The sandbox runner materializes a repository at a known base, executes approved
commands under policy, and destroys or preserves workspaces according to cleanup
policy. The gate uses a clean workspace independent from the agent workspace.

## Evidence and Artifacts

Artifacts are stored by content digest before projection. Human-friendly files
under .conveyor/runs/<run_attempt_id> are projections, not source of truth.

RunCheck validates schema versions, required refs, digest consistency,
acceptance mapping, review dossier digest, gate fields, command refs,
sensitivity metadata, and run_spec_sha256 consistency.

## Data and Artifact Boundaries

Database state records contracts, refs, transitions, and metadata. Blob storage
records bytes by digest. Projected run directories are human-readable views and
must be regenerated from verified artifacts rather than treated as identity.

## Gate and Review

The gate is deterministic stage composition. It combines workspace integrity,
diff scope, observed risk, policy, secret safety, build/install, tests,
acceptance mapping, ContractLock, quality delta, RunCheck, provenance, reviewer
aggregation, and canary health.

The reviewer is a separate actor over the recorded dossier. Reviewer health is
measured before reviewer output may influence a gate.

## Trust Boundaries

Trusted boundary:

- Conductor code and database state.
- Locked contracts and policy refs.
- Content-addressed artifacts.
- Deterministic gate logic.
- Human approvals.

Untrusted boundary:

- Target repository contents.
- Agent output.
- Tool output.
- Reviewer output.
- Generated patch contents.

Untrusted data must be labeled when inserted into prompts, artifacts, and
reports.

## Explicit Deferrals

Deferred beyond Phase 1:

- Autonomous merge, deploy, release, or rollback.
- Hosted SaaS tenancy.
- Broad adapter parity.
- Production credential brokering.
- Multi-repo swarm scheduling.
- Full object-storage backend.
- Advanced LiveView workflow controls.

## Factory-Kernel Primitives

The factory-kernel primitives that must not be cut are PlanAudit, traceability,
HumanDecision, HumanApproval, AgentBrief, ContractLock, RunSpec, StationPlan,
StationRun, StationEffect, LedgerEvent, transactional outbox, Policy.Engine,
ToolExecutor, AgentRunner event envelope, PatchSet, EvidenceRecorder, RunCheck,
content-addressed artifacts, RunBundle, Review, Gate, canary health, and replay.

## Verification Matrix Mapping

This document maps to conveyor-quality-ci-evals-vmr.13. The docs validator must
fail if required architecture sections, the L1 target, or the no-auto-merge and
no-deploy rule are removed.

## Verification Mapping

The Phase 0/1 docs contract check maps this document to
conveyor-quality-ci-evals-vmr.13 and emits structured findings for missing
sections or missing invariant phrases.
