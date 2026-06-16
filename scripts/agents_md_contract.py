#!/usr/bin/env python3
"""Generate and lint Conveyor AGENTS.md contracts."""

from __future__ import annotations

import argparse
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any


SCHEMA = "conveyor.agents_md_contract@1"
FINDING_SCHEMA = "conveyor.agents_md_finding@1"
MATRIX_REF = "conveyor-quality-ci-evals-vmr.13"
DEFAULT_CONFIG = Path(".conveyor/config.toml")
DEFAULT_POLICY = Path("docs/policy/profiles.json")
DEFAULT_TARGET = Path("AGENTS.md")

DEFAULT_SECTION_RULES = {
    "Overview": ["Conveyor", "control plane", "Phase 0", "Phase 1"],
    "Architecture Map": [
        "Conveyor.ProjectConfig",
        "Conveyor.Domain",
        "Conveyor.Repo",
        "Conveyor.Oban",
        "ConveyorWeb.Endpoint",
    ],
    "Commands": [],
    "Coding Rules": ["No Script-Based Changes", "revise existing code files in place"],
    "Testing and Verification": ["UBS", "mix test", "mix format --check-formatted"],
    "Security Rules": ["credentials", "network", "sandbox", "human approval"],
    "Git and Task Rules": ["main", "Beads", "Agent Mail"],
    "Done Criteria": ["br sync --flush-only", "tests", "artifacts", "push"],
    "Forbidden Actions": [],
    "Conveyor Evidence": ["RunSpec", "run_spec_sha256", "structured", "evidence"],
    "CodeScent Context": ["CodeScent", "optional", "credential"],
    "Blocker Reporting": ["blocker", "finding", "NextAction"],
}

SECTION_ALIASES = {
    "Overview": ["Overview", "Conveyor Project Overview"],
    "Architecture Map": ["Architecture Map", "System Shape", "Architecture Contract"],
    "Commands": ["Commands", "Conveyor Project Commands", "Installed Tools Quick Reference"],
    "Coding Rules": ["Coding Rules", "Code Editing Discipline"],
    "Testing and Verification": ["Testing and Verification", "Compiler Checks", "Testing"],
    "Security Rules": ["Security Rules", "Safety Policy", "Safety Contract"],
    "Git and Task Rules": ["Git and Task Rules", "Git Branch", "Beads", "MCP Agent Mail"],
    "Done Criteria": ["Done Criteria", "Landing the Plane"],
    "Forbidden Actions": ["Forbidden Actions", "Irreversible Git & Filesystem Actions"],
    "Conveyor Evidence": ["Conveyor Evidence", "Evidence Requirements"],
    "CodeScent Context": ["CodeScent Context"],
    "Blocker Reporting": ["Blocker Reporting", "MCP Agent Mail", "Landing the Plane"],
}


def decode_json(path: Path) -> dict[str, Any]:
    return json.JSONDecoder().decode(path.read_text(encoding="utf-8"))


