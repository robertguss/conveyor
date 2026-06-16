#!/usr/bin/env python3
"""Validate Phase 2-8 roadmap hooks seeded by Phase 0/1."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DOC_PATH = ROOT / "docs" / "roadmap" / "phase2_8_hooks.md"
HOOKS_PATH = ROOT / "docs" / "roadmap" / "phase2_8_hooks.json"
MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"
ISSUE_ID = "conveyor-observability-swarm-readiness-ohk.10"

EXPECTED_SYSTEMS = {
    "decomposition",
    "parallel_fleet_merge_queue",
    "verification_pyramid",
    "autonomy_self_healing",
    "economic_governor",
    "learning_loop",
    "throughput_upgrades",
}

REQUIRED_NON_IMPLEMENTATION_RULES = {
    "merge queue",
    "task claims",
    "memory",
    "economic governor",
    "workspace pool",
    "multi-repo orchestration",
    "autonomous retry",
}


def add_finding(
    findings: list[dict[str, str]],
    code: str,
    message: str,
    file_name: str,
    system_id: str = "",
) -> None:
    findings.append(
        {
            "schema": "conveyor.phase_hooks_finding@1",
            "severity": "error",
            "category": "phase_hooks",
            "matrix_ref": MATRIX_REF,
            "issue_id": ISSUE_ID,
            "system_id": system_id,
            "file": file_name,
            "code": code,
            "message": message,
        }
    )


def decode_hooks(findings: list[dict[str, str]]) -> dict[str, Any]:
    if not HOOKS_PATH.exists():
        add_finding(findings, "missing_file", "phase hooks JSON is missing", str(HOOKS_PATH))
        return {}
    try:
        return json.JSONDecoder().decode(HOOKS_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        add_finding(findings, "invalid_json", f"phase hooks JSON is invalid: {exc}", str(HOOKS_PATH))
        return {}


def validate_doc(findings: list[dict[str, str]], hooks: dict[str, Any]) -> None:
    if not DOC_PATH.exists():
        add_finding(findings, "missing_file", "phase hooks roadmap doc is missing", str(DOC_PATH))
        return

    content = DOC_PATH.read_text(encoding="utf-8")
    for phrase in (MATRIX_REF, ISSUE_ID, "Phase 1 Non-Implementation Rules", "Phase 0/1 seeded fields"):
        if phrase not in content:
            add_finding(findings, "missing_required_text", f"roadmap doc is missing {phrase}", str(DOC_PATH))

    for rule in REQUIRED_NON_IMPLEMENTATION_RULES:
        required_sentence = f"Do NOT implement {rule} in Phase 1."
        if required_sentence not in content:
            add_finding(findings, "missing_non_implementation_rule", f"missing sentence: {required_sentence}", str(DOC_PATH))

    systems = hooks.get("future_systems", [])
    if not isinstance(systems, list):
        return
    for system in systems:
        if not isinstance(system, dict):
            continue
        name = str(system.get("name", ""))
        system_id = str(system.get("id", ""))
        if f"### {name}" not in content:
            add_finding(findings, "missing_system_section", f"missing section for {name}", str(DOC_PATH), system_id)
        for field in system.get("seeded_fields", []):
            if isinstance(field, str) and field not in content:
                add_finding(findings, "missing_seeded_field_in_doc", f"doc does not name seeded field {field}", str(DOC_PATH), system_id)


def validate_hooks(findings: list[dict[str, str]], hooks: dict[str, Any]) -> list[dict[str, Any]]:
    if hooks.get("schema") != "conveyor.phase_hooks@1":
        add_finding(findings, "invalid_schema", "phase hooks schema must be conveyor.phase_hooks@1", str(HOOKS_PATH))
    if hooks.get("matrix_ref") != MATRIX_REF:
        add_finding(findings, "invalid_matrix_ref", f"matrix_ref must be {MATRIX_REF}", str(HOOKS_PATH))
    if hooks.get("issue_id") != ISSUE_ID:
        add_finding(findings, "invalid_issue_id", f"issue_id must be {ISSUE_ID}", str(HOOKS_PATH))

    rules = hooks.get("non_implementation_rules", [])
    if not isinstance(rules, list):
        add_finding(findings, "invalid_rules", "non_implementation_rules must be a list", str(HOOKS_PATH))
        rules = []
    rules_set = {str(rule) for rule in rules}
    for rule in sorted(REQUIRED_NON_IMPLEMENTATION_RULES - rules_set):
        add_finding(findings, "missing_rule", f"missing non-implementation rule {rule}", str(HOOKS_PATH))

    systems = hooks.get("future_systems", [])
    if not isinstance(systems, list):
        add_finding(findings, "invalid_systems", "future_systems must be a list", str(HOOKS_PATH))
        return []

    system_ids = {str(item.get("id", "")) for item in systems if isinstance(item, dict)}
    for system_id in sorted(EXPECTED_SYSTEMS - system_ids):
        add_finding(findings, "missing_system", f"missing future system {system_id}", str(HOOKS_PATH), system_id)
    for system_id in sorted(system_ids - EXPECTED_SYSTEMS):
        add_finding(findings, "unknown_system", f"unknown future system {system_id}", str(HOOKS_PATH), system_id)

    for system in systems:
        if not isinstance(system, dict):
            add_finding(findings, "invalid_system", "future system entries must be objects", str(HOOKS_PATH))
            continue
        system_id = str(system.get("id", ""))
        for field in ("id", "name", "future_phase", "later_hook", "phase1_boundary"):
            value = system.get(field)
            if not isinstance(value, str) or not value.strip():
                add_finding(findings, "missing_field", f"{system_id} is missing {field}", str(HOOKS_PATH), system_id)
        phase = str(system.get("future_phase", ""))
        if phase not in {"Phase 2", "Phase 3", "Phase 4", "Phase 5", "Phase 6", "Phase 7", "Phase 8"}:
            add_finding(findings, "invalid_future_phase", f"{system_id} future_phase must be Phase 2-8", str(HOOKS_PATH), system_id)
        seeded_fields = system.get("seeded_fields")
        if not isinstance(seeded_fields, list) or not seeded_fields:
            add_finding(findings, "missing_seeded_fields", f"{system_id} must list seeded fields", str(HOOKS_PATH), system_id)
        elif not all(isinstance(field, str) and field.strip() for field in seeded_fields):
            add_finding(findings, "invalid_seeded_field", f"{system_id} seeded fields must be non-empty strings", str(HOOKS_PATH), system_id)
        boundary = str(system.get("phase1_boundary", "")).lower()
        if "does not implement" not in boundary and "does not replace" not in boundary:
            add_finding(findings, "weak_phase1_boundary", f"{system_id} must explicitly constrain Phase 1 scope", str(HOOKS_PATH), system_id)

    return systems


def system_summary(systems: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "id": item.get("id"),
            "name": item.get("name"),
            "future_phase": item.get("future_phase"),
            "seeded_field_count": len(item.get("seeded_fields", [])),
        }
        for item in systems
        if isinstance(item, dict)
    ]


def main() -> int:
    findings: list[dict[str, str]] = []
    hooks = decode_hooks(findings)
    systems = validate_hooks(findings, hooks) if hooks else []
    validate_doc(findings, hooks)

    result = {
        "schema": "conveyor.phase_hooks_check@1",
        "status": "pass" if not findings else "fail",
        "matrix_ref": MATRIX_REF,
        "issue_id": ISSUE_ID,
        "checked_files": [str(DOC_PATH.relative_to(ROOT)), str(HOOKS_PATH.relative_to(ROOT))],
        "required_system_count": len(EXPECTED_SYSTEMS),
        "covered_system_count": len({item.get("id") for item in systems if isinstance(item, dict)} & EXPECTED_SYSTEMS),
        "required_non_implementation_rules": sorted(REQUIRED_NON_IMPLEMENTATION_RULES),
        "finding_count": len(findings),
        "future_systems": system_summary(systems),
        "findings": findings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
