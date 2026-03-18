#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_bench_at_ref.sh <git-ref>

Runs benchmarks for a specific git ref (tag, commit, or branch) and appends
the results to bench/history.jsonl.

Uses a temporary worktree to avoid disrupting your current working directory.

Arguments:
  git-ref    Git reference to benchmark (e.g., v0.4.0, abc1234, HEAD~3)

Environment:
  PARRHESIA_BENCH_RUNS               Number of runs (default: 3)
  PARRHESIA_BENCH_MACHINE_ID         Machine identifier (default: hostname -s)

All PARRHESIA_BENCH_* knobs from run_bench_compare.sh are forwarded.

Example:
  # Benchmark a specific tag
  ./scripts/run_bench_at_ref.sh v0.4.0

  # Benchmark a commit
  ./scripts/run_bench_at_ref.sh abc1234

  # Quick single-run benchmark
  PARRHESIA_BENCH_RUNS=1 ./scripts/run_bench_at_ref.sh v0.3.0
EOF
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

GIT_REF="$1"

# --- Validate ref exists -----------------------------------------------------

if ! git rev-parse --verify "$GIT_REF" >/dev/null 2>&1; then
  echo "Error: git ref '$GIT_REF' not found" >&2
  exit 1
fi

RESOLVED_COMMIT="$(git rev-parse "$GIT_REF")"
echo "Benchmarking ref: $GIT_REF ($RESOLVED_COMMIT)"
echo

# --- Setup worktree ----------------------------------------------------------

WORKTREE_DIR="$(mktemp -d)"
trap 'echo "Cleaning up worktree..."; git worktree remove --force "$WORKTREE_DIR" 2>/dev/null || rm -rf "$WORKTREE_DIR"' EXIT

echo "Creating temporary worktree at $WORKTREE_DIR"
git worktree add --detach "$WORKTREE_DIR" "$GIT_REF" >/dev/null 2>&1

# --- Run benchmark in worktree -----------------------------------------------

cd "$WORKTREE_DIR"

# Always copy latest benchmark scripts to ensure consistency
echo "Copying latest benchmark infrastructure from current..."
mkdir -p scripts bench
cp "$ROOT_DIR/scripts/run_bench_collect.sh" scripts/
cp "$ROOT_DIR/scripts/run_bench_compare.sh" scripts/
cp "$ROOT_DIR/scripts/run_nostr_bench.sh" scripts/
if [[ -f "$ROOT_DIR/scripts/run_nostr_bench_strfry.sh" ]]; then
  cp "$ROOT_DIR/scripts/run_nostr_bench_strfry.sh" scripts/
fi
if [[ -f "$ROOT_DIR/scripts/run_nostr_bench_nostr_rs_relay.sh" ]]; then
  cp "$ROOT_DIR/scripts/run_nostr_bench_nostr_rs_relay.sh" scripts/
fi
echo

echo "Installing dependencies..."
mix deps.get
echo

echo "Running benchmark in worktree..."
echo

RUNS="${PARRHESIA_BENCH_RUNS:-3}"

# Run the benchmark collect script which will append to history.jsonl
PARRHESIA_BENCH_RUNS="$RUNS" \
PARRHESIA_BENCH_MACHINE_ID="${PARRHESIA_BENCH_MACHINE_ID:-}" \
  ./scripts/run_bench_collect.sh

# --- Copy results back -------------------------------------------------------

echo
echo "Copying results back to main repository..."

if [[ -f "$WORKTREE_DIR/bench/history.jsonl" ]]; then
  HISTORY_FILE="$ROOT_DIR/bench/history.jsonl"

  # Get the last line from worktree history (the one just added)
  NEW_ENTRY="$(tail -n 1 "$WORKTREE_DIR/bench/history.jsonl")"

  # Check if this exact entry already exists in the main history
  if grep -Fxq "$NEW_ENTRY" "$HISTORY_FILE" 2>/dev/null; then
    echo "Note: Entry already exists in $HISTORY_FILE, skipping append"
  else
    echo "Appending result to $HISTORY_FILE"
    echo "$NEW_ENTRY" >> "$HISTORY_FILE"
  fi
else
  echo "Warning: No history.jsonl found in worktree" >&2
  exit 1
fi

# --- Done --------------------------------------------------------------------

echo
echo "Benchmark complete for $GIT_REF"
echo
echo "To regenerate the chart with updated history:"
echo "  # The chart generation reads from bench/history.jsonl"
echo "  # You can manually trigger chart regeneration if needed"
