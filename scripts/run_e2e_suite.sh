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

MIX_ENV="${PARRHESIA_E2E_MIX_ENV:-test}"
if [[ "$MIX_ENV" != "test" && "$MIX_ENV" != "prod" ]]; then
  echo "PARRHESIA_E2E_MIX_ENV must be test or prod, got: $MIX_ENV" >&2
  exit 1
fi
export MIX_ENV

SUITE_SLUG="$(printf '%s' "$SUITE_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
SUITE_UPPER="$(printf '%s' "$SUITE_SLUG" | tr '[:lower:]' '[:upper:]')"
PORT_ENV_VAR="PARRHESIA_${SUITE_UPPER}_E2E_RELAY_PORT"

DEFAULT_PORT="$(( (RANDOM % 10000) + 40000 ))"
TEST_HTTP_PORT="${!PORT_ENV_VAR:-${PARRHESIA_E2E_RELAY_PORT:-$DEFAULT_PORT}}"

export PARRHESIA_E2E_RELAY_PORT="$TEST_HTTP_PORT"
printf -v "$PORT_ENV_VAR" '%s' "$TEST_HTTP_PORT"
export "$PORT_ENV_VAR"

if [[ -z "${PGDATABASE:-}" ]]; then
  export PGDATABASE="parrhesia_${SUITE_SLUG}_${MIX_ENV}"
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  PGUSER_EFFECTIVE="${PGUSER:-${USER:-agent}}"
  PGHOST_EFFECTIVE="${PGHOST:-localhost}"
  PGPORT_EFFECTIVE="${PGPORT:-5432}"

  # Ecto requires a URL host to be present. For unix sockets we keep a dummy
  # TCP host and pass the socket directory as query option.
  if [[ "$PGHOST_EFFECTIVE" == /* ]]; then
    if [[ -n "${PGPASSWORD:-}" ]]; then
      export DATABASE_URL="ecto://${PGUSER_EFFECTIVE}:${PGPASSWORD}@localhost/${PGDATABASE}?socket_dir=${PGHOST_EFFECTIVE}&port=${PGPORT_EFFECTIVE}"
    else
      export DATABASE_URL="ecto://${PGUSER_EFFECTIVE}@localhost/${PGDATABASE}?socket_dir=${PGHOST_EFFECTIVE}&port=${PGPORT_EFFECTIVE}"
    fi
  else
    if [[ -n "${PGPASSWORD:-}" ]]; then
      export DATABASE_URL="ecto://${PGUSER_EFFECTIVE}:${PGPASSWORD}@${PGHOST_EFFECTIVE}:${PGPORT_EFFECTIVE}/${PGDATABASE}"
    else
      export DATABASE_URL="ecto://${PGUSER_EFFECTIVE}@${PGHOST_EFFECTIVE}:${PGPORT_EFFECTIVE}/${PGDATABASE}"
    fi
  fi
fi

if [[ "$MIX_ENV" == "test" ]]; then
  PARRHESIA_TEST_HTTP_PORT=0 mix ecto.drop --quiet --force || true
  PARRHESIA_TEST_HTTP_PORT=0 mix ecto.create --quiet
  PARRHESIA_TEST_HTTP_PORT=0 mix ecto.migrate --quiet
else
  mix ecto.drop --quiet --force || true
  mix ecto.create --quiet
  mix ecto.migrate --quiet
fi

SERVER_LOG="${ROOT_DIR}/.${SUITE_SLUG}-e2e-server.log"
: > "$SERVER_LOG"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi

  if [[ "${PARRHESIA_E2E_DROP_DB_ON_EXIT:-0}" == "1" ]]; then
    if [[ "$MIX_ENV" == "test" ]]; then
      PARRHESIA_TEST_HTTP_PORT=0 mix ecto.drop --quiet --force || true
    else
      mix ecto.drop --quiet --force || true
    fi
  fi
}

trap cleanup EXIT INT TERM

port_in_use() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :${port} )" | tail -n +2 | grep -q .
    return
  fi

  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi

  echo "Neither ss nor lsof is available for checking whether port ${port} is already in use." >&2
  exit 1
}

if port_in_use "$TEST_HTTP_PORT"; then
  echo "Port ${TEST_HTTP_PORT} is already in use. Set ${PORT_ENV_VAR} to a free port." >&2
  exit 1
fi

if [[ "$MIX_ENV" == "test" ]]; then
  PARRHESIA_TEST_HTTP_PORT="$TEST_HTTP_PORT" mix run --no-halt >"$SERVER_LOG" 2>&1 &
else
  PORT="$TEST_HTTP_PORT" mix run --no-halt >"$SERVER_LOG" 2>&1 &
fi
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

if [[ "$MIX_ENV" == "test" ]]; then
  PARRHESIA_TEST_HTTP_PORT=0 "$@"
else
  "$@"
fi
