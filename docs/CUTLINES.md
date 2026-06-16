# Conveyor Phase 0/1 Cutlines

## Purpose

Cutlines protect the Phase 0/1 schedule by making scope decisions explicit. Every Phase 0/1 Bead must carry exactly one cutline label so triage can distinguish tracer blockers from trust primitives, instrumentation, and deferred work.

This document is mapped in `conveyor-quality-ci-evals-vmr.13`.

## Cutline Labels

### TRACER_REQUIRED

Label: `cutline:tracer-required`

Meaning: required to prove the Phase 1 tracer from task intake through plan, implementation, evidence, review, gate, and report. Removing this work would break the visible end-to-end path.

Examples include the control-plane scaffold, sample task app, e2e harness, station execution, report generation, and operator commands needed to run the tracer locally.

### TRUST_REQUIRED

Label: `cutline:trust-required`

Meaning: required to keep the tracer honest. Removing this work may leave a demo that runs but cannot be trusted.

Examples include schemas, evidence validation, policy fixtures, ADRs, canaries, review gates, redaction, contract weakening checks, and provenance.

### INSTRUMENT_ONLY

Label: `cutline:instrument-only`

Meaning: instrumentation or observability that improves diagnosis without owning the core tracer or trust boundary. This work should not block the smallest tracer unless the verification matrix explicitly marks it blocking.

Examples include dashboards, metrics, traces, event enrichment, and reporting polish that can be advisory for Phase 1.

### DEFER

Label: `cutline:defer`

Meaning: explicitly out of the Phase 0/1 active implementation path. Deferred work can be documented or sketched, but it must not create active migrations, runtime obligations, or hidden schedule dependencies.

Examples include future resource sketches, autonomous merge/deploy paths, multi-tenant policy, long-running production operations, and marketplace-style extension systems.

## Never-Cut Items

Never-cut items are the minimum trust and tracer primitives that must remain in scope:

- Task envelope, RunSpec, and station plan.
- Evidence records, review records, gate decisions, and run bundle index.
- Policy profiles, redaction/quarantine semantics, and command transcripts.
- Locked TestPack and ContractLock fixtures.
- Gate canaries that fail closed.
- Phase 1 L1 boundary with no auto-merge and no auto-deploy.
- BEAM/Ash conductor ownership of canonical run truth.

Never-cut work should normally be labeled `cutline:tracer-required` or `cutline:trust-required`.

## Cut-First Items

Cut-first items are useful but should move behind the cutline before trust or tracer primitives are weakened:

- UI polish beyond the minimal operator surface.
- Extra dashboard charts after required evidence paths exist.
- Provider integrations not needed by the hermetic tracer.
- Live credential workflows.
- Production deployment workflows.
- Cross-repo marketplace or memory features.
- Future resources that are not activated in Phase 0/1.

Cut-first work should normally be labeled `cutline:instrument-only` or `cutline:defer`.

## Triage Rules

Every Phase 0/1 Bead must carry exactly one of:

- `cutline:tracer-required`
- `cutline:trust-required`
- `cutline:instrument-only`
- `cutline:defer`

Missing cutline labels are blocking hygiene findings. Multiple cutline labels are also blocking because they make priority ambiguous.

`TRACER_REQUIRED` and `TRUST_REQUIRED` work cannot silently omit verification. If a test layer is not applicable, the verification matrix must record an approved N/A rationale.

`INSTRUMENT_ONLY` work should be advisory unless a Bead explicitly promotes it to a blocking prerequisite.

`DEFER` work may document future shape, but it must not add active migrations or runtime obligations.

## Verification

Run:

```bash
python3 scripts/check_cutlines.py
```

The command emits `conveyor.cutline_audit@1` JSON with structured findings for missing policy text, unknown cutline labels, missing cutline labels, multiple cutline labels, or invalid Phase 0/1 issue records.
