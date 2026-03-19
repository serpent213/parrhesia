#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_bench_collect.sh

Runs the benchmark suite and appends results to bench/history.jsonl.
Does NOT update README.md or regenerate chart.svg.

Use run_bench_update.sh to update the chart and README from collected data.

Environment:
  PARRHESIA_BENCH_RUNS               Number of runs (default: 3)
  PARRHESIA_BENCH_MACHINE_ID         Machine identifier (default: hostname -s)

All PARRHESIA_BENCH_* knobs from run_bench_compare.sh are forwarded.

Example:
  # Collect benchmark data
  ./scripts/run_bench_collect.sh

  # Later, update chart and README
  ./scripts/run_bench_update.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# --- Configuration -----------------------------------------------------------

BENCH_DIR="$ROOT_DIR/bench"
HISTORY_FILE="$BENCH_DIR/history.jsonl"

MACHINE_ID="${PARRHESIA_BENCH_MACHINE_ID:-$(hostname -s)}"
GIT_TAG="$(git describe --tags --abbrev=0 2>/dev/null || echo 'untagged')"
GIT_COMMIT="$(git rev-parse --short=7 HEAD)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUNS="${PARRHESIA_BENCH_RUNS:-3}"

mkdir -p "$BENCH_DIR"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

JSON_OUT="$WORK_DIR/bench_summary.json"
RAW_OUTPUT="$WORK_DIR/bench_output.txt"

# --- Phase 1: Run benchmarks -------------------------------------------------

echo "Running ${RUNS}-run benchmark suite..."

PARRHESIA_BENCH_RUNS="$RUNS" \
BENCH_JSON_OUT="$JSON_OUT" \
  ./scripts/run_bench_compare.sh 2>&1 | tee "$RAW_OUTPUT"

if [[ ! -f "$JSON_OUT" ]]; then
  echo "Benchmark JSON output not found at $JSON_OUT" >&2
  exit 1
fi

# --- Phase 2: Append to history ----------------------------------------------

echo "Appending to history..."

node - "$JSON_OUT" "$TIMESTAMP" "$MACHINE_ID" "$GIT_TAG" "$GIT_COMMIT" "$RUNS" "$HISTORY_FILE" <<'NODE'
const fs = require("node:fs");

const [, , jsonOut, timestamp, machineId, gitTag, gitCommit, runsStr, historyFile] = process.argv;

const { versions, ...servers } = JSON.parse(fs.readFileSync(jsonOut, "utf8"));

const entry = {
  schema_version: 2,
  timestamp,
  run_id: `local-${timestamp}-${machineId}-${gitCommit}`,
  machine_id: machineId,
  git_tag: gitTag,
  git_commit: gitCommit,
  runs: Number(runsStr),
  source: {
    kind: "local",
    mode: "run_bench_collect",
    git_ref: gitTag,
    git_tag: gitTag,
    git_commit: gitCommit,
  },
  infra: {
    provider: "local",
  },
  versions: versions || {},
  servers,
};

fs.appendFileSync(historyFile, JSON.stringify(entry) + "\n", "utf8");
console.log("  entry: " + gitTag + " (" + gitCommit + ") on " + machineId);
NODE

# --- Done ---------------------------------------------------------------------

echo
echo "Benchmark data collected and appended to $HISTORY_FILE"
echo
echo "To update chart and README with collected data:"
echo "  ./scripts/run_bench_update.sh"
echo
echo "To update for a specific machine:"
echo "  ./scripts/run_bench_update.sh <machine_id>"
