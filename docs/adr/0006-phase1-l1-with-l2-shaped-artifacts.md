# ADR 0006: Phase 1 Is L1 With L2-Shaped Artifacts

## Status

Accepted for Phase 0/1.

## Context

Phase 1 must prove the end-to-end tracer without granting Conveyor merge or deploy authority. At the same time, future levels need artifacts that are structured enough to support stronger automation later.

This creates an intentional distinction: Phase 1 behavior is L1 assisted execution, while its artifacts should be shaped so future L2 work can evaluate them.

## Decision

Phase 1 is L1 with L2-shaped artifacts. Conveyor may create plans, patches, evidence, reviews, gates, and reports, but it does not auto-merge or deploy.

Artifacts should include the fields future L2 automation would need: schema versions, run IDs, gate outcomes, reviewer findings, policy references, artifact digests, and human decision placeholders.

## Consequences

Downstream schemas must not omit merge/deploy decision fields merely because Phase 1 does not act on them.

Reports must clearly distinguish prepared-for-review artifacts from authorized integration actions.

Autonomy-level documentation and gate behavior must agree on the L1 boundary.

## Rejected Alternatives

- Build L1-only loose artifacts. Rejected because future automation would require a disruptive schema redesign.
- Enable L2 behavior early because artifacts resemble L2. Rejected because authority and artifact shape are separate decisions.
- Hide merge/deploy fields until later. Rejected because human decisions need explicit recorded placeholders.

## Dependent Beads

- `conveyor-phase0-foundations-hsh.1`
- `conveyor-plan-traceability-kernel-0zk.1`
- `conveyor-evidence-artifacts-schemas-b1b.2`
- `conveyor-operator-ui-reporting-auc.4`

## Verification Matrix

Mapped in `conveyor-quality-ci-evals-vmr.13`.
