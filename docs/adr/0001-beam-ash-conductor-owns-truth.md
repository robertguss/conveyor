# ADR 0001: BEAM/Ash Conductor Owns Truth

## Status

Accepted for Phase 0/1.

## Context

Conveyor coordinates stochastic coding agents, but the system cannot let agent text become the source of truth for run state, policies, evidence, or gates. Phase 0/1 needs one boring control plane that records durable facts and rejects ambiguous state transitions.

The planned stack is a BEAM control plane with Phoenix, Ash, Oban, and Postgres. This stack gives Conveyor explicit resources, transactions, background work, and observable process supervision without inventing a custom workflow framework.

## Decision

The BEAM/Ash conductor owns canonical truth for tasks, run specs, station state, evidence records, review records, gate decisions, and run bundles.

Agents may propose changes and summarize their station work, but their output is only an input to conductor-owned validation. The conductor persists the accepted state transition and the evidence that justified it.

## Consequences

Domain resources and migrations must model conductor-owned state before downstream stations depend on it.

Agent adapters must return typed payloads or artifacts; they must not mutate run truth directly.

Tests and reports should verify conductor state rather than trusting agent prose.

## Rejected Alternatives

- Let each agent write its own run state. Rejected because it loses deterministic replay and makes gates depend on untrusted narration.
- Use only flat files as the canonical database. Rejected because Phase 1 needs transactional station state, job retries, and queryable evidence.
- Build a custom scheduler before using Oban and BEAM supervision. Rejected because it adds risk without improving the trust boundary.

## Dependent Beads

- `conveyor-phase0-foundations-hsh.2`
- `conveyor-phase0-domain-state-9oy.1`
- `conveyor-agent-runtime-adapters-eop.1`
- `conveyor-operator-ui-reporting-auc.1`

## Verification Matrix

Mapped in `conveyor-quality-ci-evals-vmr.13`.
