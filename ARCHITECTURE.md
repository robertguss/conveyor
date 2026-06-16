# Conveyor Architecture

## Purpose

Conveyor is a deterministic conductor plus stochastic agents. The architecture keeps deterministic control in the conductor and treats agent output as input that must be checked, recorded, and gated.

Phase 1 produces PR-quality evidence but does not auto-merge or deploy. The Phase 1 L1 target is a supervised tracer through the factory kernel.

## System Shape

The planned control plane is a BEAM application with Phoenix, LiveView, Ash, Oban, and Postgres. Phase 0 and Phase 1 can define contracts before the scaffold exists, but the contracts must be precise enough for the scaffold to implement without reinterpretation.

Conveyor coordinates external systems instead of replacing them:

- Beads supplies issue identity, priority, status, and dependencies.
- Agent Mail supplies agent identity, coordination, and advisory file reservations.
- Git supplies source history and patch boundaries.
- CI supplies independent checks.
- Agents supply stochastic implementation proposals.
- Conveyor supplies deterministic orchestration, evidence, and gates.

## Control Plane Components

The control plane is expected to contain:

- `Task Intake`: normalizes Beads issue data and operator intent into `TaskSpec`.
- `Policy Engine`: resolves autonomy level, sandbox, network, credentials, and forbidden actions.
- `Station Planner`: produces the ordered `StationPlan`.
- `Tool Executor`: runs bounded commands and records `ToolInvocation` evidence.
- `Agent Adapter`: sends prompts to coding agents and captures replies.
- `Evidence Store`: writes `EvidenceRecord`, artifacts, hashes, and run bundle indexes.
- `Review Engine`: builds `ReviewRecord` dossiers and risk findings.
- `Gate Engine`: emits deterministic `GateDecision` results.
- `Operator UI`: displays run state, evidence, and blocked decisions.

## Station Flow

The Phase 1 tracer uses these stations:

1. Readiness.
2. Baseline.
3. Acceptance calibration.
4. Scout.
5. Prompt.
6. Implement.
7. Evidence.
8. Review.
9. Gate.
10. Canary freshness.
11. Report.

Each station writes structured status and evidence. A station may stop the run when required policy, files, fixtures, or approvals are missing.

## Factory-Kernel Primitives

The factory-kernel primitives that must not be cut are:

- `RunSpec`
- `TaskSpec`
- `StationPlan`
- `ToolInvocation`
- `EvidenceRecord`
- `ReviewRecord`
- `GateDecision`
- `RunBundle`

These primitives form the smallest useful architecture. Without them, Conveyor cannot prove what it did, what an agent proposed, what policy allowed, or why the gate decided.

## Trust Boundaries

Trust boundaries sit between human approval, issue state, coordination state, workspace mutation, tool execution, network access, credentials, agent output, and evidence storage. Every boundary crossing must be explicit in the run evidence.

Generated code and generated documentation are untrusted until checked. Agent statements are untrusted until backed by artifacts or deterministic verification.

## Data and Artifact Boundaries

Run inputs are immutable once execution begins. Station outputs are append-only. The `RunBundle` ties inputs, transcripts, findings, artifacts, hashes, and gate decisions into a replayable package.

The database may index run state for UI and queries, but the run bundle remains the portable audit artifact.

## Explicit Deferrals

Deferred architecture includes multi-tenant authorization, production deploy orchestration, remote artifact storage, L2-L4 autonomy, generalized agent marketplace support, and full release management. These are intentionally outside the Phase 1 L1 target.

## Verification Mapping

`conveyor-quality-ci-evals-vmr.13` maps the architecture contract to docs lint, schema validation, e2e tracer logs, and future CI. For this Bead, `python3 scripts/check_docs_contract.py` verifies required files, sections, the no-auto-merge statement, the Phase 1 L1 target, and the factory-kernel primitive statement; `.github/workflows/docs-contract.yml` runs the same check in CI.
