# Deferred Resource Sketches

## Purpose

This document records resource concepts Conveyor intentionally defers during
Phase 0/1. They are product-shaped ideas, not active Ash resources, not database
tables, and not migration targets yet. A concept becomes an active table only
when a workflow needs lifecycle, permissions, querying, retention, or transition
guards that cannot be represented by the current RunSpec, Slice, StationRun,
artifact, policy, and report records.

`docs/future-schemas/deferred_resources.json` is the machine-readable contract.
`scripts/check_future_schemas.py` validates the contract and scans
`priv/repo/migrations` to ensure these deferred resources have not become active
migrations.

## Verification Mapping

This documentation satisfies `conveyor-phase0-foundations-hsh.8` and is mapped
by `conveyor-quality-ci-evals-vmr.13` as documentation with runtime tests marked
N/A for Phase 0/1.

Run:

```bash
python3 scripts/check_future_schemas.py
```

The checker emits `conveyor.deferred_resource_check@1` JSON with structured
findings for missing activation phases, deferral reasons, seed fields, event
types, or accidental migrations.

## Deferred Resources

### WorkspacePool

**Activation phase:** Phase 2.

**Deferral reason:** Phase 1 needs one hermetic workspace per run and does not
need fleet scheduling, lease balancing, or workspace reuse.

**Phase 0/1 seed fields:** RunSpec workspace root, ToolchainProfile image
digest, sandbox policy, station command roots, artifact root digest.

**Expected invariants:** a workspace lease belongs to one RunAttempt at a time;
lease cleanup is idempotent; workspace provenance is tied to the RunBundle root.

**Expected event types:** workspace_pool.lease_requested,
workspace_pool.lease_granted, workspace_pool.cleanup_recorded.

**Active migration:** none in Phase 0/1.

### TaskClaim

**Activation phase:** Phase 2.

**Deferral reason:** Beads and Agent Mail handle current work claiming; Conveyor
does not need an internal multi-tenant queue until it schedules work itself.

**Phase 0/1 seed fields:** Slice id, AgentProfile id, RunAttempt id,
StationRun ownership, AgentBrief digest.

**Expected invariants:** one active claim per Slice; expired claims do not grant
write authority; claim transfer is recorded as an event.

**Expected event types:** task_claim.requested, task_claim.assigned,
task_claim.expired, task_claim.released.

**Active migration:** none in Phase 0/1.

### MergeQueueItem

**Activation phase:** Phase 3.

**Deferral reason:** Phase 1 produces PR-quality evidence but does not
auto-merge or deploy, so merge queue state would be premature.

**Phase 0/1 seed fields:** Gate decision, Review decision, PR body artifact,
RunBundle digest, ContractLock digest.

**Expected invariants:** only gate-passing runs can seed queue candidates;
human merge authority remains external; queue position changes are auditable.

**Expected event types:** merge_queue.candidate_recorded,
merge_queue.human_decision_linked, merge_queue.removed.

**Active migration:** none in Phase 0/1.

### BudgetLedger

**Activation phase:** Phase 2.

**Deferral reason:** Phase 1 needs RunBudget stops and evidence, not a durable
cross-run accounting ledger.

**Phase 0/1 seed fields:** RunBudget limit, StationRun duration, token/tool
usage summaries, non-progress stop findings.

**Expected invariants:** budget entries are append-only; overruns fail closed;
manual overrides include actor, reason, and artifact references.

**Expected event types:** budget_ledger.limit_recorded,
budget_ledger.usage_recorded, budget_ledger.stop_triggered.

**Active migration:** none in Phase 0/1.

### AgentReputation

**Activation phase:** Phase 4.

**Deferral reason:** Phase 1 evaluates each run from recorded evidence and does
not score long-lived agent identity quality.

**Phase 0/1 seed fields:** AgentProfile id, reviewer findings, gate outcomes,
canary outcomes, policy incidents.

**Expected invariants:** reputation is derived from evidence, not model brand;
scores are explainable; negative signals retain artifact references.

**Expected event types:** agent_reputation.signal_recorded,
agent_reputation.score_recomputed, agent_reputation.override_recorded.

**Active migration:** none in Phase 0/1.

### Memory

**Activation phase:** Phase 4.

**Deferral reason:** Phase 1 must avoid hidden agent memory influencing
reproducibility; all usable context is explicit in RunSpec, ContextPack, and
artifacts.

**Phase 0/1 seed fields:** ContextPack digest, dossier digest, lessons-learned
artifact, rejected approach notes, policy findings.

**Expected invariants:** memory is opt-in, provenance-bound, redactable, and
never silently injected into implementation prompts.

**Expected event types:** memory.candidate_recorded, memory.approved,
memory.redacted, memory.retired.

**Active migration:** none in Phase 0/1.

### ExternalTaskRef

**Activation phase:** Phase 2.

**Deferral reason:** Phase 1 can cite external task identifiers in plans and
reports without synchronizing external issue trackers.

**Phase 0/1 seed fields:** human plan id, Slice id, source repository path,
report external refs, Beads issue id.

**Expected invariants:** external refs are advisory; missing external systems do
not block local replay; imported refs record source and timestamp.

**Expected event types:** external_task_ref.linked,
external_task_ref.refreshed, external_task_ref.unavailable.

**Active migration:** none in Phase 0/1.
