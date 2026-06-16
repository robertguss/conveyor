# Conveyor Safety Policy

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

This document defines the Phase 0/1 safety boundary for Conveyor's conductor,
agents, tool execution, sandboxing, credentials, evidence, and human control.

## Safety Contract

Conveyor treats agentic work as untrusted until the deterministic conductor has
checked it against locked contracts, policy, and evidence requirements. The
default answer to unclear authority is to stop with a structured finding.

The Phase 1 tracer may produce PR-quality evidence. It must not merge, deploy,
release, publish, or operate production systems.

## Trust Boundaries

Trusted control-plane inputs:

- Versioned Conveyor code.
- Project configuration loaded by the conductor.
- Human-approved plans, decisions, and approvals.
- ContractLock records and immutable RunSpec values.
- Policy profiles and command grammar.
- Content-addressed artifacts whose digests have been verified.

Untrusted inputs:

- Repository content under change.
- AGENTS.md files from target repositories.
- Agent prompts, messages, tool output, and final responses.
- Generated patches.
- Reviewer output.
- Command stdout/stderr.
- External dependency metadata.

Untrusted inputs may be stored, labeled, redacted, and cited. They must not be
treated as authority.

## Command Policy

Executable station commands must go through ToolExecutor and Policy.Engine.
Raw shell strings are not a safe contract. Commands must be normalized into a
command spec with executable, argv, cwd, environment keys, stdin ref, timeout,
read roots, write roots, and network mode.

Minimum Phase 1 denylist coverage:

- Destructive git operations and force pushes.
- Unapproved filesystem deletion or overwrite outside the workspace.
- sudo or host privilege escalation.
- Docker socket access from the sandbox.
- Credential file reads.
- Production database URLs and deployment credentials.
- Pipe-to-shell installers.
- Release, publish, deploy, and package registry writes.
- Network egress unless a station policy explicitly permits it.

Blocked commands must produce policy findings before execution.

## Sandbox Policy

Phase 1 sandbox defaults:

- Non-root user.
- Rootless container runtime preferred.
- No privileged containers.
- No host home mount.
- No Docker socket mount.
- Read-only contract, policy, and TestPack mounts.
- Read-write workspace only for allowed implementation paths.
- No-new-privileges.
- Seccomp or AppArmor where available.
- Resource, runtime, idle, and output limits.
- Network disabled by default.

The gate must run in a clean workspace independent from the agent workspace.

## Credential Policy

Default CI and the deterministic demo must not require live provider
credentials. Any live adapter use must be explicit, scoped, recorded, and
separable from the hermetic tracer path.

Credential material must never be projected into public run bundles. Secret-like
content in prompts, logs, diffs, dossiers, or artifacts must be classified,
redacted, or quarantined according to policy.

## Network and Credential Policy

Network access is disabled by default for Phase 1 station execution. Any network
or credential expansion must be explicit in policy, tied to a station purpose,
recorded as evidence, and blocked when it exceeds the L1 contract.

## Evidence Policy

Agent self-report is not evidence. Evidence must come from conductor-owned
verification:

- Contract and policy refs.
- Base and head identifiers.
- Clean workspace materialization.
- Command specs, decisions, outputs, timings, and digests.
- Acceptance criteria mapping.
- Test and quality results.
- Review and gate outputs.
- Artifact manifest and root digest.
- Known risks and residual findings.

## Human Control

Human approval is required for:

- Merge.
- Deploy.
- Release.
- Contract weakening.
- Policy weakening.
- Acceptance weakening.
- Required test removal or replacement.
- Expansion of credentials, network, or protected write roots.

The default Phase 1 autonomy is L1 assisted implementation.

## Gate Behavior

The gate fails closed on missing evidence, policy violations, unsupported schema
versions, stale canary health, reviewer health failures, secret findings, or
clean-workspace verification failures. Gate output is evidence, not permission
to merge or deploy.

## Threat Classes

Phase 0/1 policy must account for:

- Malicious repository content.
- Malicious tool output.
- Policy evasion.
- Test weakening.
- Secret exposure.
- Supply-chain drift.
- Artifact tampering.
- Reviewer rubber stamps.
- Gate false negatives.
- Internal database probing.
- Host escape or overreach.

The dedicated threat-model bead will add fixtures and coverage for these
classes. This contract defines the minimum boundary that implementation must
respect.

## Failure Handling

Safety failures must stop the affected station or run with structured findings.
The system should preserve enough evidence for diagnosis while avoiding public
projection of secrets or quarantined artifacts.

## Explicit Deferrals

Deferred beyond Phase 1:

- Production deployment policy.
- Organization-wide credential brokering.
- Hosted multi-tenant isolation.
- Automatic dependency updates.
- Autonomous incident remediation.
- Broad network allowlist management.

## Factory-Kernel Primitives

Safety depends on factory-kernel primitives that must not be cut: Policy.Engine,
ToolExecutor, command grammar, ContractLock, locked TestPack, RunSpec,
StationPlan, LedgerEvent, artifact digests, RunCheck, Review, Gate, canary
health, and human approvals.

## Verification Matrix Mapping

This document maps to conveyor-quality-ci-evals-vmr.13. The docs validator must
fail if required safety sections, the L1 target, or the no-auto-merge and
no-deploy rule are removed.

## Verification Mapping

The Phase 0/1 docs contract check maps this document to
conveyor-quality-ci-evals-vmr.13 and emits structured findings for missing
sections or missing invariant phrases.