def load_config(path: Path) -> dict[str, Any]:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def command_specs(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    commands = config.get("commands", {})
    if not isinstance(commands, dict):
        return {}
    return {str(key): value for key, value in commands.items() if isinstance(value, dict)}


def section_rules(config: dict[str, Any]) -> dict[str, list[str]]:
    rules = {title: list(terms) for title, terms in DEFAULT_SECTION_RULES.items()}
    agents_md = config.get("agents_md", {})
    if not isinstance(agents_md, dict):
        return rules

    overrides = agents_md.get("section_rules", {})
    if not isinstance(overrides, dict):
        return rules

    for title, terms in overrides.items():
        if str(title) not in rules or not isinstance(terms, list):
            continue
        rules[str(title)] = [str(term) for term in terms]

    return rules


def command_text(command_id: str, command: dict[str, Any]) -> str:
    executable = str(command.get("executable", ""))
    argv = [str(part) for part in command.get("argv", [])]
    return " ".join([executable, *argv]).strip() or command_id


def denylist_patterns(policy: dict[str, Any]) -> list[str]:
    classes = policy.get("denylist_classes", {})
    patterns: list[str] = []
    if not isinstance(classes, dict):
        return patterns

    for class_doc in classes.values():
        if not isinstance(class_doc, dict):
            continue
        for pattern in class_doc.get("blocked_patterns", []):
            if isinstance(pattern, str):
                patterns.append(pattern)
    return sorted(set(patterns))


def markdown_sections(text: str) -> dict[str, str]:
    matches = list(re.finditer(r"^(#{1,6})\s+(.+?)\s*$", text, flags=re.MULTILINE))
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        title = match.group(2).strip()
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections[title] = text[start:end]
    return sections


def section_body(sections: dict[str, str], required_title: str) -> str:
    for alias in SECTION_ALIASES[required_title]:
        if alias in sections:
            return sections[alias]
    return ""


def add_finding(findings: list[dict[str, Any]], code: str, message: str, **extra: Any) -> None:
    finding = {
        "schema": FINDING_SCHEMA,
        "severity": "error",
        "category": "agents_md_contract",
        "code": code,
        "message": message,
        "matrix_ref": MATRIX_REF,
    }
    finding.update(extra)
    findings.append(finding)


def supplemental_terms(title: str, lines: list[str], config: dict[str, Any]) -> list[str]:
    body = "\n".join(lines)
    missing_terms = [term for term in section_rules(config)[title] if term not in body]
    if not missing_terms:
        return []

    return ["- Contract terms: " + ", ".join(f"`{term}`" for term in missing_terms) + "."]


def validate_agents_md(text: str, config: dict[str, Any], policy: dict[str, Any]) -> list[dict[str, Any]]:
    sections = markdown_sections(text)
    findings: list[dict[str, Any]] = []

    for title, required_terms in section_rules(config).items():
        body = section_body(sections, title)
        if not body:
            add_finding(findings, "missing_section", f"AGENTS.md is missing {title}", section=title)
            continue

        missing_terms = [term for term in required_terms if term not in body]
        if missing_terms:
            add_finding(
                findings,
                "missing_section_terms",
                f"{title} is missing required contract terms",
                section=title,
                missing_terms=missing_terms,
            )

    command_body = section_body(sections, "Commands")
    for command_id, command in sorted(command_specs(config).items()):
        expected = command_text(command_id, command)
        if command_id not in command_body or expected not in command_body:
            add_finding(
                findings,
                "command_mismatch",
                "AGENTS.md command section does not match .conveyor/config.toml",
                command_id=command_id,
                expected=expected,
            )

    forbidden_body = section_body(sections, "Forbidden Actions")
    for pattern in denylist_patterns(policy):
        if pattern not in forbidden_body:
            add_finding(
                findings,
                "forbidden_action_mismatch",
                "AGENTS.md forbidden actions do not align with policy denylist",
                pattern=pattern,
            )

    done_body = section_body(sections, "Done Criteria")
    if done_body and not all(term in done_body for term in ("tests", "artifacts", "push")):
        add_finding(
            findings,
            "vague_done_criteria",
            "Done Criteria must name tests, artifacts, and push expectations",
        )

    security_body = section_body(sections, "Security Rules")
    if security_body and not all(term in security_body.lower() for term in ("credential", "network", "sandbox")):
        add_finding(
            findings,
            "missing_security_rules",
            "Security Rules must cover credentials, network policy, and sandbox behavior",
        )

    return findings


def render_agents_md(config: dict[str, Any], policy: dict[str, Any]) -> str:
    command_lines = []
    for command_id, command in sorted(command_specs(config).items()):
        command_lines.append(
            "- "
            f"`{command_id}`: `{command_text(command_id, command)}` "
            f"(cwd `{command.get('cwd')}`, artifact `{command.get('artifact_path')}`, "
            f"network `{command.get('network')}`, consumers `{', '.join(command.get('consumers', []))}`)"
        )

    forbidden_lines = [f"- `{pattern}`" for pattern in denylist_patterns(policy)]
    overview_lines = [
        "Conveyor is a deterministic control plane for Phase 0 and Phase 1 agentic coding work.",
    ]
    architecture_lines = [
        "- `Conveyor.ProjectConfig` loads project command and policy input.",
        "- `Conveyor.Domain` owns Ash resources through `Conveyor.Repo`.",
        "- `Conveyor.Oban` runs durable work in the supervision tree.",
        "- `ConveyorWeb.Endpoint` hosts the Phoenix/LiveView operator surface.",
    ]
    testing_lines = [
        "- Run UBS, `mix test`, and `mix format --check-formatted` where applicable.",
    ]

    return "\n".join(
        [
            "# AGENTS.md - Conveyor Generated Contract",
            "",
            "## Overview",
            *overview_lines,
            *supplemental_terms("Overview", overview_lines, config),
            "",
            "## Architecture Map",
            *architecture_lines,
            *supplemental_terms("Architecture Map", architecture_lines, config),
            "",
            "## Commands",
            *command_lines,
            "",
            "## Coding Rules",
            "- No Script-Based Changes for source rewrites; revise existing code files in place.",
            "",
            "## Testing and Verification",
            *testing_lines,
            *supplemental_terms("Testing and Verification", testing_lines, config),
            "",
            "## Security Rules",
            "- Respect credentials, network policy, sandbox limits, and human approval boundaries.",
            "",
            "## Git and Task Rules",
            "- Work on `main`; track work with Beads and Agent Mail.",
            "",
            "## Done Criteria",
            "- Done means tests pass, artifacts are preserved, `br sync --flush-only` has run, and push policy is satisfied.",
            "",
            "## Forbidden Actions",
            *forbidden_lines,
            "",
            "## Conveyor Evidence",
            "- RunSpec evidence uses `run_spec_sha256`, structured findings, and preserved evidence artifacts.",
            "",
            "## CodeScent Context",
            "- CodeScent is optional unless a command profile explicitly grants the credential and context.",
            "",
            "## Blocker Reporting",
            "- Report every blocker as a structured finding with a concrete NextAction.",
            "",
        ]
    )


def case_result(name: str, findings: list[dict[str, Any]], expected_codes: set[str]) -> dict[str, Any]:
    actual_codes = {str(finding["code"]) for finding in findings}
    status = "pass" if actual_codes == expected_codes else "fail"
    if expected_codes and expected_codes <= actual_codes:
        status = "pass"

    return {
        "name": name,
        "status": status,
        "expected_codes": sorted(expected_codes),
        "actual_codes": sorted(actual_codes),
        "finding_count": len(findings),
    }


def run_self_test(config: dict[str, Any], policy: dict[str, Any]) -> list[dict[str, Any]]:
    generated = render_agents_md(config, policy)
    commands = command_specs(config)
    command_id = "verify" if "verify" in commands else sorted(commands)[0]
    cases = [
        ("generated_file_passes", generated, set()),
        (
            "missing_security_rules",
            re.sub(
                r"## Security Rules\n.*?\n\n",
                "## Security Rules\n- Human approval is required.\n\n",
                generated,
                flags=re.DOTALL,
            ),
            {"missing_section_terms", "missing_security_rules"},
        ),
        (
            "vague_done_criteria",
            re.sub(
                r"## Done Criteria\n.*?\n\n",
                "## Done Criteria\n- Done when it looks good.\n\n",
                generated,
                flags=re.DOTALL,
            ),
            {"missing_section_terms", "vague_done_criteria"},
        ),
        (
            "command_mismatch",
            generated.replace(command_text(command_id, commands[command_id]), "missing command"),
            {"command_mismatch"},
        ),
        (
            "forbidden_action_mismatch",
            generated.replace("- `git reset --hard`\n", ""),
            {"forbidden_action_mismatch"},
        ),
    ]
    return [case_result(name, validate_agents_md(text, config, policy), expected) for name, text, expected in cases]


def write_output(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    parser.add_argument("--target", type=Path, default=DEFAULT_TARGET)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--generated-output", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--lint-target", action="store_true")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    config = load_config(args.config)
    policy = decode_json(args.policy)
    generated = render_agents_md(config, policy)

    if args.generated_output:
        args.generated_output.parent.mkdir(parents=True, exist_ok=True)
        args.generated_output.write_text(generated, encoding="utf-8")

    generated_findings = validate_agents_md(generated, config, policy)
    self_tests = run_self_test(config, policy) if args.self_test else []
    target_findings: list[dict[str, Any]] = []

    if args.lint_target:
        target_findings = validate_agents_md(args.target.read_text(encoding="utf-8"), config, policy)

    findings = generated_findings + target_findings
    status = "pass"
    if findings or any(case["status"] != "pass" for case in self_tests):
        status = "fail"

    payload = {
        "schema": SCHEMA,
        "matrix_ref": MATRIX_REF,
        "status": status,
        "config": str(args.config),
        "policy": str(args.policy),
        "target": str(args.target),
        "generated_finding_count": len(generated_findings),
        "target_finding_count": len(target_findings),
        "findings": findings,
        "self_tests": self_tests,
    }

    if args.output:
        write_output(args.output, payload)

    print(json.dumps(payload, indent=2, sort_keys=True))
    return 1 if status == "fail" else 0


if __name__ == "__main__":
    sys.exit(main())
