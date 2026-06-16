# ADR 0004: Locked TestPack and ContractLock Are Never-Cut Primitives

## Status

Accepted for Phase 0/1.

## Context

The Phase 1 tracer needs a sterile sample app and contract fixtures that prove Conveyor can detect both successful implementation and weakened requirements. Without stable fixtures, a demo can pass while the product loses its trust properties.

TestPack and ContractLock are the minimum fixtures that let Conveyor verify behavior, evidence quality, and contract weakening independently of live services.

## Decision

Locked TestPack and ContractLock fixtures are never-cut primitives for Phase 1.

The TestPack provides known-good and known-bad implementation scenarios. ContractLock fixtures prove that weakening acceptance criteria, schemas, tests, or review gates is detected and reported.

## Consequences

Phase 1 planning must keep sample app fixtures, contract-diff fixtures, and canary fixtures in scope even when schedule pressure appears.

CI and e2e harnesses must preserve raw logs and structured summaries for fixture runs.

Reports must identify whether a failure came from implementation, fixture setup, contract weakening, or gate behavior.

## Rejected Alternatives

- Use only the Conveyor codebase as the test target. Rejected because product tests need a sterile task app with known baseline behavior.
- Rely on live provider tests for trust. Rejected because Phase 1 default CI must be hermetic and reproducible.
- Treat contract weakening as a later polish feature. Rejected because the trust claim depends on detecting weakened contracts from the start.

## Dependent Beads

- `conveyor-sample-app-testpack-6q4.1`
- `conveyor-sample-app-testpack-6q4.2`
- `conveyor-plan-traceability-kernel-0zk.5`
- `conveyor-quality-ci-evals-vmr.14`

## Verification Matrix

Mapped in `conveyor-quality-ci-evals-vmr.13`.
