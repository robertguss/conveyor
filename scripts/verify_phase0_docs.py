#!/usr/bin/env python3
"""Validate the Phase 0/1 Conveyor contract documentation."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VMR_REF = "conveyor-quality-ci-evals-vmr.13"

REQUIRED_DOCS = {
    "VISION.md": [
        "Shared Contract",
        "Purpose",
        "Product Contract",
        "Non-Goals",
        "Phase 0 Cutline",
        "Phase 1 Cutline",
        "Evidence Requirements",
        "Trust Boundaries",
        "Explicit Deferrals",
        "Factory-Kernel Primitives",
        "Done Criteria",
    ],
    "AUTONOMY_LEVELS.md": [
        "Shared Contract",
        "Autonomy Contract",
        "L0 Observe",
        "L1 Assisted Implementation",
        "L2 Supervised Repository Automation",
        "L3 Governed Integration",
        "L4 Production Operations",
        "Phase 1 Target",
        "Capability Mapping",
        "Escalation Rules",
        "Factory-Kernel Primitives",
        "Verification Matrix Mapping",
    ],
    "SAFETY_POLICY.md": [
        "Shared Contract",
        "Safety Contract",
        "Trust Boundaries",
        "Command Policy",
        "Sandbox Policy",
        "Credential Policy",
        "Evidence Policy",
        "Human Control",
        "Threat Classes",
        "Explicit Deferrals",
        "Factory-Kernel Primitives",
        "Verification Matrix Mapping",
    ],
    "TASK_SCHEMA.md": [
        "Shared Contract",
        "Schema Contract",
        "Versioning",
        "Plan Fields",
        "Requirement Fields",
        "Slice Fields",
        "AgentBrief Fields",
        "RunSpec Fields",
        "StationPlan Fields",
        "Human Decisions",
        "Readiness",
        "Factory-Kernel Primitives",
        "Verification Matrix Mapping",
    ],
    "EVIDENCE_SCHEMA.md": [
        "Shared Contract",
        "Evidence Contract",
        "Versioning",
        "Machine Evidence",
        "Acceptance Mapping",
        "Command Evidence",
        "Artifact Integrity",
        "Redaction and Quarantine",
        "Review Evidence",
        "Gate Evidence",
        "Human Dossier",
        "Replay",
        "Factory-Kernel Primitives",
        "Verification Matrix Mapping",
    ],
    "ARCHITECTURE.md": [
        "Shared Contract",
        "Architecture Contract",
        "System Shape",
        "Phase 1 Linear StationPlan",
        "Data Model",
        "State and Idempotency",
        "Ledger and Outbox",
        "Agent Runtime",
        "Policy and Sandbox",
        "Evidence and Artifacts",
        "Gate and Review",
        "Trust Boundaries",
        "Explicit Deferrals",
        "Factory-Kernel Primitives",
        "Verification Matrix Mapping",
    ],
}

REQUIRED_PHRASES = [
    "Conveyor is a deterministic conductor plus stochastic agents.",
    "Phase 1 target autonomy level is L1.",
    "Phase 1 produces PR-quality evidence but does not auto-merge or deploy.",
    "The factory-kernel primitives must not be cut.",
    VMR_REF,
]


def markdown_sections(text: str) -> set[str]:
    sections: set[str] = set()
    for line in text.splitlines():
        match = re.match(r"^#{1,6}\s+(.+?)\s*$", line)
        if match:
            sections.add(match.group(1).strip())
    return sections


def finding(file_name: str, code: str, message: str, **extra: str) -> dict[str, str]:
    item = {
        "severity": "error",
        "file": file_name,
        "code": code,
        "message": message,
        "vmr": VMR_REF,
    }
    item.update(extra)
    return item


def validate_doc(file_name: str, required_sections: list[str]) -> list[dict[str, str]]:
    path = ROOT / file_name
    findings: list[dict[str, str]] = []

    if not path.exists():
        return [
            finding(
                file_name,
                "missing_doc",
                f"{file_name} is required by conveyor-phase0-foundations-hsh.1",
            )
        ]

    text = path.read_text(encoding="utf-8")
    sections = markdown_sections(text)

    for section in required_sections:
        if section not in sections:
            findings.append(
                finding(
                    file_name,
                    "missing_section",
                    f"Required section is missing: {section}",
                    section=section,
                )
            )

    for phrase in REQUIRED_PHRASES:
        if phrase not in text:
            findings.append(
                finding(
                    file_name,
                    "missing_required_phrase",
                    f"Required contract statement is missing: {phrase}",
                    phrase=phrase,
                )
            )

    if "auto-merge" not in text or "deploy" not in text:
        findings.append(
            finding(
                file_name,
                "missing_no_auto_merge_or_deploy",
                "Document must retain the no-auto-merge and no-deploy statement.",
            )
        )

    if "L1" not in text:
        findings.append(
            finding(
                file_name,
                "missing_l1_target",
                "Document must retain the Phase 1 L1 target statement.",
            )
        )

    return findings


def main() -> int:
    findings: list[dict[str, str]] = []
    for file_name, required_sections in REQUIRED_DOCS.items():
        findings.extend(validate_doc(file_name, required_sections))

    payload = {
        "schema_version": "conveyor.phase0_docs_check@1",
        "vmr": VMR_REF,
        "checked_files": sorted(REQUIRED_DOCS),
        "finding_count": len(findings),
        "findings": findings,
        "status": "fail" if findings else "pass",
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
