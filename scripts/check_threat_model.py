#!/usr/bin/env python3
"""Validate Phase 0/1 threat-model coverage."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DOC_PATH = ROOT / "docs" / "THREAT_MODEL.md"
FIXTURE_PATH = ROOT / "docs" / "fixtures" / "threat_model.json"
MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"
ISSUE_ID = "conveyor-safety-policy-sandbox-qsn.1"

EXPECTED_THREATS = {
    "malicious_repo_content",
    "malicious_tool_output",
    "policy_evasion",
    "test_weakening",
    "secret_exposure",
    "supply_chain_drift",
    "artifact_tampering",
    "reviewer_rubber_stamps",
    "gate_false_negatives",
    "internal_db_probing",
    "host_escape_and_overreach",
}

COVERAGE_TYPES = {"doctor_check", "test", "canary", "policy_fixture"}
REQUIRED_COVERAGE_FIELDS = {"type", "name", "station", "command", "artifact", "expected_result"}


def add_finding(
    findings: list[dict[str, str]],
    threat_id: str,
    code: str,
    message: str,
    file_name: str,
) -> None:
    findings.append(
        {
            "schema": "conveyor.threat_model_finding@1",
            "severity": "error",
            "category": "threat_model",
            "matrix_ref": MATRIX_REF,
            "issue_id": ISSUE_ID,
            "threat_id": threat_id,
            "file": file_name,
            "code": code,
            "message": message,
        }
    )


def load_fixture(findings: list[dict[str, str]]) -> dict[str, Any]:
    if not FIXTURE_PATH.exists():
        add_finding(findings, "fixture", "missing_file", "threat model fixture is missing", str(FIXTURE_PATH))
        return {}

    try:
        fixture_text = FIXTURE_PATH.read_text(encoding="utf-8")
        return json.JSONDecoder().decode(fixture_text)
    except json.JSONDecodeError as exc:
        add_finding(findings, "fixture", "invalid_json", f"fixture JSON is invalid: {exc}", str(FIXTURE_PATH))
        return {}


def has_heading(markdown: str, heading: str) -> bool:
    pattern = rf"^###\s+{re.escape(heading)}\s*$"
    return re.search(pattern, markdown, flags=re.MULTILINE) is not None


def section_has(markdown: str, heading: str, label: str) -> bool:
    pattern = rf"^###\s+{re.escape(heading)}\s*$([\s\S]*?)(?=^###\s+|\Z)"
    match = re.search(pattern, markdown, flags=re.MULTILINE)
    return bool(match and label in match.group(1))


def validate_doc(findings: list[dict[str, str]], threats: list[dict[str, Any]]) -> str:
    if not DOC_PATH.exists():
        add_finding(findings, "doc", "missing_file", "threat model document is missing", str(DOC_PATH))
        return ""

    markdown = DOC_PATH.read_text(encoding="utf-8")
    for phrase in (MATRIX_REF, ISSUE_ID, "Primary defense", "Residual risk", "Phase 1 coverage"):
        if phrase not in markdown:
            add_finding(findings, "doc", "missing_required_text", f"document is missing {phrase}", str(DOC_PATH))

    for threat in threats:
        threat_id = str(threat.get("id", "unknown"))
        title = str(threat.get("title", ""))
        if not has_heading(markdown, title):
            add_finding(findings, threat_id, "missing_doc_heading", f"missing threat heading {title}", str(DOC_PATH))
            continue
        for label in ("**Primary defense:**", "**Residual risk:**", "**Phase 1 coverage:**"):
            if not section_has(markdown, title, label):
                add_finding(findings, threat_id, "missing_doc_label", f"missing {label} in {title}", str(DOC_PATH))

    return markdown


def validate_fixture(findings: list[dict[str, str]], fixture: dict[str, Any]) -> list[dict[str, Any]]:
    if fixture.get("schema") != "conveyor.threat_model_fixture@1":
        add_finding(findings, "fixture", "invalid_schema", "fixture schema must be conveyor.threat_model_fixture@1", str(FIXTURE_PATH))
    if fixture.get("matrix_ref") != MATRIX_REF:
        add_finding(findings, "fixture", "invalid_matrix_ref", f"fixture matrix_ref must be {MATRIX_REF}", str(FIXTURE_PATH))
    if fixture.get("issue_id") != ISSUE_ID:
        add_finding(findings, "fixture", "invalid_issue_id", f"fixture issue_id must be {ISSUE_ID}", str(FIXTURE_PATH))

    threats = fixture.get("threat_classes")
    if not isinstance(threats, list):
        add_finding(findings, "fixture", "invalid_threat_classes", "threat_classes must be a list", str(FIXTURE_PATH))
        return []

    seen = {str(item.get("id", "")) for item in threats if isinstance(item, dict)}
    for missing in sorted(EXPECTED_THREATS - seen):
        add_finding(findings, missing, "missing_threat_class", f"missing expected threat class {missing}", str(FIXTURE_PATH))
    for extra in sorted(seen - EXPECTED_THREATS):
        add_finding(findings, extra, "unknown_threat_class", f"unknown threat class {extra}", str(FIXTURE_PATH))

    for threat in threats:
        if not isinstance(threat, dict):
            add_finding(findings, "fixture", "invalid_threat_record", "each threat class must be an object", str(FIXTURE_PATH))
            continue

        threat_id = str(threat.get("id", "unknown"))
        title = threat.get("title")
        defenses = threat.get("primary_defenses")
        risks = threat.get("residual_risks")
        coverage = threat.get("phase1_coverage")

        if not isinstance(title, str) or not title.strip():
            add_finding(findings, threat_id, "missing_title", "threat class title is required", str(FIXTURE_PATH))
        if not isinstance(defenses, list) or not defenses or not all(isinstance(item, str) and item.strip() for item in defenses):
            add_finding(findings, threat_id, "missing_primary_defense", "at least one primary defense is required", str(FIXTURE_PATH))
        if not isinstance(risks, list) or not risks or not all(isinstance(item, str) and item.strip() for item in risks):
            add_finding(findings, threat_id, "missing_residual_risk", "at least one residual risk is required", str(FIXTURE_PATH))
        if not isinstance(coverage, list) or not coverage:
            add_finding(findings, threat_id, "missing_phase1_coverage", "at least one Phase 1 coverage item is required", str(FIXTURE_PATH))
            continue

        for item in coverage:
            if not isinstance(item, dict):
                add_finding(findings, threat_id, "invalid_coverage_record", "coverage entries must be objects", str(FIXTURE_PATH))
                continue

            missing_fields = sorted(REQUIRED_COVERAGE_FIELDS - set(item))
            if missing_fields:
                add_finding(
                    findings,
                    threat_id,
                    "missing_coverage_field",
                    f"coverage entry is missing fields: {', '.join(missing_fields)}",
                    str(FIXTURE_PATH),
                )

            coverage_type = item.get("type")
            if coverage_type not in COVERAGE_TYPES:
                add_finding(
                    findings,
                    threat_id,
                    "invalid_coverage_type",
                    f"coverage type must be one of {sorted(COVERAGE_TYPES)}",
                    str(FIXTURE_PATH),
                )

            for field in REQUIRED_COVERAGE_FIELDS:
                value = item.get(field)
                if not isinstance(value, str) or not value.strip():
                    add_finding(findings, threat_id, "empty_coverage_field", f"coverage field {field} must be non-empty", str(FIXTURE_PATH))

    return threats


def coverage_report(threats: list[dict[str, Any]]) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for threat in threats:
        coverage = threat.get("phase1_coverage") if isinstance(threat, dict) else []
        coverage_items = coverage if isinstance(coverage, list) else []
        records.append(
            {
                "threat_id": threat.get("id"),
                "title": threat.get("title"),
                "primary_defense_count": len(threat.get("primary_defenses", [])),
                "residual_risk_count": len(threat.get("residual_risks", [])),
                "coverage_types": sorted({item.get("type") for item in coverage_items if isinstance(item, dict)}),
                "coverage_names": [item.get("name") for item in coverage_items if isinstance(item, dict)],
            }
        )
    return records


def main() -> int:
    findings: list[dict[str, str]] = []
    fixture = load_fixture(findings)
    threats = validate_fixture(findings, fixture) if fixture else []
    validate_doc(findings, threats)

    result = {
        "schema": "conveyor.threat_model_coverage@1",
        "status": "pass" if not findings else "fail",
        "matrix_ref": MATRIX_REF,
        "issue_id": ISSUE_ID,
        "checked_files": [str(DOC_PATH.relative_to(ROOT)), str(FIXTURE_PATH.relative_to(ROOT))],
        "required_threat_count": len(EXPECTED_THREATS),
        "covered_threat_count": len({item.get("id") for item in threats if isinstance(item, dict)} & EXPECTED_THREATS),
        "finding_count": len(findings),
        "coverage": coverage_report(threats),
        "findings": findings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
