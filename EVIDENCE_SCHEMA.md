# Conveyor Evidence Schema

## Purpose

This document defines the Phase 0/1 evidence contract. Conveyor is a deterministic conductor plus stochastic agents; evidence is how the conductor turns agent work into something reviewable.

Phase 1 produces PR-quality evidence but does not auto-merge or deploy. The Phase 1 L1 target requires evidence good enough for human review, not autonomous production action.

## Schema Identity

Schema name: `conveyor.evidence@1`

Evidence is append-only inside a run. Later stations may add context or retries, but they must not erase earlier transcripts or findings.

## Required Fields

| Field | Type | Required Meaning |
| --- | --- | --- |
| `schema_version` | string | Must equal `conveyor.evidence@1`. |
| `evidence_id` | string | Stable identifier for this evidence record. |
| `run_id` | string | Run that produced the evidence. |
| `task_id` | string | Normalized task under review. |
| `station_key` | string | Station that produced the evidence. |
| `started_at` | string | RFC 3339 timestamp. |
| `finished_at` | string | RFC 3339 timestamp or null for blocked records. |
| `status` | string | `pass`, `fail`, `blocked`, or `info`. |
| `command` | object | Command, working directory, environment summary, timeout, and exit code when applicable. |
| `transcript_path` | string | Path to captured stdout/stderr transcript. |
| `artifact_paths` | array | Files produced by the station. |
| `content_hashes` | object | Digests for artifacts needed for replay. |
| `findings` | array | Structured findings emitted by the station. |
| `policy_refs` | array | Policies or trust-boundary decisions applied. |
| `replay` | object | Local reproduction command or reason replay is unavailable. |

## Station Evidence

Every station writes a status line with station key, status, duration, and finding category. The Phase 1 station set includes readiness, baseline, acceptance calibration, scout, prompt, implement, evidence, review, gate, canary freshness, and report.

Agent messages are evidence only when preserved with timestamps and source attribution. Verified facts require artifacts, transcripts, schema validation, or deterministic checks.

## Review and Gate Evidence

Review evidence names risks, open questions, failing checks, and reviewer conclusions. Gate evidence names the exact policy or verification result used to pass, fail, or block.

The gate never auto-merges or deploys in Phase 1. It produces the final PR-quality evidence package and stops.

## Factory-Kernel Primitives

The factory-kernel primitives that must not be cut are `RunSpec`, `TaskSpec`, `StationPlan`, `ToolInvocation`, `EvidenceRecord`, `ReviewRecord`, `GateDecision`, and `RunBundle`. `conveyor.evidence@1` defines the durable shape of `EvidenceRecord`.

## Structured Findings

Evidence validation findings use this shape:

```json
{
  "schema": "conveyor.finding@1",
  "severity": "error",
  "category": "evidence_schema",
  "station_key": "gate",
  "message": "missing replay command",
  "matrix_ref": "conveyor-quality-ci-evals-vmr.13"
}
```

## Explicit Deferrals

Deferred evidence features include signed attestations, remote artifact storage, production deploy provenance, and cross-organization retention policy. Phase 1 uses local, replayable run bundles.

## Verification Mapping

`conveyor-quality-ci-evals-vmr.13` maps this schema to docs lint and later schema fixture validation. For this Bead, `python3 scripts/check_docs_contract.py` verifies required sections and invariant statements, and `.github/workflows/docs-contract.yml` runs the same check in CI.
