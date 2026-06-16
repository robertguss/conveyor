# Conveyor Autonomy Levels

## Purpose

This document defines the autonomy ladder used by Conveyor. Conveyor is a deterministic conductor plus stochastic agents, so every autonomy level separates what the conductor may decide from what an agent may suggest.

Phase 1 produces PR-quality evidence but does not auto-merge or deploy. The Phase 1 L1 target is the only target for the first tracer.

## Level Summary

| Level | Name | Conveyor Authority | Human Role |
| --- | --- | --- | --- |
| L0 | Observe | Read context and report findings. No workspace mutation. | Decide all actions. |
| L1 | Supervised Patch | Prepare plans, run bounded tools, create patches, collect evidence, and stop at a gate. | Approve merge and deploy decisions. |
| L2 | Supervised Integration | Coordinate multiple patches and CI retries inside approved boundaries. | Approve final integration and release. |
| L3 | Conditional Merge | Merge only within pre-approved repos, policies, and test gates. | Approve policy and monitor exceptions. |
| L4 | Conditional Deploy | Deploy only within pre-approved service, rollback, and incident boundaries. | Own production risk and emergency stops. |

Levels above L1 are design placeholders. They must not be implemented by accident during Phase 0 or Phase 1.

## L0 Observe

At L0, Conveyor may inspect files, Beads, messages, logs, schemas, and previous run bundles. It may create a report but must not edit source, update issue state, reserve files, or run mutating commands.

L0 is useful for scout, audit, replay, and review stations where the safest output is a finding set.

## L1 Supervised Patch

At L1, Conveyor may make bounded repository edits, run configured checks, collect evidence, and prepare a PR-quality package. The run must name its Bead, workspace, policy, station plan, tool permissions, and expected evidence before mutating code.

L1 stops before merge and deployment. A human remains responsible for deciding whether the PR-quality evidence is sufficient.

## L2 Through L4 Deferrals

L2, L3, and L4 are deferred. Phase 1 must not rely on them. Any code or configuration that appears to enable autonomous merge or deploy is a policy violation unless a later Bead explicitly raises the target level and updates this contract.

The factory-kernel primitives that must not be cut still apply at every future level: `RunSpec`, `TaskSpec`, `StationPlan`, `ToolInvocation`, `EvidenceRecord`, `ReviewRecord`, `GateDecision`, and `RunBundle`.

## Permission Rules

Each autonomy level must declare allowed tools, denied tools, network policy, credential policy, workspace mutation policy, and gate behavior. Missing policy means deny.

Agents may propose actions outside the current level, but Conveyor must record the proposal as blocked evidence and must not execute it.

## Evidence Requirements

Every autonomy transition requires evidence. At L1, the minimum evidence is the normalized task, station plan, tool transcript, artifact manifest, structured findings, tests or checks, and deterministic gate result.

Evidence must be sufficient to distinguish agent intent from conductor authority.

## Verification Mapping

`conveyor-quality-ci-evals-vmr.13` maps this autonomy contract to the docs contract check. `python3 scripts/check_docs_contract.py` verifies the required headings, the no-auto-merge statement, the Phase 1 L1 target, and the factory-kernel primitive statement; `.github/workflows/docs-contract.yml` runs the same check in CI.
