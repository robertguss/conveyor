# ADR 0007: Merge and Deploy Authority Is Deferred

## Status

Accepted for Phase 0/1.

## Context

Conveyor can prepare a high-quality change package, but merge and deploy decisions carry repository, release, operational, and organizational risk. Phase 1 is intended to earn trust by making those decisions easier for humans, not by taking them.

This boundary must be explicit so future implementers do not accidentally add merge or deploy authority while building convenient operator flows.

## Decision

Merge and deploy authority is deferred beyond Phase 1. Conveyor Phase 1 may prepare branches, patches, reports, and gate recommendations, but a human must approve merge, release, deployment, credential changes, and irreversible external actions.

Any future autonomy level that changes this boundary requires a new ADR, updated safety policy, updated schemas, and verification matrix coverage.

## Consequences

Mix tasks, UI actions, agent adapters, and gates must not perform merge or deploy in Phase 1.

Reports should present merge/deploy as human next actions, not as automatic run steps.

CI and e2e tests should assert the no-auto-merge and no-auto-deploy invariant.

## Rejected Alternatives

- Allow auto-merge for green runs in Phase 1. Rejected because the trust boundary has not been proven yet.
- Allow deploy for sample apps only. Rejected because it blurs the product contract and creates misleading operator expectations.
- Leave merge/deploy behavior unspecified. Rejected because ambiguity becomes accidental authority.

## Dependent Beads

- `conveyor-phase0-foundations-hsh.1`
- `conveyor-operator-ui-reporting-auc.1`
- `conveyor-quality-ci-evals-vmr.13`
- `conveyor-quality-ci-evals-vmr.14`

## Verification Matrix

Mapped in `conveyor-quality-ci-evals-vmr.13`.
