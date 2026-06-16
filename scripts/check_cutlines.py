#!/usr/bin/env python3
"""Audit Phase 0/1 cutline labels and policy text."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
ISSUES_PATH = ROOT / ".beads" / "issues.jsonl"
DOC_PATH = ROOT / "docs" / "CUTLINES.md"
MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"

ALLOWED_CUTLINES = {
    "cutline:tracer-required": "TRACER_REQUIRED",
    "cutline:trust-required": "TRUST_REQUIRED",
    "cutline:instrument-only": "INSTRUMENT_ONLY",
    "cutline:defer": "DEFER",
}

JSON_DECODER = json.JSONDecoder()

DOC_REQUIRED_TERMS = [
    "Never-Cut Items",
    "Cut-First Items",
    "Task envelope",
    "RunSpec",
    "station plan",
    "Evidence records",
    "Gate canaries",
    "no auto-merge",
    "no auto-deploy",
    "cutline:tracer-required",
    "cutline:trust-required",
    "cutline:instrument-only",
    "cutline:defer",
    MATRIX_REF,
]


def finding(code: str, message: str, **extra: Any) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "schema": "conveyor.cutline_finding@1",
        "severity": "error",
        "category": "cutline_audit",
        "code": code,
        "message": message,
        "matrix_ref": MATRIX_REF,
    }
    payload.update(extra)
    return payload


def load_issues() -> list[dict[str, Any]]:
    issues: list[dict[str, Any]] = []
    with ISSUES_PATH.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            try:
                issue = JSON_DECODER.decode(line)
            except json.JSONDecodeError as exc:
                raise ValueError(f"{ISSUES_PATH}:{line_number}: invalid JSON: {exc}") from exc
            issues.append(issue)
    return issues


def is_phase_0_or_1(issue: dict[str, Any]) -> bool:
    labels = set(issue.get("labels") or [])
    if "phase:0" in labels or "phase:1" in labels:
        return True

    text = " ".join(
        str(issue.get(field) or "")
        for field in ("id", "title", "description", "acceptance_criteria")
    ).casefold()
    return "phase 0" in text or "phase-0" in text or "phase 1" in text or "phase-1" in text


def check_doc() -> list[dict[str, Any]]:
    if not DOC_PATH.exists():
        return [finding("missing_cutline_doc", "docs/CUTLINES.md is required", file=str(DOC_PATH.relative_to(ROOT)))]

    text = DOC_PATH.read_text(encoding="utf-8")
    findings: list[dict[str, Any]] = []
    for term in DOC_REQUIRED_TERMS:
        if term not in text:
            findings.append(
                finding(
                    "missing_policy_term",
                    f"docs/CUTLINES.md is missing required term: {term}",
                    file=str(DOC_PATH.relative_to(ROOT)),
                    term=term,
                )
            )
    return findings


def check_issues(issues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    findings: list[dict[str, Any]] = []

    for issue in issues:
        if not is_phase_0_or_1(issue):
            continue

        issue_id = str(issue.get("id") or "<missing-id>")
        labels = set(issue.get("labels") or [])
        cutlines = sorted(label for label in labels if label.startswith("cutline:"))

        if not cutlines:
            findings.append(finding("missing_cutline_label", f"{issue_id} has no cutline label", issue_id=issue_id))
            continue

        if len(cutlines) > 1:
            findings.append(
                finding(
                    "multiple_cutline_labels",
                    f"{issue_id} has multiple cutline labels",
                    issue_id=issue_id,
                    cutlines=cutlines,
                )
            )

        for cutline in cutlines:
            if cutline not in ALLOWED_CUTLINES:
                findings.append(
                    finding(
                        "unknown_cutline_label",
                        f"{issue_id} uses unknown cutline label {cutline}",
                        issue_id=issue_id,
                        cutline=cutline,
                    )
                )

    return findings


def main() -> int:
    findings = check_doc()

    try:
        issues = load_issues()
    except (OSError, ValueError) as exc:
        findings.append(finding("issue_load_failed", str(exc), file=str(ISSUES_PATH.relative_to(ROOT))))
        issues = []

    findings.extend(check_issues(issues))

    phase_count = sum(1 for issue in issues if is_phase_0_or_1(issue))
    cutline_counts = {
        cutline: sum(
            1
            for issue in issues
            if is_phase_0_or_1(issue) and cutline in set(issue.get("labels") or [])
        )
        for cutline in sorted(ALLOWED_CUTLINES)
    }

    result = {
        "schema": "conveyor.cutline_audit@1",
        "matrix_ref": MATRIX_REF,
        "status": "pass" if not findings else "fail",
        "phase_issue_count": phase_count,
        "cutline_counts": cutline_counts,
        "finding_count": len(findings),
        "findings": findings,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
