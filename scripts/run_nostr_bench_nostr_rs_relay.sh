#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_nostr_bench_nostr_rs_relay.sh [all]
  ./scripts/run_nostr_bench_nostr_rs_relay.sh <connect|echo|event|req> [nostr-bench options...]

Runs nostr-bench against a running nostr-rs-relay instance.

Examples:
  ./scripts/run_nostr_bench_nostr_rs_relay.sh
  NOSTR_RS_BENCH_RELAY_URL=ws://127.0.0.1:8080 ./scripts/run_nostr_bench_nostr_rs_relay.sh
  ./scripts/run_nostr_bench_nostr_rs_relay.sh connect -c 500 -r 100

Relay target env vars:
  NOSTR_RS_BENCH_RELAY_URL (default: ws://127.0.0.1:${NOSTR_RS_RELAY_PORT:-8080})
  NOSTR_RS_RELAY_PORT      (default: 8080)

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

RELAY_URL="${NOSTR_RS_BENCH_RELAY_URL:-ws://127.0.0.1:${NOSTR_RS_RELAY_PORT:-8080}}"

if [[ "$MODE" == "all" && $# -gt 0 ]]; then
  echo "extra arguments are only supported for explicit subcommands" >&2
  usage
  exit 1
fi

run_default() {
  echo "==> nostr-bench connect ${RELAY_URL}"
  nostr-bench connect \
    --json \
    -c "${PARRHESIA_BENCH_CONNECT_COUNT:-200}" \
    -r "${PARRHESIA_BENCH_CONNECT_RATE:-100}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    "${RELAY_URL}"

  echo
  echo "==> nostr-bench echo ${RELAY_URL}"
  nostr-bench echo \
    --json \
    -c "${PARRHESIA_BENCH_ECHO_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_ECHO_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    --size "${PARRHESIA_BENCH_ECHO_SIZE:-512}" \
    "${RELAY_URL}"

  echo
  echo "==> nostr-bench event ${RELAY_URL}"
  nostr-bench event \
    --json \
    -c "${PARRHESIA_BENCH_EVENT_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_EVENT_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    "${RELAY_URL}"

  echo
  echo "==> nostr-bench req ${RELAY_URL}"
  nostr-bench req \
    --json \
    -c "${PARRHESIA_BENCH_REQ_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_REQ_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    --limit "${PARRHESIA_BENCH_REQ_LIMIT:-10}" \
    "${RELAY_URL}"
}

case "$MODE" in
  all)
    run_default
    ;;
  connect | echo | event | req)
    exec nostr-bench "$MODE" "$@" "${RELAY_URL}"
    ;;
  *)
    echo "invalid mode: ${MODE}" >&2
    exit 1
    ;;
esac
