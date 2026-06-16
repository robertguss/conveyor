#!/usr/bin/env python3
"""Validate Conveyor policy profiles and denylist fixtures."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
PROFILES_PATH = ROOT / "docs" / "policy" / "profiles.json"
FIXTURES_PATH = ROOT / "docs" / "fixtures" / "policy" / "denylist_cases.json"
MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"
ISSUE_ID = "conveyor-safety-policy-sandbox-qsn.3"

EXPECTED_PROFILES = {"explore", "implement", "verify", "release", "maintenance"}
EXPECTED_DENYLIST_CLASSES = {
    "destructive_fs",
    "dangerous_git",
    "force_push",
    "chmod_chown_outside_workspace",
    "pipe_to_shell_installer",
    "sudo",
    "credential_access",
    "prod_db_url",
    "unapproved_package_install",
    "unapproved_network",
    "deploy_publish_l0_l2",
}
INCIDENT_SEVERITIES = {"high", "critical"}


def add_finding(
    findings: list[dict[str, str]],
    code: str,
    message: str,
    file_name: str,
    case_id: str = "",
) -> None:
    findings.append(
        {
            "schema": "conveyor.policy_profile_finding@1",
            "severity": "error",
            "category": "policy_profile",
            "matrix_ref": MATRIX_REF,
            "issue_id": ISSUE_ID,
            "case_id": case_id,
            "file": file_name,
            "code": code,
            "message": message,
        }
    )


def decode_json(path: Path, findings: list[dict[str, str]]) -> dict[str, Any]:
    if not path.exists():
        add_finding(findings, "missing_file", f"{path.relative_to(ROOT)} is missing", str(path))
        return {}
    try:
        return json.JSONDecoder().decode(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        add_finding(findings, "invalid_json", f"{path.relative_to(ROOT)} is invalid JSON: {exc}", str(path))
        return {}


def command_text(command: dict[str, Any]) -> str:
    argv = command.get("argv", [])
    env = command.get("env", {})
    network = command.get("network", "")
    argv_text = " ".join(str(part) for part in argv) if isinstance(argv, list) else str(argv)
    env_text = " ".join(f"{key}={value}" for key, value in sorted(env.items())) if isinstance(env, dict) else str(env)
    return f"{env_text} {argv_text} {network}".strip().lower()


def validate_profiles(profiles_doc: dict[str, Any], findings: list[dict[str, str]]) -> None:
    if profiles_doc.get("schema") != "conveyor.policy_profiles@1":
        add_finding(findings, "invalid_schema", "profiles schema must be conveyor.policy_profiles@1", str(PROFILES_PATH))
    if profiles_doc.get("matrix_ref") != MATRIX_REF:
        add_finding(findings, "invalid_matrix_ref", f"profiles matrix_ref must be {MATRIX_REF}", str(PROFILES_PATH))
    if profiles_doc.get("issue_id") != ISSUE_ID:
        add_finding(findings, "invalid_issue_id", f"profiles issue_id must be {ISSUE_ID}", str(PROFILES_PATH))

    denylist = profiles_doc.get("denylist_classes", {})
    if not isinstance(denylist, dict):
        add_finding(findings, "invalid_denylist", "denylist_classes must be an object", str(PROFILES_PATH))
        denylist = {}

    denylist_names = set(denylist)
    for class_name in sorted(EXPECTED_DENYLIST_CLASSES - denylist_names):
        add_finding(findings, "missing_denylist_class", f"missing denylist class {class_name}", str(PROFILES_PATH))
    for class_name in sorted(denylist_names - EXPECTED_DENYLIST_CLASSES):
        add_finding(findings, "unknown_denylist_class", f"unknown denylist class {class_name}", str(PROFILES_PATH))

    for class_name, spec in denylist.items():
        if not isinstance(spec, dict):
            add_finding(findings, "invalid_denylist_class", f"{class_name} must be an object", str(PROFILES_PATH))
            continue
        if spec.get("severity") not in {"low", "medium", "high", "critical"}:
            add_finding(findings, "invalid_severity", f"{class_name} has invalid severity", str(PROFILES_PATH))
        if not isinstance(spec.get("incident_required"), bool):
            add_finding(findings, "invalid_incident_flag", f"{class_name} incident_required must be boolean", str(PROFILES_PATH))
        patterns = spec.get("blocked_patterns")
        if not isinstance(patterns, list) or not patterns:
            add_finding(findings, "missing_blocked_patterns", f"{class_name} must name blocked patterns", str(PROFILES_PATH))

    profiles = profiles_doc.get("profiles", {})
    if not isinstance(profiles, dict):
        add_finding(findings, "invalid_profiles", "profiles must be an object", str(PROFILES_PATH))
        return

    profile_names = set(profiles)
    for profile_name in sorted(EXPECTED_PROFILES - profile_names):
        add_finding(findings, "missing_profile", f"missing policy profile {profile_name}", str(PROFILES_PATH))
    for profile_name in sorted(profile_names - EXPECTED_PROFILES):
        add_finding(findings, "unknown_profile", f"unknown policy profile {profile_name}", str(PROFILES_PATH))

    for profile_name, profile in profiles.items():
        if not isinstance(profile, dict):
            add_finding(findings, "invalid_profile", f"profile {profile_name} must be an object", str(PROFILES_PATH))
            continue
        if profile.get("autonomy_ceiling") not in {"L0", "L1", "L2"}:
            add_finding(findings, "invalid_autonomy_ceiling", f"profile {profile_name} must stay within L0-L2", str(PROFILES_PATH))
        if profile.get("network_policy") != "deny_by_default":
            add_finding(findings, "invalid_network_policy", f"profile {profile_name} must deny network by default", str(PROFILES_PATH))
        denied_classes = profile.get("denied_classes")
        if not isinstance(denied_classes, list):
            add_finding(findings, "invalid_denied_classes", f"profile {profile_name} denied_classes must be a list", str(PROFILES_PATH))
            continue
        missing = EXPECTED_DENYLIST_CLASSES - set(denied_classes)
        for class_name in sorted(missing):
            add_finding(findings, "profile_missing_denylist", f"profile {profile_name} does not deny {class_name}", str(PROFILES_PATH))


def evaluate_case(case: dict[str, Any], profiles_doc: dict[str, Any]) -> dict[str, Any]:
    denylist = profiles_doc.get("denylist_classes", {})
    profiles = profiles_doc.get("profiles", {})
    profile = profiles.get(case.get("profile"), {})
    denylist_class = str(case.get("denylist_class", ""))
    class_spec = denylist.get(denylist_class, {})
    denied_classes = set(profile.get("denied_classes", [])) if isinstance(profile, dict) else set()
    blocked = denylist_class in denied_classes
    text = command_text(case.get("command", {}))
    patterns = class_spec.get("blocked_patterns", []) if isinstance(class_spec, dict) else []
    matched_patterns = [pattern for pattern in patterns if str(pattern).lower() in text]
    decision = "block" if blocked and matched_patterns else "allow"
    severity = str(class_spec.get("severity", "medium")) if isinstance(class_spec, dict) else "medium"
    incident_required = bool(class_spec.get("incident_required")) if isinstance(class_spec, dict) else False
    incident = decision == "block" and (incident_required or severity in INCIDENT_SEVERITIES)
    reasons = [
        f"profile={case.get('profile')}",
        f"denylist_class={denylist_class}",
        f"matched_patterns={','.join(matched_patterns)}",
    ]
    return {
        "schema": "conveyor.policy_decision@1",
        "case_id": case.get("id"),
        "profile": case.get("profile"),
        "autonomy_level": case.get("autonomy_level"),
        "denylist_class": denylist_class,
        "decision": decision,
        "severity": severity,
        "incident_required": incident,
        "matched_patterns": matched_patterns,
        "reasons": reasons,
        "incident": {
            "schema": "conveyor.policy_incident@1",
            "case_id": case.get("id"),
            "severity": severity,
            "category": "policy_violation",
            "message": f"Blocked {denylist_class} for {case.get('profile')} profile",
            "next_action": "Require human-approved policy change or safer command fixture.",
        }
        if incident
        else None,
    }


def validate_fixtures(
    fixtures_doc: dict[str, Any],
    profiles_doc: dict[str, Any],
    findings: list[dict[str, str]],
) -> list[dict[str, Any]]:
    if fixtures_doc.get("schema") != "conveyor.policy_fixture_suite@1":
        add_finding(findings, "invalid_schema", "fixture schema must be conveyor.policy_fixture_suite@1", str(FIXTURES_PATH))
    if fixtures_doc.get("matrix_ref") != MATRIX_REF:
        add_finding(findings, "invalid_matrix_ref", f"fixture matrix_ref must be {MATRIX_REF}", str(FIXTURES_PATH))
    if fixtures_doc.get("issue_id") != ISSUE_ID:
        add_finding(findings, "invalid_issue_id", f"fixture issue_id must be {ISSUE_ID}", str(FIXTURES_PATH))

    cases = fixtures_doc.get("cases", [])
    if not isinstance(cases, list):
        add_finding(findings, "invalid_cases", "cases must be a list", str(FIXTURES_PATH))
        return []

    covered_classes = {str(case.get("denylist_class", "")) for case in cases if isinstance(case, dict)}
    for class_name in sorted(EXPECTED_DENYLIST_CLASSES - covered_classes):
        add_finding(findings, "missing_fixture_class", f"missing fixture for {class_name}", str(FIXTURES_PATH))

    decisions: list[dict[str, Any]] = []
    for case in cases:
        if not isinstance(case, dict):
            add_finding(findings, "invalid_case", "each fixture case must be an object", str(FIXTURES_PATH))
            continue

        case_id = str(case.get("id", ""))
        for field in ("id", "denylist_class", "profile", "autonomy_level", "command", "expected_decision", "expected_incident"):
            if field not in case:
                add_finding(findings, "missing_case_field", f"case is missing {field}", str(FIXTURES_PATH), case_id)

        decision = evaluate_case(case, profiles_doc)
        decisions.append(decision)

        if decision["decision"] != case.get("expected_decision"):
            add_finding(
                findings,
                "unexpected_decision",
                f"expected {case.get('expected_decision')} but got {decision['decision']}",
                str(FIXTURES_PATH),
                case_id,
            )
        if bool(decision["incident_required"]) != bool(case.get("expected_incident")):
            add_finding(
                findings,
                "unexpected_incident",
                f"expected incident={case.get('expected_incident')} but got {decision['incident_required']}",
                str(FIXTURES_PATH),
                case_id,
            )
        if case.get("expected_decision") == "block" and not decision["matched_patterns"]:
            add_finding(findings, "missing_pattern_match", "blocked case did not match a denylist pattern", str(FIXTURES_PATH), case_id)

    return decisions


def main() -> int:
    findings: list[dict[str, str]] = []
    profiles_doc = decode_json(PROFILES_PATH, findings)
    fixtures_doc = decode_json(FIXTURES_PATH, findings)

    if profiles_doc:
        validate_profiles(profiles_doc, findings)
    decisions = validate_fixtures(fixtures_doc, profiles_doc, findings) if profiles_doc and fixtures_doc else []

    result = {
        "schema": "conveyor.policy_profile_check@1",
        "status": "pass" if not findings else "fail",
        "matrix_ref": MATRIX_REF,
        "issue_id": ISSUE_ID,
        "checked_files": [str(PROFILES_PATH.relative_to(ROOT)), str(FIXTURES_PATH.relative_to(ROOT))],
        "required_denylist_count": len(EXPECTED_DENYLIST_CLASSES),
        "covered_denylist_count": len({decision["denylist_class"] for decision in decisions} & EXPECTED_DENYLIST_CLASSES),
        "decision_count": len(decisions),
        "incident_count": sum(1 for decision in decisions if decision["incident_required"]),
        "finding_count": len(findings),
        "policy_decisions": decisions,
        "findings": findings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
