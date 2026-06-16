#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${CONVEYOR_CI_ARTIFACT_DIR:-$ROOT/tmp/ci/control-plane}"
LOG_DIR="$ARTIFACT_DIR/logs"
STATIONS_JSONL="$ARTIFACT_DIR/stations.jsonl"
SUMMARY_JSON="$ARTIFACT_DIR/summary.json"

mkdir -p "$LOG_DIR"
: >"$STATIONS_JSONL"

overall_status="pass"
overall_code=0

generate_secret() {
  python3 -c 'import secrets; print(secrets.token_urlsafe(48))'
}

export CONVEYOR_SESSION_SIGNING_SALT="${CONVEYOR_SESSION_SIGNING_SALT:-$(generate_secret)}"
export PHX_LIVE_VIEW_SIGNING_SALT="${PHX_LIVE_VIEW_SIGNING_SALT:-$(generate_secret)}"
export PHX_SECRET_KEY_BASE="${PHX_SECRET_KEY_BASE:-$(generate_secret)}"

json_line() {
  local station_key="$1"
  local status="$2"
  local exit_code="$3"
  local duration_ms="$4"
  local log_path="$5"
  local command="$6"
  local category="$7"

  python3 - "$STATIONS_JSONL" "$station_key" "$status" "$exit_code" "$duration_ms" "$log_path" "$command" "$category" <<'PY'
import json
import sys
from pathlib import Path

path, station_key, status, exit_code, duration_ms, log_path, command, category = sys.argv[1:]
record = {
    "schema": "conveyor.ci_station@1",
    "station_key": station_key,
    "status": status,
    "exit_code": int(exit_code),
    "duration_ms": int(duration_ms),
    "log_path": log_path,
    "command": command,
    "finding_category": category,
}
with Path(path).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

run_station() {
  local station_key="$1"
  shift
  local log_path="$LOG_DIR/$station_key.log"
  local started ended duration exit_code

  started="$(date +%s%3N)"
  echo "==> $station_key: $*"

  "$@" >"$log_path" 2>&1
  exit_code=$?

  ended="$(date +%s%3N)"
  duration=$((ended - started))

  if [ "$exit_code" -eq 0 ]; then
    json_line "$station_key" "pass" "$exit_code" "$duration" "$log_path" "$*" ""
    echo "PASS $station_key duration_ms=$duration log=$log_path"
  else
    overall_status="fail"
    if [ "$overall_code" -eq 0 ]; then
      overall_code="$exit_code"
    fi
    json_line "$station_key" "fail" "$exit_code" "$duration" "$log_path" "$*" "ci_station_failed"
    echo "FAIL $station_key exit=$exit_code duration_ms=$duration log=$log_path" >&2
    echo "--- $station_key log tail ---" >&2
    tail -80 "$log_path" >&2
    echo "--- end $station_key log tail ---" >&2
  fi
}

skip_station() {
  local station_key="$1"
  local reason="$2"
  local log_path="$LOG_DIR/$station_key.log"

  printf '%s\n' "$reason" >"$log_path"
  json_line "$station_key" "skip" 0 0 "$log_path" "$reason" ""
  echo "SKIP $station_key reason=$reason log=$log_path"
}

cd "$ROOT" || exit 1

run_station hex mix local.hex --force
run_station rebar mix local.rebar --force
run_station deps_get mix deps.get
run_station format mix format --check-formatted
run_station compile mix compile --warnings-as-errors
run_station ecto_migrate mix ecto.migrate
run_station config_probe mix conveyor.config_probe \
  --config .conveyor/config.toml \
  --output "$ARTIFACT_DIR/conveyor_config_probe.json"
run_station version_probe mix conveyor.version_probe \
  --output "$ARTIFACT_DIR/conveyor_version_probe.json" \
  --boot-log "$ARTIFACT_DIR/conveyor_boot.log"
run_station test mix test

if mix help credo >"$LOG_DIR/credo.detect.log" 2>&1; then
  run_station credo mix credo --strict
else
  skip_station credo "mix credo is not configured"
fi

if mix help dialyzer >"$LOG_DIR/dialyzer.detect.log" 2>&1; then
  run_station dialyzer mix dialyzer
else
  skip_station dialyzer "mix dialyzer is not configured"
fi

python3 - "$STATIONS_JSONL" "$SUMMARY_JSON" "$overall_status" "$overall_code" <<'PY'
import json
import sys
from pathlib import Path

stations_path, summary_path, status, exit_code = sys.argv[1:]
stations = [
    json.loads(line)
    for line in Path(stations_path).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
summary = {
    "schema": "conveyor.ci_control_plane_summary@1",
    "status": status,
    "exit_code": int(exit_code),
    "station_count": len(stations),
    "stations": stations,
}
Path(summary_path).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(summary, indent=2, sort_keys=True))
PY

exit "$overall_code"
