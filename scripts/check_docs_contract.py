#!/usr/bin/env python3
"""Validate Conveyor Phase 0/1 contract documentation."""

from __future__ import annotations

import json
import sys
from pathlib import Path


MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"

REQUIRED_DOCS = {
    "VISION.md": [
        "Purpose",
        "Product Contract",
        "Non-Goals",
        "Phase 0 and Phase 1 Cutline",
        "Factory-Kernel Primitives",
        "Evidence Requirements",
        "Trust Boundaries",
        "Explicit Deferrals",
        "Verification Mapping",
    ],
    "AUTONOMY_LEVELS.md": [
        "Purpose",
        "Level Summary",
        "L0 Observe",
        "L1 Supervised Patch",
        "L2 Through L4 Deferrals",
        "Permission Rules",
        "Evidence Requirements",
        "Verification Mapping",
    ],
    "SAFETY_POLICY.md": [
        "Purpose",
        "Safety Contract",
        "Trust Boundaries",
        "Sandbox Policy",
        "Network and Credential Policy",
        "Gate Behavior",
        "Factory-Kernel Primitives",
        "Failure Handling",
        "Explicit Deferrals",
        "Verification Mapping",
    ],
    "TASK_SCHEMA.md": [
        "Purpose",
        "Schema Identity",
        "Required Fields",
        "Validation Rules",
        "Task Lifecycle",
        "Factory-Kernel Primitives",
        "Structured Findings",
        "Explicit Deferrals",
        "Verification Mapping",
    ],
    "EVIDENCE_SCHEMA.md": [
        "Purpose",
        "Schema Identity",
        "Required Fields",
        "Station Evidence",
        "Review and Gate Evidence",
        "Factory-Kernel Primitives",
        "Structured Findings",
        "Explicit Deferrals",
        "Verification Mapping",
    ],
    "ARCHITECTURE.md": [
        "Purpose",
        "System Shape",
        "Control Plane Components",
        "Station Flow",
        "Factory-Kernel Primitives",
        "Trust Boundaries",
        "Data and Artifact Boundaries",
        "Explicit Deferrals",
        "Verification Mapping",
    ],
}

INVARIANT_PHRASES = {
    "phase1_no_auto_merge": "Phase 1 produces PR-quality evidence but does not auto-merge or deploy",
    "l1_target": "Phase 1 L1 target",
    "conductor_agents": "deterministic conductor plus stochastic agents",
    "factory_kernel": "factory-kernel primitives that must not be cut",
    "matrix_ref": MATRIX_REF,
}


def heading_present(text: str, heading: str) -> bool:
    markers = (f"## {heading}", f"### {heading}")
    return any(marker in text for marker in markers)


def finding(file_name: str, code: str, message: str, **extra: str) -> dict[str, str]:
    payload = {
        "schema": "conveyor.docs_contract_finding@1",
        "severity": "error",
        "category": "docs_contract",
        "file": file_name,
        "code": code,
        "message": message,
        "matrix_ref": MATRIX_REF,
    }
    payload.update(extra)
    return payload


def check_doc(root: Path, file_name: str, sections: list[str]) -> list[dict[str, str]]:
    path = root / file_name
    findings: list[dict[str, str]] = []

    if not path.exists():
        return [
            finding(
                file_name,
                "missing_file",
                f"{file_name} is required by the Phase 0/1 docs contract",
            )
        ]

    text = path.read_text(encoding="utf-8")

    for section in sections:
        if not heading_present(text, section):
            findings.append(
                finding(
                    file_name,
                    "missing_section",
                    f"{file_name} is missing required section {section}",
                    section=section,
                )
            )

    for key, phrase in INVARIANT_PHRASES.items():
        if phrase not in text:
            findings.append(
                finding(
                    file_name,
                    "missing_invariant",
                    f"{file_name} is missing invariant phrase {key}",
                    invariant=key,
                )
            )

    return findings


def main() -> int:
    root = Path.cwd()
    findings: list[dict[str, str]] = []

    for file_name, sections in REQUIRED_DOCS.items():
        findings.extend(check_doc(root, file_name, sections))

    result = {
        "schema": "conveyor.docs_contract_check@1",
        "matrix_ref": MATRIX_REF,
        "status": "pass" if not findings else "fail",
        "checked_files": sorted(REQUIRED_DOCS),
        "finding_count": len(findings),
        "findings": findings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
