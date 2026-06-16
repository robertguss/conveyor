# Phase 2-8 Hooks Seeded By Phase 0/1

## Purpose

Phase 0/1 should leave deliberate hooks for later Conveyor capabilities without
implementing those future systems early. This document names the Phase 0/1
fields that seed each future system and states the Phase 1 scope boundary.

This roadmap is documentation-only for `conveyor-observability-swarm-readiness-ohk.10`
and is mapped by `conveyor-quality-ci-evals-vmr.13`.

## Phase 1 Non-Implementation Rules

Do NOT implement merge queue in Phase 1.
Do NOT implement task claims in Phase 1.
Do NOT implement memory in Phase 1.
Do NOT implement economic governor in Phase 1.
Do NOT implement workspace pool in Phase 1.
Do NOT implement multi-repo orchestration in Phase 1.
Do NOT implement autonomous retry in Phase 1.

These rules keep future hooks from becoming accidental scope. Phase 1 produces
PR-quality evidence and operator reports; it does not auto-merge, deploy,
schedule fleets, allocate cross-run budgets, learn hidden memory, or self-heal
without a human-approved plan.

## Verification

Run:

```bash
python3 scripts/check_phase_hooks.py
```

The checker reads this file and `docs/roadmap/phase2_8_hooks.json`, then emits
`conveyor.phase_hooks_check@1` JSON with structured findings for missing seeded
fields or missing non-implementation rules.

## Future Systems

### Decomposition

**Future phase:** Phase 2.

**Phase 0/1 seeded fields:** human_plan.id, requirement.id,
acceptance_criteria.id, slice.id, contract_lock.digest, agent_brief.digest,
station_plan.dependencies.

**Later hook:** These fields let Conveyor split larger plans into ordered,
traceable Slices without changing the Phase 1 plan-audit contract.

**Phase 1 boundary:** Phase 1 audits and runs the Slice it is given; it does not
implement an autonomous decomposition queue.

### Parallel Fleet And Merge Queue

**Future phase:** Phase 3.

**Phase 0/1 seeded fields:** run_attempt.id, workspace.root,
toolchain_profile.digest, gate.decision, review.decision,
run_bundle.root_digest, pr_body.artifact.

**Later hook:** These fields seed parallel run comparison, workspace leasing,
and human-visible merge candidates.

**Phase 1 boundary:** Phase 1 does not implement merge queue, workspace pool,
or multi-repo orchestration.

### Verification Pyramid

**Future phase:** Phase 2.

**Phase 0/1 seeded fields:** verification_matrix.ref,
test_command.transcript, junit.path, schema_validation.report,
gate_canary.outcome, failure.category, next_action.

**Later hook:** These fields let future CI group evidence into unit,
integration, e2e, canary, replay, and policy layers.

**Phase 1 boundary:** Phase 1 records and gates evidence; it does not replace
project-specific test ownership.

### Autonomy And Self-Healing

**Future phase:** Phase 4.

**Phase 0/1 seeded fields:** autonomy.level, run_budget.stop,
policy_incident.id, review.findings, gate.findings, rejected_approach.notes,
retry_eligibility.finding.

**Later hook:** These fields let Conveyor reason about promotion, retry, and
self-healing policies from auditable evidence.

**Phase 1 boundary:** Phase 1 does not implement autonomous retry.

### Economic Governor

**Future phase:** Phase 5.

**Phase 0/1 seeded fields:** station_run.duration_ms, token_usage.summary,
tool_usage.summary, budget.limit, non_progress_stop.finding,
artifact_storage.bytes.

**Later hook:** These fields seed cost accounting, budget allocation, and
throughput tradeoff decisions.

**Phase 1 boundary:** Phase 1 does not implement economic governor.

### Learning Loop

**Future phase:** Phase 4.

**Phase 0/1 seeded fields:** context_pack.digest, dossier.digest,
reviewer_rubric.version, policy_finding.category, gate_finding.category,
rejected_alternatives.

**Later hook:** These fields let future memory or learning systems propose
reusable lessons while keeping provenance and redaction requirements attached.

**Phase 1 boundary:** Phase 1 does not implement memory.

### Throughput Upgrades

**Future phase:** Phase 6.

**Phase 0/1 seeded fields:** station.key, station_run.duration_ms,
queue_wait.duration_ms, artifact_digest.count, policy_decision.id,
canary_freshness.result, report_projection.duration_ms.

**Later hook:** These fields seed bottleneck analysis, station parallelism, and
operator-facing throughput tuning.

**Phase 1 boundary:** Phase 1 does not implement fleet scheduling or
multi-repo orchestration.
