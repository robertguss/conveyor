# Conveyor Phase 0/1 Threat Model

## Purpose

This document defines the Phase 0/1 threat model for Conveyor's trust kernel. The
agent, repository content, tool output, runtime environment, and generated
artifacts are untrusted until Conveyor records evidence that policy checks,
sandbox boundaries, review, and gate controls handled them.

Docker is a required execution boundary, but it is not a complete safety model.
Conveyor must also normalize commands, apply policy profiles, bind credentials to
explicit leases, record station effects, preserve tamper-evident artifacts, and
fail closed when evidence is stale, missing, malformed, or inconsistent.

## Verification Mapping

This threat model is mapped by `conveyor-quality-ci-evals-vmr.13` and provides
the source fixture for `conveyor-safety-policy-sandbox-qsn.1`.

The local coverage check is:

```bash
python3 scripts/check_threat_model.py
```

The check reads this document and `docs/fixtures/threat_model.json`, then emits
`conveyor.threat_model_coverage@1` JSON with one coverage record per threat
class. A passing result means each class has:

- a documented primary defense;
- a documented residual risk;
- at least one Phase 1 doctor check, test, canary, or policy fixture;
- a fixture record that names the expected station, command, and artifact.

## Trust Boundaries

Conveyor treats the following inputs and systems as separate trust domains:

- Human-authored product and plan contracts.
- Repository files, diffs, tests, hooks, and local scripts.
- Agent prompts, model output, reviewer output, and tool output.
- ToolExecutor command specs and sandbox execution results.
- Host environment, network access, filesystem roots, and credentials.
- Internal Postgres state, append-only ledger rows, and projected public reports.
- Content-addressed artifacts, run bundles, dossiers, and replay inputs.

Crossing a boundary requires a recorded policy decision, artifact digest, station
effect, or structured finding. Missing evidence is a blocking finding, not a
warning to ignore.

## Threat Classes

### Malicious Repo Content

**Primary defense:** Normalize repository paths and command roots before
execution, deny hidden host escapes, run repository code only through
ToolExecutor policy, and record every accepted file root in the RunSpec.

**Residual risk:** A repository can still contain valid-looking source or test
code that attempts social or semantic manipulation of an agent or reviewer.

**Phase 1 coverage:** Policy fixture `malicious_repo_content_path_escape`
exercises path/root normalization and expects a blocked command finding.

### Malicious Tool Output

**Primary defense:** Label tool output as untrusted context, bind it to artifact
digests, reject malformed schemas, and keep reviewer decisions tied to the exact
dossier digest they evaluated.

**Residual risk:** Correctly shaped output can still contain misleading prose or
partial evidence that requires reviewer and gate corroboration.

**Phase 1 coverage:** Test fixture `malicious_tool_output_prompt_injection`
checks that untrusted tool text is preserved as evidence without becoming policy
or instruction text.

### Policy Evasion

**Primary defense:** Evaluate normalized command specs against explicit policy
profiles, allowlists, denylists, environment policy, network policy, and
credential lease requirements before execution.

**Residual risk:** Policy profiles can be underspecified or stale if changes land
without a matching canary and verification matrix update.

**Phase 1 coverage:** Policy fixture `policy_evasion_shell_wrapper` checks that
wrapper commands do not bypass denylisted operations.

### Test Weakening

**Primary defense:** Compare planned acceptance checks, existing test commands,
and final diffs; require gate findings for removed, skipped, weakened, or
unmapped tests.

**Residual risk:** Some semantic weakening is visible only when acceptance
calibration and reviewer evidence are strong enough to notice it.

**Phase 1 coverage:** Canary `test_weakening_removed_assertion` expects the gate
to fail on a weakened-contract fixture.

### Secret Exposure

**Primary defense:** Credentials are issued only through CredentialLease records,
redaction is applied before public projection, and raw sensitive artifacts stay
quarantined behind private artifact paths.

**Residual risk:** A tool can still print secret-shaped data before the redactor
classifies it, so raw logs must remain private by default.

**Phase 1 coverage:** Doctor check `secret_exposure_env_leak` asserts that
secret-shaped environment variables and logs produce blocking findings.

### Supply Chain Drift

**Primary defense:** Record ToolchainProfile data, lock dependency inputs where
possible, compare dependency manifests across clean environments, and fail the
gate when runtime versions drift from the RunSpec.

**Residual risk:** Fresh upstream packages can change behavior while retaining
compatible version ranges unless the plan requires a stricter lock.

**Phase 1 coverage:** Test fixture `supply_chain_drift_unpinned_dependency`
expects drift to be reported with version and artifact references.

### Artifact Tampering

**Primary defense:** Store evidence and reports under content-addressed digests,
verify blob digests before projection, and compute a stable RunBundle root
digest for replay.

**Residual risk:** A compromised local filesystem can delete or hide artifacts;
Conveyor detects this as missing evidence but cannot reconstruct deleted bytes.

**Phase 1 coverage:** Canary `artifact_tampering_digest_mismatch` mutates a
recorded artifact and expects replay/report projection to fail.

### Reviewer Rubber Stamps

**Primary defense:** Reviewer profiles are separate from implementer profiles,
reviews are bound to dossier digests and rubric versions, and malformed or stale
reviews block the gate.

**Residual risk:** A reviewer can still produce shallow but schema-valid text,
which the gate must counter with required checks and evidence cross-references.

**Phase 1 coverage:** Test fixture `reviewer_rubber_stamp_empty_findings`
expects a review without substantive findings or checks to fail validation.

### Gate False Negatives

**Primary defense:** Gate decisions are deterministic, fail closed on stale or
missing evidence, and require every blocking finding category to include
severity, category, artifact references, and NextAction.

**Residual risk:** The gate can only evaluate checks represented in the current
policy, schema, and verification matrix.

**Phase 1 coverage:** Canary `gate_false_negative_missing_required_check`
omits required evidence and expects a blocking gate decision.

### Internal DB Probing

**Primary defense:** Station code accesses internal state through scoped
resources and append-only ledger APIs; public reports project only approved
artifact records and redacted summaries.

**Residual risk:** Bugs in resource authorization can expose internal run state
to an operator surface before projection filters apply.

**Phase 1 coverage:** Policy fixture `internal_db_probing_private_table`
checks that unapproved station/report access to private tables is blocked.

### Host Escape And Overreach

**Primary defense:** Docker sandbox defaults restrict capabilities, filesystem
mounts, host networking, and process privileges; commands outside declared roots
or network policy fail before execution.

**Residual risk:** Kernel, container runtime, or host misconfiguration can exceed
Conveyor's control, so doctor checks must make unsafe hosts explicit.

**Phase 1 coverage:** Doctor check `host_escape_privileged_container` asserts
that privileged container settings and host-root mounts are blocking findings.

## Fixture Contract

The structured fixture in `docs/fixtures/threat_model.json` is the machine
readable source of truth for coverage. Each threat class has:

- `id`: stable kebab/snake style identifier used by tests and reports;
- `title`: human-readable threat class title matching this document;
- `primary_defenses`: one or more defenses Conveyor must preserve;
- `residual_risks`: one or more explicit risks still present after defenses;
- `phase1_coverage`: at least one `doctor_check`, `test`, `canary`, or
  `policy_fixture` with an artifact path and expected blocking behavior.

Adding a threat class without coverage is invalid. Removing or weakening a
defense requires a separate human-approved contract change bead.
