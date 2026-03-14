#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_nostr_bench.sh [all]
  ./scripts/run_nostr_bench.sh <connect|echo|event|req> [nostr-bench options...]

Runs nostr-bench against a temporary Parrhesia test server started via
./scripts/run_e2e_suite.sh.

Examples:
  ./scripts/run_nostr_bench.sh
  ./scripts/run_nostr_bench.sh connect -c 500 -r 100
  ./scripts/run_nostr_bench.sh event --json -c 200 -r 100

Default "all" run can be tuned via env vars:
  PARRHESIA_BENCH_CONNECT_COUNT (default: 200)
  PARRHESIA_BENCH_CONNECT_RATE  (default: 100)
  PARRHESIA_BENCH_ECHO_COUNT    (default: 100)
  PARRHESIA_BENCH_ECHO_RATE     (default: 50)
  PARRHESIA_BENCH_ECHO_SIZE     (default: 512)
  PARRHESIA_BENCH_EVENT_COUNT   (default: 100)
  PARRHESIA_BENCH_EVENT_RATE    (default: 50)
  PARRHESIA_BENCH_REQ_COUNT     (default: 100)
  PARRHESIA_BENCH_REQ_RATE      (default: 50)
  PARRHESIA_BENCH_REQ_LIMIT     (default: 10)
  PARRHESIA_BENCH_KEEPALIVE_SECONDS (default: 5)
EOF
}

MODE="${1:-all}"
if [[ $# -gt 0 ]]; then
  shift
fi

if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v nostr-bench >/dev/null 2>&1; then
  echo "nostr-bench not found in PATH. Enter devenv shell first." >&2
  exit 1
fi

if [[ "$MODE" == "all" && $# -gt 0 ]]; then
  echo "extra arguments are only supported for explicit subcommands" >&2
  usage
  exit 1
fi

exec ./scripts/run_e2e_suite.sh \
  bench \
  bash -lc '
set -euo pipefail

relay_url="ws://127.0.0.1:${PARRHESIA_E2E_RELAY_PORT}/relay"
mode="$1"
shift || true

run_default() {
  echo "==> nostr-bench connect ${relay_url}"
  nostr-bench connect \
    --json \
    -c "${PARRHESIA_BENCH_CONNECT_COUNT:-200}" \
    -r "${PARRHESIA_BENCH_CONNECT_RATE:-100}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    "${relay_url}"

  echo
  echo "==> nostr-bench echo ${relay_url}"
  nostr-bench echo \
    --json \
    -c "${PARRHESIA_BENCH_ECHO_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_ECHO_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    --size "${PARRHESIA_BENCH_ECHO_SIZE:-512}" \
    "${relay_url}"

  echo
  echo "==> nostr-bench event ${relay_url}"
  nostr-bench event \
    --json \
    -c "${PARRHESIA_BENCH_EVENT_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_EVENT_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    "${relay_url}"

  echo
  echo "==> nostr-bench req ${relay_url}"
  nostr-bench req \
    --json \
    -c "${PARRHESIA_BENCH_REQ_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_REQ_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    --limit "${PARRHESIA_BENCH_REQ_LIMIT:-10}" \
    "${relay_url}"
}

case "$mode" in
  all)
    run_default
    ;;
  connect | echo | event | req)
    exec nostr-bench "$mode" "$@" "${relay_url}"
    ;;
  *)
    echo "invalid mode: ${mode}" >&2
    exit 1
    ;;
esac
' run_nostr_bench "$MODE" "$@"
