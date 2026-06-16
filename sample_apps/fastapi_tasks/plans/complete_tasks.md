# Complete Tasks Plan

## Goal

Add the smallest completion behavior to the FastAPI Tasks sample: a client can mark one existing task complete and then see that completed state when listing tasks.

## Non-Goals

- Auth
- Pagination
- Un-completing tasks
- Bulk updates
- Deployment

## Normalized Conveyor Plan

```json conveyor-plan@1
{
  "schema_version": "conveyor.plan@1",
  "plan_id": "fastapi-tasks-complete-plan",
  "title": "Complete tasks in the sterile FastAPI sample",
  "objective": "Produce PR-quality evidence for marking one existing sample task complete without merging or deploying.",
  "autonomy_level": "L1",
  "cutline": "TRACER_REQUIRED",
  "tasks": [
    {
      "task_id": "SLICE-001",
      "title": "Mark an existing task complete",
      "acceptance": [
        "REQ-001: A client can mark one existing task complete.",
        "REQ-002: GET /tasks shows completed=true for that task after completion.",
        "REQ-003: Completing an unknown task returns 404 without mutating existing tasks.",
        "REQ-004: Completing an already-completed task is idempotent and keeps completed=true."
      ],
      "evidence_required": [
        "baseline_regression pytest JUnit XML",
        "acceptance_locked pytest JUnit XML",
        "structured plan_audit result",
        "run bundle command transcript"
      ]
    }
  ]
}
```

## Requirements

| Requirement | Statement | Acceptance | Test | Slice |
| --- | --- | --- | --- | --- |
| REQ-001 | Add a completion operation for one existing task. | AC-001 | tests/acceptance_locked/test_complete_task.py::test_complete_existing_task | SLICE-001 |
| REQ-002 | Preserve completed state in list responses. | AC-002 | tests/acceptance_locked/test_complete_task.py::test_completed_task_is_listed | SLICE-001 |
| REQ-003 | Return 404 for unknown task completion without mutating state. | AC-003 | tests/acceptance_locked/test_complete_task.py::test_complete_unknown_task_does_not_mutate_list | SLICE-001 |
| REQ-004 | Treat repeated completion as idempotent. | AC-004 | tests/acceptance_locked/test_complete_task.py::test_complete_already_completed_task_is_idempotent | SLICE-001 |

## Acceptance Criteria

- AC-001: Given a task created through `POST /tasks`, when the client requests completion for that task, the response is successful and returns the same task with `completed=true`.
- AC-002: Given a completed task, `GET /tasks` returns that task with `completed=true` and preserves the existing create/list behavior.
- AC-003: Given an unknown task id, the completion request returns 404 and `GET /tasks` still returns the same task list as before the request.
- AC-004: Given an already-completed task, repeating the completion request succeeds and leaves the task completed without creating duplicates.

## Architecture and Constraints

The sample remains isolated from Conveyor core. The implementation should extend the in-memory `TaskStore` and FastAPI app only.

The likely endpoint is `POST /tasks/{task_id}/complete` because the feature is an action on one task and the plan intentionally defers generic update semantics.

The store must keep its lock discipline and must not add network, database, production secrets, authentication, deployment, or pagination dependencies.

## Risk

The main risk is weakening the baseline create/list behavior while adding completion. The baseline_regression suite must run before acceptance_locked tests and must block implementation unless the Slice explicitly targets baseline repair.

The second risk is broadening the sample beyond the tracer need. The non-goals are fixed for this plan and should be treated as out of scope by plan audit and review.

## Test Strategy

1. Run `scripts/run_baseline.sh` and require `suite=baseline_regression`, `status=passed`, and zero failures or errors.
2. Add `tests/acceptance_locked/test_complete_task.py` for AC-001 through AC-004.
3. Run the acceptance_locked suite after baseline_regression.
4. Emit JUnit XML and structured summaries for both suites.
5. Preserve raw pytest logs and command transcripts in the run bundle.

## Decisions

- Use L1 assisted execution only.
- Use a single Slice, `SLICE-001`, so the tracer has one bounded implementation target.
- Keep completion idempotent rather than creating an error for repeated completion.
- Defer auth, pagination, un-completing, bulk updates, and deployment.

## Handoff

This plan is handoff_ready when `scripts/plan_audit.py plans/complete_tasks.md` reports zero findings.
