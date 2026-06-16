# Conveyor Safety Policy

## Purpose

This policy defines the safety envelope for Phase 0 and Phase 1. Conveyor is a deterministic conductor plus stochastic agents; the conductor owns policy enforcement and the agents supply bounded proposals.

Phase 1 produces PR-quality evidence but does not auto-merge or deploy. The Phase 1 L1 target allows supervised patch creation only.

## Safety Contract

Conveyor defaults to deny when policy is missing, ambiguous, expired, or contradicted by evidence. A run may proceed only when the `RunSpec`, task, tool permissions, sandbox, and gate expectations are explicit.

The safety contract is designed for auditability. A blocked action is a useful result when it prevents unreviewed authority, credential exposure, unsafe network access, or irreversible mutation.

## Trust Boundaries

The primary trust boundaries are:

- Human operator authority.
- Beads issue state and dependency graph.
- Agent Mail coordination and file reservations.
- Source workspace and git state.
- Shell commands and external tools.
- Network egress.
- Credentials, tokens, and secrets.
- Generated code and generated documentation.
- Evidence artifacts and replay bundles.

Crossing a boundary requires a policy decision and an `EvidenceRecord`.

## Sandbox Policy

Phase 1 work runs in a local or hermetic workspace with bounded file scope. Tool execution must record command, arguments, working directory, environment summary, timeout, exit code, transcript path, and artifact paths.

Commands that delete files, discard git history, expose secrets, auto-merge, deploy, or mutate unreserved surfaces are out of policy for L1 unless the human explicitly authorizes the exact command and consequence.

## Network and Credential Policy

Network access is denied unless the `RunSpec` explicitly permits it for a named station. Live credentials are denied for hermetic tracer runs. If a tool requires credentials, Conveyor records a blocked finding rather than inventing or reusing ambient secrets.

Evidence must never depend on hidden credentials to be understood. A reviewer should be able to inspect the run bundle without privileged access.

## Gate Behavior

The gate is deterministic. It may pass, fail, or block. It must name the policy rule, missing evidence, failing check, or human decision required before any downstream action.

The gate does not merge or deploy in Phase 1. It prepares PR-quality evidence and stops.

## Factory-Kernel Primitives

The factory-kernel primitives that must not be cut are `RunSpec`, `TaskSpec`, `StationPlan`, `ToolInvocation`, `EvidenceRecord`, `ReviewRecord`, `GateDecision`, and `RunBundle`. Removing one of these primitives removes the evidence chain needed for safety.

## Failure Handling

Failures are first-class evidence. A failed command, missing section, stale canary, schema violation, policy denial, or reviewer objection must produce a structured finding with severity, category, station, path, and reproduction pointer.

Retries must not hide the original failure. They may add evidence but must preserve the first failing transcript.

## Explicit Deferrals

Deferred safety work includes production incident policy, multi-tenant authorization, secret broker integration, autonomous rollback, and L2-L4 approval flows. These are not part of the Phase 1 L1 target.

## Verification Mapping

`conveyor-quality-ci-evals-vmr.13` maps this policy to the docs contract check. `python3 scripts/check_docs_contract.py` emits structured findings for missing safety headings and missing invariant statements; `.github/workflows/docs-contract.yml` runs the same check in CI.
