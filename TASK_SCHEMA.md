# Conveyor Task Schema

## Purpose

This document defines the Phase 0/1 task contract. Conveyor is a deterministic conductor plus stochastic agents; this schema is how the conductor turns an issue and operator intent into bounded work.

Phase 1 produces PR-quality evidence but does not auto-merge or deploy. The Phase 1 L1 target means every task is scoped for supervised patch production and evidence capture.

## Schema Identity

Schema name: `conveyor.task@1`

A task is immutable once a run starts. If a human changes scope, Conveyor creates a new task version or a new run rather than mutating the original record.

## Required Fields

| Field | Type | Required Meaning |
| --- | --- | --- |
| `schema_version` | string | Must equal `conveyor.task@1`. |
| `task_id` | string | Stable identifier for this normalized task. |
| `issue_id` | string | Beads issue ID or explicit external issue reference. |
| `title` | string | Human-readable task title. |
| `intent` | string | What outcome the run is trying to produce. |
| `autonomy_level` | string | Must be `L0` or `L1` for Phase 1. |
| `cutline` | string | `TRACER_REQUIRED`, `TRUST_REQUIRED`, or another defined cutline. |
| `inputs` | object | Files, Beads, messages, fixtures, and references used as input. |
| `constraints` | array | Policy, scope, non-goals, and forbidden actions. |
| `acceptance_criteria` | array | Verifiable completion checks. |
| `station_plan_ref` | string | Reference to the `StationPlan` selected for the run. |
| `evidence_plan` | array | Evidence that must exist before gate review. |
| `human_approvals` | array | Required human approvals, including merge/deploy decisions. |
| `deferrals` | array | Explicit out-of-scope work. |

## Validation Rules

The task must name its Bead or equivalent issue, current autonomy level, expected evidence, and forbidden actions. Missing fields fail validation before tool execution.

The task must preserve non-goals. It must not expand a Phase 1 tracer into an issue tracker, LLM framework, deployment system, or autonomous merge flow.

## Task Lifecycle

Task states are `draft`, `planned`, `running`, `blocked`, `failed`, and `completed`. The gate determines final run status, but it does not rewrite the task acceptance criteria after the run begins.

If an agent discovers scope drift, Conveyor records a finding and either blocks the run or asks for a new task.

## Factory-Kernel Primitives

The factory-kernel primitives that must not be cut are `RunSpec`, `TaskSpec`, `StationPlan`, `ToolInvocation`, `EvidenceRecord`, `ReviewRecord`, `GateDecision`, and `RunBundle`. `conveyor.task@1` is the external task-facing part of `TaskSpec`.

## Structured Findings

Task validation findings use this shape:

```json
{
  "schema": "conveyor.finding@1",
  "severity": "error",
  "category": "task_schema",
  "field": "acceptance_criteria",
  "message": "missing required acceptance criteria",
  "matrix_ref": "conveyor-quality-ci-evals-vmr.13"
}
```

## Explicit Deferrals

Deferred task features include cross-repo task decomposition, multi-tenant assignment, autonomous priority changes, and hidden compatibility shims for deprecated task versions.

## Verification Mapping

`conveyor-quality-ci-evals-vmr.13` maps this schema to docs lint and later schema fixtures. For this Bead, `python3 scripts/check_docs_contract.py` verifies the required sections and invariant statements, and `.github/workflows/docs-contract.yml` runs the same check in CI.
