#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <suite-name> <command> [args...]" >&2
  exit 1
fi

SUITE_NAME="$1"
shift

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export MIX_ENV=test

SUITE_SLUG="$(printf '%s' "$SUITE_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
SUITE_UPPER="$(printf '%s' "$SUITE_SLUG" | tr '[:lower:]' '[:upper:]')"
PORT_ENV_VAR="PARRHESIA_${SUITE_UPPER}_E2E_RELAY_PORT"

DEFAULT_PORT="$(( (RANDOM % 10000) + 40000 ))"
TEST_HTTP_PORT="${!PORT_ENV_VAR:-${PARRHESIA_E2E_RELAY_PORT:-$DEFAULT_PORT}}"

export PARRHESIA_E2E_RELAY_PORT="$TEST_HTTP_PORT"
printf -v "$PORT_ENV_VAR" '%s' "$TEST_HTTP_PORT"
export "$PORT_ENV_VAR"

if [[ -z "${PGDATABASE:-}" ]]; then
  export PGDATABASE="parrhesia_${SUITE_SLUG}_test"
fi

PARRHESIA_TEST_HTTP_PORT=0 mix ecto.drop --quiet || true
PARRHESIA_TEST_HTTP_PORT=0 mix ecto.create --quiet
PARRHESIA_TEST_HTTP_PORT=0 mix ecto.migrate --quiet

SERVER_LOG="${ROOT_DIR}/.${SUITE_SLUG}-e2e-server.log"
: > "$SERVER_LOG"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
}

trap cleanup EXIT INT TERM

if ss -ltn "( sport = :${TEST_HTTP_PORT} )" | tail -n +2 | grep -q .; then
  echo "Port ${TEST_HTTP_PORT} is already in use. Set ${PORT_ENV_VAR} to a free port." >&2
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

PARRHESIA_TEST_HTTP_PORT=0 "$@"
