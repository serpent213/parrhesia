#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export MIX_ENV=test
export PARRHESIA_NAK_E2E=1

TEST_HTTP_PORT="${PARRHESIA_NAK_E2E_RELAY_PORT:-$(( (RANDOM % 10000) + 40000 ))}"

if [[ -z "${PGDATABASE:-}" ]]; then
  export PGDATABASE="parrhesia_nak_e2e_test"
fi

PARRHESIA_TEST_HTTP_PORT=0 mix ecto.drop --quiet || true
PARRHESIA_TEST_HTTP_PORT=0 mix ecto.create --quiet
PARRHESIA_TEST_HTTP_PORT=0 mix ecto.migrate --quiet

SERVER_LOG="${ROOT_DIR}/.nak-e2e-server.log"
: > "$SERVER_LOG"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

if ss -ltn "( sport = :${TEST_HTTP_PORT} )" | tail -n +2 | grep -q .; then
  echo "Port ${TEST_HTTP_PORT} is already in use. Set PARRHESIA_NAK_E2E_RELAY_PORT to a free port." >&2
  exit 1
fi

PARRHESIA_TEST_HTTP_PORT="$TEST_HTTP_PORT" mix run --no-halt >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

READY=0
for _ in {1..100}; do
  if curl -fsS "http://127.0.0.1:${TEST_HTTP_PORT}/health" >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.1
done

if [[ "$READY" -ne 1 ]]; then
  echo "Server did not become ready on port ${TEST_HTTP_PORT}" >&2
  tail -n 200 "$SERVER_LOG" >&2 || true
  exit 1
fi

PARRHESIA_TEST_HTTP_PORT=0 \
  PARRHESIA_NAK_E2E_RELAY_PORT="$TEST_HTTP_PORT" \
  mix test test/parrhesia/e2e/nak_cli_test.exs --no-start --only nak_e2e --timeout 15000
