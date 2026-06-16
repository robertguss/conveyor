#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
OUT_DIR="${BASELINE_OUT_DIR:-${ROOT_DIR}/artifacts/${RUN_ID}}"

mkdir -p "${OUT_DIR}"
cd "${ROOT_DIR}"

if command -v uv >/dev/null 2>&1; then
  PYTEST_CMD=(uv run --extra test python -m pytest)
else
  PYTHON_BIN="${PYTHON_BIN:-python3}"
  PYTEST_CMD=("${PYTHON_BIN}" -m pytest)
fi

set +e
"${PYTEST_CMD[@]}" tests/baseline_regression --junitxml "${OUT_DIR}/pytest-junit.xml" 2>&1 | tee "${OUT_DIR}/pytest.log"
PYTEST_STATUS="${PIPESTATUS[0]}"
set -e

if command -v python3 >/dev/null 2>&1; then
  SUMMARY_PYTHON=python3
else
  SUMMARY_PYTHON="${PYTEST_CMD[0]}"
fi

"${SUMMARY_PYTHON}" - "${OUT_DIR}" "${PYTEST_STATUS}" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

out_dir = Path(sys.argv[1])
pytest_status = int(sys.argv[2])
junit_path = out_dir / "pytest-junit.xml"

summary = {
    "schema_version": "baseline_summary@1",
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "sample": "fastapi_tasks",
    "suite": "baseline_regression",
    "blocks_implementation": True,
    "acceptance_locked_suite": "separate",
    "storage": "in_memory",
    "production_secrets_required": False,
    "network_egress_required": False,
    "pytest_exit_code": pytest_status,
    "status": "passed" if pytest_status == 0 else "failed",
    "artifacts": {
        "junitxml": str(junit_path),
        "raw_log": str(out_dir / "pytest.log"),
    },
}

if junit_path.exists():
    root = ET.parse(junit_path).getroot()
    suites = root.findall("testsuite") if root.tag == "testsuites" else [root]
    summary["tests"] = sum(int(s.attrib.get("tests", 0)) for s in suites)
    summary["failures"] = sum(int(s.attrib.get("failures", 0)) for s in suites)
    summary["errors"] = sum(int(s.attrib.get("errors", 0)) for s in suites)
    summary["skipped"] = sum(int(s.attrib.get("skipped", 0)) for s in suites)

summary_path = out_dir / "baseline-summary.json"
summary["artifacts"]["structured_summary"] = str(summary_path)
summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"baseline summary: {summary_path}")
PY

exit "${PYTEST_STATUS}"
