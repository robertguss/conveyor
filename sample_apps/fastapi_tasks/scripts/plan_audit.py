#!/usr/bin/env python3
"""Audit the FastAPI sample human plan for Conveyor handoff readiness."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


REQUIRED_REQUIREMENTS = ["REQ-001", "REQ-002", "REQ-003", "REQ-004"]
REQUIRED_NON_GOALS = ["auth", "pagination", "un-completing", "bulk updates", "deployment"]
REQUIRED_SCHEMA_VERSION = "conveyor.plan@1"
MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"
JSON_DECODER = json.JSONDecoder()


def finding(code: str, message: str, **extra: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "schema": "conveyor.plan_audit_finding@1",
        "severity": "error",
        "category": "plan_audit",
        "code": code,
        "message": message,
        "matrix_ref": MATRIX_REF,
    }
    payload.update(extra)
    return payload


def extract_plan_block(text: str) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    lines = text.splitlines()
    try:
        start = lines.index("```json conveyor-plan@1")
    except ValueError:
        return None, [finding("missing_plan_block", "plan is missing a ```json conveyor-plan@1 block")]

    body: list[str] = []
    for line in lines[start + 1 :]:
        if line == "```":
            break
        body.append(line)
    else:
        return None, [finding("unterminated_plan_block", "plan JSON block is missing its closing fence")]

    try:
        return JSON_DECODER.decode("\n".join(body)), []
    except json.JSONDecodeError as exc:
        return None, [finding("invalid_plan_json", f"plan JSON is invalid: {exc}")]


def audit_plan(plan_path: Path) -> dict[str, Any]:
    findings: list[dict[str, Any]] = []
    text = plan_path.read_text(encoding="utf-8")
    normalized = text.casefold()

    plan, block_findings = extract_plan_block(text)
    findings.extend(block_findings)

    if plan is not None:
        if plan.get("schema_version") != REQUIRED_SCHEMA_VERSION:
            findings.append(
                finding(
                    "unsupported_schema_version",
                    "plan block must use conveyor.plan@1",
                    actual=plan.get("schema_version"),
                )
            )
        if plan.get("autonomy_level") != "L1":
            findings.append(finding("invalid_autonomy_level", "sample plan must target L1"))
        if plan.get("cutline") != "TRACER_REQUIRED":
            findings.append(finding("invalid_cutline", "sample plan must be TRACER_REQUIRED"))

    for non_goal in REQUIRED_NON_GOALS:
        if non_goal not in normalized:
            findings.append(finding("missing_non_goal", f"missing non-goal: {non_goal}", non_goal=non_goal))

    for requirement in REQUIRED_REQUIREMENTS:
        requirement_rows = [line for line in text.splitlines() if line.startswith(f"| {requirement} ")]
        if not requirement_rows:
            findings.append(finding("missing_requirement", f"missing requirement row: {requirement}", requirement=requirement))
            continue

        row = requirement_rows[0]
        for token, code in (("AC-", "missing_acceptance_mapping"), ("test", "missing_test_mapping"), ("SLICE-", "missing_slice_mapping")):
            if token not in row:
                findings.append(
                    finding(
                        code,
                        f"{requirement} is missing {token} mapping",
                        requirement=requirement,
                    )
                )

    if "handoff_ready" not in normalized:
        findings.append(finding("missing_handoff_ready", "plan must name handoff_ready as the target result"))

    return {
        "schema": "conveyor.plan_audit_result@1",
        "matrix_ref": MATRIX_REF,
        "plan": str(plan_path),
        "status": "handoff_ready" if not findings else "blocked",
        "finding_count": len(findings),
        "findings": findings,
    }


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: plan_audit.py <plan.md>", file=sys.stderr)
        return 2

    result = audit_plan(Path(sys.argv[1]))
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if result["findings"] else 0


if __name__ == "__main__":
    sys.exit(main())
