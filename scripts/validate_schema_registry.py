#!/usr/bin/env python3
"""Validate Conveyor's local Phase 0/1 schema registry."""

from __future__ import annotations

import copy
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import SchemaError


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_DIR = ROOT / "docs" / "schemas"
REGISTRY_PATH = SCHEMA_DIR / "registry.json"
VALID_DIR = SCHEMA_DIR / "examples" / "valid"
INVALID_DIR = SCHEMA_DIR / "examples" / "invalid"


@dataclass(frozen=True)
class RegistryEntry:
    artifact: str
    version: str
    schema_file: str
    valid_example: str
    invalid_example: str


VMR_REF = "conveyor-quality-ci-evals-vmr.13"
VMR_EVIDENCE_REF = "conveyor-quality-ci-evals-vmr.6"
JSON_DECODER = json.JSONDecoder()


def load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return JSON_DECODER.decode(handle.read())
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON in {path.relative_to(ROOT)}: {exc}") from exc


def load_registry() -> tuple[list[RegistryEntry], str]:
    registry = load_json(REGISTRY_PATH)
    vmr_ref = registry["vmr_ref"]
    entries = [RegistryEntry(**entry) for entry in registry["entries"]]
    return entries, vmr_ref


def finding(entry: RegistryEntry | None, check: str, status: str, **extra: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "report_schema": "conveyor.schema_validation_finding@1",
        "category": "schema_validation",
        "check": check,
        "status": status,
        "vmr_ref": VMR_REF,
        "shared_with": [
            VMR_EVIDENCE_REF,
            VMR_REF,
        ],
    }
    if entry is not None:
        body.update(
            {
                "artifact": entry.artifact,
                "schema_version": entry.version,
                "schema": str((SCHEMA_DIR / entry.schema_file).relative_to(ROOT)),
            }
        )
    body.update(extra)
    return body


def explicit_version_error(registry: list[RegistryEntry], schema_version: str) -> dict[str, str]:
    registered = {entry.version: entry for entry in registry}
    if schema_version in registered:
        return {}

    artifact_name = schema_version.split("@", 1)[0]
    known_artifacts = {entry.artifact for entry in registry}
    if artifact_name in known_artifacts:
        return {
            "code": "unsupported_schema_version",
            "message": f"unsupported version for registered artifact: {schema_version}",
        }
    return {
        "code": "unknown_schema_version",
        "message": f"no registered schema for artifact version: {schema_version}",
    }


def validate_payload(schema: dict[str, Any], payload: dict[str, Any]) -> list[str]:
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    return [error.message for error in sorted(validator.iter_errors(payload), key=lambda err: err.json_path)]


def main() -> int:
    findings: list[dict[str, Any]] = []

    try:
        registry, registry_vmr_ref = load_registry()
        registry_versions = [entry.version for entry in registry]
        registry_status = "pass" if registry_vmr_ref == VMR_REF else "fail"
        findings.append(
            finding(
                None,
                "registry_load",
                registry_status,
                registry=str(REGISTRY_PATH.relative_to(ROOT)),
                versions=registry_versions,
                expected_vmr_ref=VMR_REF,
                actual_vmr_ref=registry_vmr_ref,
            )
        )
    except (KeyError, TypeError, OSError, ValueError) as exc:
        findings.append(finding(None, "registry_load", "fail", registry=str(REGISTRY_PATH.relative_to(ROOT)), error=str(exc)))
        registry = []

    for entry in registry:
        schema_path = SCHEMA_DIR / entry.schema_file
        valid_path = VALID_DIR / entry.valid_example
        invalid_path = INVALID_DIR / entry.invalid_example

        try:
            schema = load_json(schema_path)
            Draft202012Validator.check_schema(schema)
            findings.append(finding(entry, "schema_load", "pass"))
            schema_version_required = "schema_version" in schema.get("required", [])
            findings.append(
                finding(
                    entry,
                    "schema_version_required",
                    "pass" if schema_version_required else "fail",
                    failure_category=None if schema_version_required else "missing_schema_version_requirement",
                )
            )
        except (OSError, ValueError, SchemaError) as exc:
            findings.append(finding(entry, "schema_load", "fail", error=str(exc)))
            continue

        for path, expected_status, check in (
            (valid_path, "pass", "valid_golden"),
            (invalid_path, "fail", "invalid_golden"),
        ):
            try:
                payload = load_json(path)
            except (OSError, ValueError) as exc:
                findings.append(finding(entry, check, "fail", example=str(path.relative_to(ROOT)), error=str(exc)))
                continue

            version_error = explicit_version_error(registry, payload.get("schema_version", ""))
            errors = [version_error["message"]] if version_error else validate_payload(schema, payload)
            failure_category = None
            if version_error:
                failure_category = version_error["code"]
            elif errors:
                failure_category = "schema_validation_failed"
            actual_status = "fail" if errors else "pass"
            status = "pass" if actual_status == expected_status else "fail"
            findings.append(
                finding(
                    entry,
                    check,
                    status,
                    example=str(path.relative_to(ROOT)),
                    expected=expected_status,
                    actual=actual_status,
                    failure_category=failure_category,
                    errors=errors,
                )
            )

        valid_payload = load_json(valid_path)
        unsupported_payload = copy.deepcopy(valid_payload)
        unsupported_payload["schema_version"] = f"{entry.artifact}@999"
        unsupported_error = explicit_version_error(registry, unsupported_payload["schema_version"])
        findings.append(
            finding(
                entry,
                "unsupported_version_rejection",
                "pass" if unsupported_error.get("code") == "unsupported_schema_version" else "fail",
                expected="unsupported_schema_version",
                actual=unsupported_error.get("code"),
                error=unsupported_error.get("message"),
            )
        )

    unknown_error = explicit_version_error(registry, "not_registered@1")
    findings.append(
        finding(
            None,
            "unknown_version_rejection",
            "pass" if unknown_error.get("code") == "unknown_schema_version" else "fail",
            expected="unknown_schema_version",
            actual=unknown_error.get("code"),
            error=unknown_error.get("message"),
        )
    )

    failed = [item for item in findings if item["status"] != "pass"]
    result = {
        "schema_registry": str(SCHEMA_DIR.relative_to(ROOT)),
        "report_schema": "conveyor.schema_validation_report@1",
        "vmr_ref": VMR_REF,
        "shared_with": [
            VMR_EVIDENCE_REF,
            VMR_REF,
        ],
        "checked_versions": [entry.version for entry in registry],
        "summary": {
            "passed": len(findings) - len(failed),
            "failed": len(failed),
            "total": len(findings),
        },
        "findings": findings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
