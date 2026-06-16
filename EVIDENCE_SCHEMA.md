# Conveyor Evidence Schema

## Shared Contract

Conveyor is a deterministic conductor plus stochastic agents.

Phase 1 target autonomy level is L1.

Phase 1 produces PR-quality evidence but does not auto-merge or deploy.

The factory-kernel primitives must not be cut.

Phase 1 L1 target: assisted implementation that produces PR-quality evidence
but does not auto-merge or deploy.

The factory-kernel primitives that must not be cut are listed in this document.

Conveyor verification matrix item: conveyor-quality-ci-evals-vmr.13.

## Purpose

This document defines the Phase 0/1 evidence contract for machine evidence,
station evidence, review and gate evidence, artifacts, redaction, dossiers, and
replay.

## Evidence Contract

This file defines the Phase 0/1 evidence contract in prose. Machine-readable
schemas and golden examples will live in the schema registry, but all
implementations must preserve these artifact meanings.

Evidence is created by the conductor. Agent output, reviewer output, and tool
output are untrusted inputs until checked and recorded.

## Schema Identity

Evidence artifacts use versioned identities including evidence@1, review@1,
gate@1, run_bundle@1, and related manifest/provenance vocabulary. Unknown or
unsupported identities must fail explicitly.

## Versioning

Public evidence artifacts must carry schema_version. Phase 1 uses evidence@1,
review@1, gate@1, run_bundle@1, and related artifact vocabulary.

Unknown or unsupported versions fail explicitly. Best-effort evidence parsing is
not allowed for gate decisions.

## Required Fields

Required fields are the minimum fields needed to connect evidence to a run,
Slice, locked contract, commands, acceptance criteria, policy decisions, review,
gate, artifacts, and known risks.

## Machine Evidence

evidence@1 must include:

- run_attempt_id.
- run_spec_sha256.
- project and Slice refs.
- plan, AgentBrief, ContractLock, policy, and TestPack refs.
- base and head identity.
- autonomy level.
- agent profile and capability snapshot.
- changed files and PatchSet ref.
- conductor-run commands with command specs and output refs.
- acceptance criteria status and evidence refs.
- baseline, acceptance, quality, policy, review, and gate summaries.
- known risks.
- generated timestamp.

## Station Evidence

Each StationRun must record input refs, idempotency key, policy profile,
command/tool refs where applicable, output artifact refs, structured findings,
status, and timing. Station effects must be replayable from recorded refs.

## Acceptance Mapping

Every acceptance criterion in the locked contract must be mapped to one of:

- passed with evidence refs.
- failed with evidence refs.
- blocked with structured findings.
- explicitly not applicable with approved rationale.

Missing acceptance mapping blocks success.

## Command Evidence

Command evidence must include:

- executable and argv.
- cwd.
- environment key names, not secret values.
- network mode.
- policy profile and decision.
- start and finish timestamps.
- exit code or termination reason.
- stdout/stderr artifact refs.
- output digests.
- timeout, runtime, and output byte counters.

## Artifact Integrity

Artifacts must be content-addressed before human-friendly projection. Projection
paths are not identity. The projector must verify bytes by digest before writing
files into a run bundle.

RunBundle must include a manifest and root digest that cover public artifacts,
redacted projections, and key refs.

## Redaction and Quarantine

Sensitive raw artifacts must be marked sensitive or quarantined and omitted from
public projection unless a policy explicitly permits a redacted version.

Redacted artifacts have their own digests. Manifests must distinguish raw
digests from redacted digests.

## Review Evidence

review@1 must include:

- reviewer profile.
- dossier digest.
- rubric version.
- decision.
- findings.
- recommendation.
- malformed or stale-review status when applicable.

Reviewer output is not enough to pass the gate. The gate composes reviewer
output with deterministic checks.

## Review and Gate Evidence

Review and gate artifacts must be linked to the same run_spec_sha256 and dossier
digest. Review findings are advisory until the deterministic gate composes them
with policy, tests, RunCheck, and canary health.

## Gate Evidence

gate@1 must include results for:

- Workspace integrity.
- Diff scope.
- Observed risk.
- Policy.
- Secret safety.
- Build, install, test, and acceptance checks.
- ContractLock.
- Quality delta.
- RunCheck.
- Provenance.
- Reviewer aggregation.
- Canary health.

Gate false negatives are a safety failure and must be covered by canary
fixtures.

## Human Dossier

The projected dossier must be useful without LiveView. It must include task
context, requirement traceability, summary, diff refs, acceptance mapping,
conductor verification commands, quality signals, reviewer result, gate result,
policy and safety findings, known risks, and bundle digests.

The PR body draft must state task, summary, acceptance checkboxes,
verification, risk, agent/profile, and evidence digest refs.

## Replay

Phase 1 must preserve enough data for R0 timeline replay and for later R1
artifact regeneration where supported. Old run bundles remain interpretable
through recorded schema versions and compatibility notes.

## Structured Findings

Evidence validation failures must emit structured findings naming the artifact,
schema identity, missing ref or mismatch, severity, and
conveyor-quality-ci-evals-vmr.13 mapping.

## Factory-Kernel Primitives

Evidence depends on factory-kernel primitives that must not be cut:
EvidenceRecorder, RunCheck, content-addressed blob storage, artifact projector,
RunBundle manifest, redaction/quarantine, Review, Gate, canary health,
LedgerEvent, and replay hooks.

## Verification Matrix Mapping

This document maps to conveyor-quality-ci-evals-vmr.13. The docs validator must
fail if required evidence sections, the L1 target, or the no-auto-merge and
no-deploy rule are removed.

## Explicit Deferrals

Deferred beyond Phase 1 are full object-storage backends, hosted retention
administration, broad SBOM policy, and autonomous release evidence.

## Verification Mapping

The Phase 0/1 docs contract check maps this document to
conveyor-quality-ci-evals-vmr.13 and emits structured findings for missing
sections or missing invariant phrases.
