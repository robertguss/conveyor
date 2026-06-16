# ADR 0002: Evidence Is the Product Artifact

## Status

Accepted for Phase 0/1.

## Context

Conveyor is not valuable because it can ask an agent to edit code. It is valuable when it produces enough evidence for a human to review the proposed change without trusting hidden agent state.

Phase 1 produces PR-quality evidence but does not auto-merge or deploy. The durable output must therefore be the run bundle and report, not only the working tree diff.

## Decision

Evidence is a first-class product artifact. Every successful Phase 1 run must produce structured evidence records, command transcripts, artifact paths, redaction status, review findings, gate decisions, and a final run bundle index.

The report can be human-readable, but the evidence must also be machine-readable and schema-versioned.

## Consequences

Stations must write evidence even on failure.

Gate logic blocks when required evidence is missing, malformed, unredacted, or unsupported by schema version.

The UI and Mix commands should point to evidence paths and run bundle digests rather than only printing summaries.

## Rejected Alternatives

- Treat evidence as optional logs. Rejected because optional logs cannot support deterministic review or replay.
- Trust final agent summaries as the evidence package. Rejected because summaries can omit failed commands, policy denials, or weakened tests.
- Delay evidence schemas until after implementation. Rejected because implementation would then bake in accidental artifact shapes.

## Dependent Beads

- `conveyor-evidence-artifacts-schemas-b1b.2`
- `conveyor-quality-ci-evals-vmr.13`
- `conveyor-quality-ci-evals-vmr.14`
- `conveyor-operator-ui-reporting-auc.4`

## Verification Matrix

Mapped in `conveyor-quality-ci-evals-vmr.13`.
