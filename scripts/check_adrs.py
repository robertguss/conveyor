#!/usr/bin/env python3
"""Validate Phase 0/1 ADR coverage."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ADR_DIR = ROOT / "docs" / "adr"
MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"

REQUIRED_ADRS = {
    "0001-beam-ash-conductor-owns-truth.md": "BEAM/Ash conductor owns truth",
    "0002-evidence-is-product-artifact.md": "evidence is the product artifact",
    "0003-docker-is-not-security-boundary.md": "Docker is not the security boundary",
    "0004-testpack-contractlock-never-cut.md": "locked TestPack and ContractLock are never-cut primitives",
    "0005-gate-canaries-fail-closed.md": "gate canaries fail closed",
    "0006-phase1-l1-with-l2-shaped-artifacts.md": "Phase 1 is L1 with L2-shaped artifacts",
    "0007-merge-deploy-authority-deferred.md": "merge and deploy authority is deferred",
}

REQUIRED_SECTIONS = [
    "Status",
    "Context",
    "Decision",
    "Consequences",
    "Rejected Alternatives",
    "Dependent Beads",
    "Verification Matrix",
]


def heading_present(text: str, heading: str) -> bool:
    return re.search(rf"^##\s+{re.escape(heading)}\s*$", text, flags=re.MULTILINE) is not None


def finding(file_name: str, code: str, message: str, **extra: str) -> dict[str, str]:
    payload = {
        "schema": "conveyor.adr_contract_finding@1",
        "severity": "error",
        "category": "adr_contract",
        "file": file_name,
        "code": code,
        "message": message,
        "matrix_ref": MATRIX_REF,
    }
    payload.update(extra)
    return payload


def check_adr(file_name: str, expected_decision: str) -> list[dict[str, str]]:
    path = ADR_DIR / file_name
    findings: list[dict[str, str]] = []

    if not path.exists():
        return [finding(file_name, "missing_file", f"{file_name} is required for hsh.10 ADR coverage")]

    text = path.read_text(encoding="utf-8")

    for section in REQUIRED_SECTIONS:
        if not heading_present(text, section):
            findings.append(
                finding(file_name, "missing_section", f"{file_name} is missing section {section}", section=section)
            )

    if expected_decision.casefold() not in text.casefold():
        findings.append(
            finding(
                file_name,
                "missing_decision",
                f"{file_name} does not name required decision: {expected_decision}",
                decision=expected_decision,
            )
        )

    if MATRIX_REF not in text:
        findings.append(
            finding(file_name, "missing_matrix_ref", f"{file_name} does not reference {MATRIX_REF}")
        )

    if not re.search(r"^- `conveyor-[^`]+`", text, flags=re.MULTILINE):
        findings.append(
            finding(file_name, "missing_dependent_bead", f"{file_name} must list dependent beads")
        )

    return findings


def main() -> int:
    findings: list[dict[str, str]] = []

    if not ADR_DIR.exists():
        findings.append(finding(str(ADR_DIR.relative_to(ROOT)), "missing_directory", "docs/adr is required"))
    else:
        for file_name, expected_decision in REQUIRED_ADRS.items():
            findings.extend(check_adr(file_name, expected_decision))

    result = {
        "schema": "conveyor.adr_contract_check@1",
        "matrix_ref": MATRIX_REF,
        "status": "pass" if not findings else "fail",
        "checked_files": sorted(REQUIRED_ADRS),
        "finding_count": len(findings),
        "findings": findings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
