# ADR 0003: Docker Is Not the Security Boundary

## Status

Accepted for Phase 0/1.

## Context

Conveyor will run commands against untrusted repositories and agent-produced changes. Docker can help isolate tools and normalize environments, but containerization alone is not a complete security model.

Phase 1 needs explicit command policy, credential policy, network posture, workspace scope, evidence capture, and gate behavior regardless of whether a station runs locally or in a container.

## Decision

Docker is an execution convenience, not the security boundary. The security boundary is the conductor-enforced policy profile plus recorded evidence for command class, sandbox, credentials, network, file scope, and gate result.

Container settings may strengthen isolation, but they do not replace policy checks or human approval for risky actions.

## Consequences

Policy code must deny unsafe commands even when they run inside Docker.

RunSpec records container use as one environment fact, not as proof that a command is safe.

Credentials and network access remain denied by default for hermetic Phase 1 runs.

## Rejected Alternatives

- Treat Docker as enough isolation for arbitrary commands. Rejected because host mounts, credentials, network, and kernel exposure remain meaningful risks.
- Disable all container execution until a perfect sandbox exists. Rejected because Phase 1 still needs reproducible local execution for safe command classes.
- Hide sandbox decisions inside adapter code. Rejected because reviewers need policy evidence in the run bundle.

## Dependent Beads

- `conveyor-safety-policy-sandbox-qsn.1`
- `conveyor-safety-policy-sandbox-qsn.2`
- `conveyor-safety-policy-sandbox-qsn.3`
- `conveyor-phase0-foundations-hsh.5`

## Verification Matrix

Mapped in `conveyor-quality-ci-evals-vmr.13`.
