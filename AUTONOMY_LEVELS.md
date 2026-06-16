# Conveyor Autonomy Levels

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

This document defines the autonomy levels Conveyor may assign to agents and
station runs. It sets the Phase 1 L1 target and names the permissions that must
remain unavailable until later product contracts authorize them.

## Autonomy Contract

Conveyor assigns autonomy to a run, Slice, station, and agent profile explicitly.
Autonomy is not implied by model capability. The conductor derives the maximum
allowed autonomy from policy, agent capabilities, project configuration, and the
locked contract.

An agent may be stochastic. Conveyor's station graph, policy decisions, artifact
digests, state transitions, and gate composition must remain deterministic.

## Level Summary

L0 observes, L1 prepares a supervised patch and evidence, L2 may supervise
repository automation, L3 may govern integration, and L4 would operate
production. Phase 1 implements only L1 assisted implementation.

## L0 Observe

L0 is observe-only.

Allowed behavior:

- Read approved context.
- Summarize repository structure and plan gaps.
- Produce findings, suggestions, or draft text.
- Run no mutating commands unless separately executed by the conductor under a
  non-agent station.

Required controls:

- No source mutation authority.
- No credential access.
- No merge, deploy, release, or publish authority.
- Findings are advisory until accepted by a human or a higher-level contract.

## L1 Assisted Implementation

L1 is the Phase 1 target.

Allowed behavior:

- Work on one approved Slice.
- Mutate only paths allowed by the locked DiffPolicy.
- Request or execute commands only through ToolExecutor and Policy.Engine.
- Produce a PatchSet, final response, and implementation notes.

Required controls:

- A complete AgentBrief and ContractLock are required before implementation.
- Baseline and acceptance calibration must run before implementation when the
  StationPlan requires them.
- The gate must independently apply the patch to a clean workspace.
- The conductor records evidence and gate results independently.
- A human reviews the dossier and decides whether to integrate the work.

L1 does not auto-merge or deploy.

## L1 Supervised Patch

L1 supervised patch authority allows an agent to propose code changes for one
approved Slice, within locked write paths, under ToolExecutor and Policy.Engine.
The output is a PatchSet plus evidence for human review. It is not merge or
deploy authority.

## L2 Supervised Repository Automation

L2 is deferred beyond Phase 1.

Intended behavior:

- Conveyor may open or update a pull request under explicit policy.
- Conveyor may run multiple bounded Slices for one approved plan.
- Conveyor may request human approval for contract changes or risky actions.

Required controls:

- Human approval remains required for merge and deploy.
- Contract weakening and policy weakening require explicit HumanApproval.
- Gate failures remain blocking.

## L3 Governed Integration

L3 is deferred beyond Phase 1.

Intended behavior:

- Conveyor may integrate changes after all required gates and explicit project
  policies pass.
- Integration is limited to repositories and branches configured for that level.

Required controls:

- Stronger reviewer health and canary requirements.
- Explicit branch protection compatibility.
- Recorded rollback and incident ownership path.

## L4 Production Operations

L4 is deferred beyond Phase 1 and outside the current product contract.

Intended behavior:

- Conveyor may deploy, release, roll back, or operate production systems.

Required controls:

- Not defined in Phase 0/1.
- Must require a new product contract, threat model, and verification matrix.

## L2 Through L4 Deferrals

L2, L3, and L4 are deferred beyond Phase 1. Phase 0/1 may document seams for
them, but those seams must be disabled or policy-blocked so the L1 tracer cannot
merge, deploy, release, publish, or operate production systems.

## Phase 1 Target

Phase 1 target autonomy level is L1. The tracer bullet must prove that L1 can
produce PR-quality evidence but does not auto-merge or deploy.

Any feature that requires L2, L3, or L4 authority is out of scope unless it is
implemented only as a disabled seam with tests proving Phase 1 cannot exercise
that authority.

## Capability Mapping

AgentProfile capabilities must lower, not raise, autonomy when support is
missing or unsafe.

Capability examples:

- Streaming events.
- Pre-exec command interception.
- Cancellation and heartbeat.
- Diff capture.
- Structured output.
- Cost reporting.
- MCP or slash-command support.
- Session resume.

If an adapter cannot support policy-mediated command execution, it must be
observe-only or otherwise capped below implementation authority.

## Escalation Rules

The following require human approval before continuing:

- Acceptance criteria weakening.
- Required test removal or identity change.
- Policy weakening.
- Protected path edits.
- Credential or network expansion.
- Contract-affecting plan changes.
- Any request to merge, deploy, release, publish, or force push.

## Permission Rules

Permissions are allowlisted by profile, station, and locked contract. Missing
adapter capabilities reduce authority. Protected paths, credential expansion,
network expansion, test weakening, policy weakening, merge, deploy, release, and
publish actions require human approval or remain blocked.

## Evidence Requirements

Every autonomy decision must be recorded with the selected level, profile,
capability snapshot, policy refs, command decisions, and gate result. A run that
claims L1 must prove that its output was independently verified by the conductor.

## Factory-Kernel Primitives

Autonomy enforcement depends on factory-kernel primitives that must not be cut:
AgentProfile, Policy.Engine, ToolExecutor, AgentBrief, ContractLock, RunSpec,
StationPlan, LedgerEvent, EvidenceRecorder, RunCheck, Review, Gate, canary
health, and RunBundle.

## Verification Matrix Mapping

This document maps to conveyor-quality-ci-evals-vmr.13. The docs validator must
fail if the L1 target, no-auto-merge rule, or factory-kernel primitive statement
is removed.

## Verification Mapping

The Phase 0/1 docs contract check maps this document to
conveyor-quality-ci-evals-vmr.13 and emits structured findings for missing
sections or missing invariant phrases.
