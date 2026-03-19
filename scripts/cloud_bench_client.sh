#!/usr/bin/env bash
set -euo pipefail

relay_url="${1:-}"
mode="${2:-all}"

if [[ -z "$relay_url" ]]; then
  echo "usage: cloud-bench-client.sh <relay-url> [connect|echo|event|req|all]" >&2
  exit 1
fi

bench_bin="${NOSTR_BENCH_BIN:-/usr/local/bin/nostr-bench}"
bench_threads="${PARRHESIA_BENCH_THREADS:-0}"
client_nofile="${PARRHESIA_BENCH_CLIENT_NOFILE:-262144}"

ulimit -n "${client_nofile}" >/dev/null 2>&1 || true

run_connect() {
  echo "==> nostr-bench connect ${relay_url}"
  "$bench_bin" connect --json \
    -c "${PARRHESIA_BENCH_CONNECT_COUNT:-200}" \
    -r "${PARRHESIA_BENCH_CONNECT_RATE:-100}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    -t "${bench_threads}" \
    "${relay_url}"
}

run_echo() {
  echo "==> nostr-bench echo ${relay_url}"
  "$bench_bin" echo --json \
    -c "${PARRHESIA_BENCH_ECHO_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_ECHO_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    -t "${bench_threads}" \
    --size "${PARRHESIA_BENCH_ECHO_SIZE:-512}" \
    "${relay_url}"
}

run_event() {
  echo "==> nostr-bench event ${relay_url}"
  "$bench_bin" event --json \
    -c "${PARRHESIA_BENCH_EVENT_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_EVENT_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    -t "${bench_threads}" \
    "${relay_url}"
}

run_req() {
  echo "==> nostr-bench req ${relay_url}"
  "$bench_bin" req --json \
    -c "${PARRHESIA_BENCH_REQ_COUNT:-100}" \
    -r "${PARRHESIA_BENCH_REQ_RATE:-50}" \
    -k "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    -t "${bench_threads}" \
    --limit "${PARRHESIA_BENCH_REQ_LIMIT:-10}" \
    "${relay_url}"
}

case "$mode" in
  connect) run_connect ;;
  echo)    run_echo ;;
  event)   run_event ;;
  req)     run_req ;;
  all)     run_connect; echo; run_echo; echo; run_event; echo; run_req ;;
  *)       echo "unknown mode: $mode" >&2; exit 1 ;;
esac
