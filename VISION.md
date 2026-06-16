# Conveyor Vision

## Purpose

Conveyor is a deterministic conductor plus stochastic agents for agentic coding work. Its job is to turn a task into a reproducible run: select the policy, prepare the workspace, route prompts to coding agents, collect evidence, review the evidence, and stop at an auditable gate.

Conveyor is not a general issue tracker, LLM framework, deployment system, or autonomous production operator. It coordinates those surrounding systems through explicit contracts and leaves durable evidence that a human can inspect.

## Product Contract

Phase 1 produces PR-quality evidence but does not auto-merge or deploy. The Phase 1 L1 target is supervised execution: Conveyor may prepare plans, run bounded tools, gather evidence, and propose a pull request package, but a human remains responsible for merge and deployment decisions.

The product is the run record, not just the code change. A successful run produces enough evidence for another operator to replay the command path, inspect the trust decisions, and understand why the gate stopped or passed.

## Non-Goals

Conveyor does not replace GitHub, Beads, Agent Mail, CI, code review, or release automation. It does not own source-of-truth issue state. It does not keep secret credentials for arbitrary agents. It does not auto-merge, auto-deploy, or silently bypass policy in Phase 1.

Conveyor also does not hide stochastic behavior behind claims of determinism. Agents may be stochastic; Conveyor is deterministic in orchestration, artifact naming, policy checks, evidence validation, and gate decisions.

## Phase 0 and Phase 1 Cutline

Phase 0 establishes the product contract, schemas, control-plane scaffold, local policy, and fixtures. Phase 1 proves the tracer path on hermetic tasks with deterministic logs, replayable evidence, and no live production authority.

The cutline favors a small factory kernel over broad platform surface area. Anything not required to demonstrate the tracer path, evidence package, or gate should be deferred and named explicitly.

## Factory-Kernel Primitives

The factory-kernel primitives that must not be cut are:

- `RunSpec`: immutable description of the run inputs, environment, policy, and versions.
- `TaskSpec`: normalized task, acceptance criteria, constraints, and linked Beads issue.
- `StationPlan`: ordered station graph for readiness, scout, prompt, implement, evidence, review, gate, canary freshness, and report.
- `ToolInvocation`: command, sandbox, network, credential, and timeout envelope.
- `EvidenceRecord`: transcript, artifacts, findings, hashes, and replay pointers.
- `ReviewRecord`: reviewer dossier, checks performed, risks, and open questions.
- `GateDecision`: deterministic pass, fail, or blocked result with policy reasons.
- `RunBundle`: content-addressed package that ties every station artifact together.

These primitives are the minimum shape needed for trust. UI, scheduling, adapters, dashboards, and deployment integrations are secondary until the primitives are stable.

## Evidence Requirements

Every run must capture the commands that were attempted, their exit status, timestamped station boundaries, environment summary, relevant policy, artifact paths, structured findings, and final gate decision. Evidence must be deterministic enough for local replay without requiring live credentials or network access unless the `RunSpec` explicitly permits them.

Evidence must distinguish agent claims from verified facts. Conveyor records both, but gates only trust facts backed by artifacts, transcripts, schema validation, or deterministic checks.

## Trust Boundaries

Conveyor treats agents, generated code, shell commands, network access, credentials, and mutable workspaces as separate trust domains. Crossing a boundary requires an explicit policy decision and evidence record.

Human authority remains outside the automated boundary in Phase 1. A human may approve a merge or deployment after reading the evidence, but Conveyor must not take that action itself.

## Explicit Deferrals

Deferred work includes multi-tenant permissions, production deploy orchestration, autonomous merge, live credential brokering, generalized issue tracking, cross-repo planning, and long-running agent marketplace features. These deferrals can become Beads later, but they are not required for the Phase 1 tracer.

## Verification Mapping

`conveyor-quality-ci-evals-vmr.13` is the verification matrix owner for this contract. The docs contract check is `python3 scripts/check_docs_contract.py`, and CI wires it through `.github/workflows/docs-contract.yml`. The check emits structured findings for missing files, missing sections, missing invariant statements, and the `conveyor-quality-ci-evals-vmr.13` mapping reference.
