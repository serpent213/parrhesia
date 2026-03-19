#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_bench_cloud.sh [options] [-- extra args for cloud_bench_orchestrate.mjs]

Thin wrapper around scripts/cloud_bench_orchestrate.mjs.

Behavior:
  - Forwards args directly to the orchestrator.
  - Adds convenience aliases:
      --image IMAGE    -> --parrhesia-image IMAGE
  - Adds smoke defaults when --quick is set (unless already provided):
      --server-type cx23
      --client-type cx23
      --runs 1
      --clients 1
      --connect-count 20
      --connect-rate 20
      --echo-count 20
      --echo-rate 20
      --echo-size 512
      --event-count 20
      --event-rate 20
      --req-count 20
      --req-rate 20
      --req-limit 10
      --keepalive-seconds 2

Flags handled by this wrapper:
  --quick
  --image IMAGE
  -h, --help

Everything else is passed through unchanged.

Examples:
  just bench cloud
  just bench cloud --quick
  just bench cloud --clients 2 --runs 1 --targets parrhesia-memory
  just bench cloud --image ghcr.io/owner/parrhesia:latest --threads 4
  just bench cloud --no-monitoring
  just bench cloud --yes --datacenter auto
EOF
}

has_opt() {
  local key="$1"
  shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "$key" || "$arg" == "$key="* ]]; then
      return 0
    fi
  done
  return 1
}

add_default_if_missing() {
  local key="$1"
  local value="$2"
  if ! has_opt "$key" "${ORCH_ARGS[@]}"; then
    ORCH_ARGS+=("$key" "$value")
  fi
}

ORCH_ARGS=()
QUICK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --quick)
      QUICK=1
      ORCH_ARGS+=("--quick")
      shift
      ;;
    --image)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --image" >&2
        exit 1
      fi
      ORCH_ARGS+=("--parrhesia-image" "$2")
      shift 2
      ;;
    --)
      shift
      ORCH_ARGS+=("$@")
      break
      ;;
    *)
      ORCH_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "$QUICK" == "1" ]]; then
  add_default_if_missing "--server-type" "cx23"
  add_default_if_missing "--client-type" "cx23"
  add_default_if_missing "--runs" "1"
  add_default_if_missing "--clients" "1"

  add_default_if_missing "--connect-count" "20"
  add_default_if_missing "--connect-rate" "20"
  add_default_if_missing "--echo-count" "20"
  add_default_if_missing "--echo-rate" "20"
  add_default_if_missing "--echo-size" "512"
  add_default_if_missing "--event-count" "20"
  add_default_if_missing "--event-rate" "20"
  add_default_if_missing "--req-count" "20"
  add_default_if_missing "--req-rate" "20"
  add_default_if_missing "--req-limit" "10"
  add_default_if_missing "--keepalive-seconds" "2"
fi

CMD=(node scripts/cloud_bench_orchestrate.mjs "${ORCH_ARGS[@]}")

printf 'Running cloud bench:\n  %q' "${CMD[0]}"
for ((i=1; i<${#CMD[@]}; i++)); do
  printf ' %q' "${CMD[$i]}"
done
printf '\n\n'

"${CMD[@]}"
