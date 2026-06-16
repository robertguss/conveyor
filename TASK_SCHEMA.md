# Conveyor Task Schema

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

This document defines the Phase 0/1 task contract for plans, requirements,
Slices, AgentBriefs, RunSpecs, StationPlans, readiness, and structured findings.

## Schema Contract

This file defines the Phase 0/1 task contract in prose. The local schema
registry will later provide machine-readable versions for public artifacts.
Until then, implementations must preserve these field meanings and fail
explicitly on unknown or unsupported schema versions.

## Schema Identity

The task contract uses versioned identities including conveyor.plan@1,
agent_brief@1, run_spec@1, and station_plan@1. Unknown or unsupported identities
must fail explicitly.

## Versioning

Task contracts must carry a schema version. Phase 1 uses conveyor.plan@1,
run_spec@1, station_plan@1, and agent_brief@1 vocabulary.

Compatibility rules:

- Unknown major versions fail explicitly.
- Unsupported versions fail explicitly.
- Future minor versions may be accepted only when documented semantic
  compatibility exists.
- Best-effort parsing is not allowed for handoff-ready work.

## Required Fields

Required fields are the minimum fields needed to make a plan auditable, a Slice
bounded, an AgentBrief executable, and a RunSpec replayable. Missing required
fields block handoff-ready status.

## Validation Rules

Validation must check schema version, required fields, traceability, explicit
non-goals, acceptance coverage, required tests, policy refs, protected paths,
and unsupported version behavior.

## Plan Fields

A normalized plan must include:

- schema_version.
- project key and repository refs.
- goal.
- non_goals.
- requirements with stable IDs, source refs, and status.
- acceptance criteria with stable IDs.
- required verification commands.
- risk and safety notes.
- architecture constraints and decisions.
- explicit human decisions and approvals.
- Slice list with traceability back to requirements and acceptance criteria.

Prose-only plans may lint, but they cannot become handoff-ready.

## Requirement Fields

Each requirement must include:

- Stable requirement ID.
- Source section or artifact ref.
- Status: active, deferred, out_of_scope, or superseded.
- Acceptance criteria refs.
- Required test refs where applicable.
- Slice refs or a documented reason none apply.

Open or orphaned requirements block handoff-ready status.

## Slice Fields

Each Slice must include:

- Stable Slice ID.
- Goal and current behavior.
- Desired behavior.
- Requirement refs.
- Acceptance criteria refs.
- Out-of-scope items.
- Risk notes.
- DiffPolicy refs.
- Required tests.
- Verification commands.
- AgentBrief ref.

A Slice is too vague if a reviewer cannot determine what files, behavior, and
tests are in scope.

## AgentBrief Fields

An AgentBrief must include:

- schema_version.
- Slice ref.
- Current behavior.
- Desired behavior.
- Key interfaces.
- Acceptance criteria refs.
- Required tests and command specs.
- Out-of-scope items.
- Risk and policy notes.
- Allowed write paths.
- Protected paths.
- Autonomy level.
- Contract digest.

The Phase 1 target autonomy level is L1.

## RunSpec Fields

RunSpec is immutable once execution starts. It must include:

- schema_version.
- run_attempt_id.
- project ref.
- plan contract digest.
- AgentBrief digest.
- base commit or source identity.
- policy profile refs.
- toolchain profile refs.
- TestPack refs.
- StationPlan ref.
- artifact schema versions.
- autonomy level.
- AGENTS.md digest where applicable.

## StationPlan Fields

StationPlan is a versioned capsule describing the deterministic conductor path.
The Phase 1 linear plan includes readiness, baseline, acceptance calibration,
context scout, prompt builder, implementation, evidence recording, review, gate,
canary freshness, report projection, optional post-integration checks, and
retrospective.

Each station must define:

- Name and version.
- Inputs and required refs.
- Idempotency key.
- Policy profile.
- Expected outputs.
- Failure categories.
- Artifact refs.

## Human Decisions

HumanDecision and HumanApproval records are required for:

- Architecture choices that affect the contract.
- Scope exclusions.
- Contract changes.
- Acceptance weakening.
- Required test changes.
- Policy weakening.
- External integration expansion.

## Readiness

A task can become ready only when the plan, Slice, AgentBrief, acceptance
criteria, tests, policy, DiffPolicy, and protected paths are complete enough for
bounded execution.

Readiness failures must be structured findings with stable categories and
NextAction guidance.

## Task Lifecycle

The task lifecycle moves from plan draft to audited plan, approved Slice, ready
AgentBrief, locked RunSpec, station execution, evidence recording, review, gate,
report projection, and human integration decision.

## Structured Findings

Task validation failures must emit structured findings naming the missing or
invalid field, affected artifact, schema identity, severity, and NextAction.
Findings must reference conveyor-quality-ci-evals-vmr.13 where they enforce this
contract.

## Factory-Kernel Primitives

Task readiness depends on factory-kernel primitives that must not be cut:
PlanAudit, traceability, HumanDecision, HumanApproval, AgentBrief, ContractLock,
RunSpec, StationPlan, locked TestPack, Policy.Engine, ToolExecutor, and
LedgerEvent.

## Verification Matrix Mapping

This document maps to conveyor-quality-ci-evals-vmr.13. The docs validator must
fail if required task sections, the L1 target, or the no-auto-merge and
no-deploy rule are removed.

## Explicit Deferrals

Deferred beyond this prose contract are the full local schema registry, broad
artifact migration rules, hosted workflow templates, and autonomous merge or
deploy task states.

## Verification Mapping

The Phase 0/1 docs contract check maps this document to
conveyor-quality-ci-evals-vmr.13 and emits structured findings for missing
sections or missing invariant phrases.
