#!/usr/bin/env python3
"""Validate deferred resource sketches and absence of active migrations."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DOC_PATH = ROOT / "docs" / "future-schemas" / "README.md"
REGISTRY_PATH = ROOT / "docs" / "future-schemas" / "deferred_resources.json"
MIGRATIONS_DIR = ROOT / "priv" / "repo" / "migrations"
MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"
ISSUE_ID = "conveyor-phase0-foundations-hsh.8"

EXPECTED_RESOURCES = {
    "WorkspacePool",
    "TaskClaim",
    "MergeQueueItem",
    "BudgetLedger",
    "AgentReputation",
    "Memory",
    "ExternalTaskRef",
}


def add_finding(
    findings: list[dict[str, str]],
    code: str,
    message: str,
    file_name: str,
    resource: str = "",
) -> None:
    findings.append(
        {
            "schema": "conveyor.deferred_resource_finding@1",
            "severity": "error",
            "category": "deferred_resource",
            "matrix_ref": MATRIX_REF,
            "issue_id": ISSUE_ID,
            "resource": resource,
            "file": file_name,
            "code": code,
            "message": message,
        }
    )


def decode_registry(findings: list[dict[str, str]]) -> dict[str, Any]:
    if not REGISTRY_PATH.exists():
        add_finding(findings, "missing_file", "deferred resource registry is missing", str(REGISTRY_PATH))
        return {}
    try:
        return json.JSONDecoder().decode(REGISTRY_PATH.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        add_finding(findings, "invalid_json", f"deferred resource registry is invalid JSON: {exc}", str(REGISTRY_PATH))
        return {}


def migration_texts() -> dict[str, str]:
    if not MIGRATIONS_DIR.exists():
        return {}
    migrations: dict[str, str] = {}
    for path in sorted(MIGRATIONS_DIR.glob("*.exs")):
        migrations[str(path.relative_to(ROOT))] = path.read_text(encoding="utf-8")
    return migrations


def validate_doc(findings: list[dict[str, str]], resources: list[dict[str, Any]]) -> None:
    if not DOC_PATH.exists():
        add_finding(findings, "missing_file", "future schema README is missing", str(DOC_PATH))
        return

    content = DOC_PATH.read_text(encoding="utf-8")
    for phrase in (MATRIX_REF, ISSUE_ID, "Active migration", "Phase 0/1 seed fields"):
        if phrase not in content:
            add_finding(findings, "missing_required_text", f"README is missing {phrase}", str(DOC_PATH))

    for resource in resources:
        name = str(resource.get("name", ""))
        if f"### {name}" not in content:
            add_finding(findings, "missing_resource_section", f"README is missing section for {name}", str(DOC_PATH), name)
            continue
        for label in (
            "**Activation phase:**",
            "**Deferral reason:**",
            "**Phase 0/1 seed fields:**",
            "**Expected invariants:**",
            "**Expected event types:**",
            "**Active migration:** none in Phase 0/1.",
        ):
            if label not in content:
                add_finding(findings, "missing_doc_label", f"README is missing label {label}", str(DOC_PATH), name)


def validate_registry(findings: list[dict[str, str]], registry: dict[str, Any]) -> list[dict[str, Any]]:
    if registry.get("schema") != "conveyor.deferred_resources@1":
        add_finding(findings, "invalid_schema", "registry schema must be conveyor.deferred_resources@1", str(REGISTRY_PATH))
    if registry.get("matrix_ref") != MATRIX_REF:
        add_finding(findings, "invalid_matrix_ref", f"registry matrix_ref must be {MATRIX_REF}", str(REGISTRY_PATH))
    if registry.get("issue_id") != ISSUE_ID:
        add_finding(findings, "invalid_issue_id", f"registry issue_id must be {ISSUE_ID}", str(REGISTRY_PATH))

    resources = registry.get("resources", [])
    if not isinstance(resources, list):
        add_finding(findings, "invalid_resources", "resources must be a list", str(REGISTRY_PATH))
        return []

    names = {str(item.get("name", "")) for item in resources if isinstance(item, dict)}
    for name in sorted(EXPECTED_RESOURCES - names):
        add_finding(findings, "missing_resource", f"missing deferred resource {name}", str(REGISTRY_PATH), name)
    for name in sorted(names - EXPECTED_RESOURCES):
        add_finding(findings, "unknown_resource", f"unknown deferred resource {name}", str(REGISTRY_PATH), name)

    for resource in resources:
        if not isinstance(resource, dict):
            add_finding(findings, "invalid_resource", "each resource must be an object", str(REGISTRY_PATH))
            continue
        name = str(resource.get("name", ""))
        required_strings = ("id", "name", "table_name", "activation_phase", "deferral_reason")
        for field in required_strings:
            value = resource.get(field)
            if not isinstance(value, str) or not value.strip():
                add_finding(findings, "missing_field", f"{name} is missing {field}", str(REGISTRY_PATH), name)
        for field in ("phase0_1_seed_fields", "expected_invariants", "event_types"):
            value = resource.get(field)
            if not isinstance(value, list) or not value or not all(isinstance(item, str) and item.strip() for item in value):
                add_finding(findings, "missing_list_field", f"{name} must have non-empty {field}", str(REGISTRY_PATH), name)
        if resource.get("active_migration") is not False:
            add_finding(findings, "active_migration_flag", f"{name} must have active_migration=false", str(REGISTRY_PATH), name)
        activation_phase = str(resource.get("activation_phase", ""))
        if activation_phase not in {"Phase 2", "Phase 3", "Phase 4", "Phase 5", "Phase 6", "Phase 7", "Phase 8"}:
            add_finding(findings, "invalid_activation_phase", f"{name} activation phase must be Phase 2 or later", str(REGISTRY_PATH), name)

    return resources


def validate_no_active_migrations(findings: list[dict[str, str]], resources: list[dict[str, Any]]) -> None:
    migrations = migration_texts()
    for resource in resources:
        name = str(resource.get("name", ""))
        table_name = str(resource.get("table_name", ""))
        resource_id = str(resource.get("id", ""))
        tokens = {token for token in (table_name, resource_id, name) if token}
        for file_name, content in migrations.items():
            lowered = content.lower()
            for token in tokens:
                if token.lower() in lowered:
                    add_finding(
                        findings,
                        "deferred_resource_migration",
                        f"{name} appears in active migration {file_name}",
                        file_name,
                        name,
                    )


def resource_summary(resources: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        {
            "name": item.get("name"),
            "activation_phase": item.get("activation_phase"),
            "seed_field_count": len(item.get("phase0_1_seed_fields", [])),
            "invariant_count": len(item.get("expected_invariants", [])),
            "event_type_count": len(item.get("event_types", [])),
            "active_migration": item.get("active_migration"),
        }
        for item in resources
        if isinstance(item, dict)
    ]


def main() -> int:
    findings: list[dict[str, str]] = []
    registry = decode_registry(findings)
    resources = validate_registry(findings, registry) if registry else []
    validate_doc(findings, resources)
    validate_no_active_migrations(findings, resources)

    result = {
        "schema": "conveyor.deferred_resource_check@1",
        "status": "pass" if not findings else "fail",
        "matrix_ref": MATRIX_REF,
        "issue_id": ISSUE_ID,
        "checked_files": [str(DOC_PATH.relative_to(ROOT)), str(REGISTRY_PATH.relative_to(ROOT))],
        "migration_dir": str(MIGRATIONS_DIR.relative_to(ROOT)),
        "required_resource_count": len(EXPECTED_RESOURCES),
        "covered_resource_count": len({item.get("name") for item in resources if isinstance(item, dict)} & EXPECTED_RESOURCES),
        "finding_count": len(findings),
        "resources": resource_summary(resources),
        "findings": findings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
