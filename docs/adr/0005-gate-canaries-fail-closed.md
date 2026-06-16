# ADR 0005: Gate Canaries Fail Closed

## Status

Accepted for Phase 0/1.

## Context

Conveyor gates must detect missing evidence, unsafe policy, weakened contracts, bad reviews, stale canaries, and failed checks. A gate that cannot prove its inputs are fresh and complete cannot safely pass a run.

Phase 1 stops before merge or deploy, but its evidence package must still be trustworthy enough for human review.

## Decision

Gate canaries fail closed. If a canary is missing, stale, unsupported by schema, unable to run, or contradicted by evidence, the gate blocks and records a structured finding.

Gate failures must include a stable category, policy reference, artifact path, and next action.

## Consequences

Canary freshness is a station, not a footnote in the report.

Advisory findings cannot silently override blocking canary failures.

Operators should see a blocked run as a useful safety result when the system cannot prove trust.

## Rejected Alternatives

- Let stale canaries warn but pass. Rejected because stale canaries create false confidence.
- Allow an agent to waive canary failures. Rejected because waiver authority belongs to the human and must be recorded.
- Retry until a canary passes without preserving failures. Rejected because the first failure is evidence.

## Dependent Beads

- `conveyor-gate-review-canary-dcv.1`
- `conveyor-gate-review-canary-dcv.4`
- `conveyor-quality-ci-evals-vmr.14`
- `conveyor-evidence-artifacts-schemas-b1b.6`

## Verification Matrix

Mapped in `conveyor-quality-ci-evals-vmr.13`.
