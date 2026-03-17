#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUN_ID="${PARRHESIA_NODE_SYNC_E2E_RUN_ID:-local-$(date +%s)}"
RESOURCE="${PARRHESIA_NODE_SYNC_E2E_RESOURCE:-tribes.accounts.user}"
RUNNER_MIX_ENV="${PARRHESIA_NODE_SYNC_E2E_RUNNER_MIX_ENV:-test}"
TMP_DIR="${PARRHESIA_NODE_SYNC_E2E_TMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/parrhesia-node-sync-e2e.XXXXXX")}"
STATE_FILE="$TMP_DIR/state.json"
LOG_DIR="$TMP_DIR/logs"
mkdir -p "$LOG_DIR"

SUFFIX="$(basename "$TMP_DIR" | tr -c 'a-zA-Z0-9' '_')"
DB_NAME_A="${PARRHESIA_NODE_SYNC_E2E_DB_A:-parrhesia_node_sync_a_${SUFFIX}}"
DB_NAME_B="${PARRHESIA_NODE_SYNC_E2E_DB_B:-parrhesia_node_sync_b_${SUFFIX}}"

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

  echo "Neither ss nor lsof is available for checking port usage." >&2
  exit 1
}

pick_port() {
  local port

  while true; do
    port="$(( (RANDOM % 10000) + 40000 ))"

    if ! port_in_use "$port"; then
      printf '%s\n' "$port"
      return
    fi
  done
}

NODE_A_PORT="${PARRHESIA_NODE_A_PORT:-$(pick_port)}"
NODE_B_PORT="${PARRHESIA_NODE_B_PORT:-$(pick_port)}"

if [[ "$NODE_A_PORT" == "$NODE_B_PORT" ]]; then
  echo "Node A and Node B ports must differ." >&2
  exit 1
fi

database_url_for() {
  local database_name="$1"
  local pg_user="${PGUSER:-${USER:-agent}}"
  local pg_host="${PGHOST:-localhost}"
  local pg_port="${PGPORT:-5432}"

  if [[ "$pg_host" == /* ]]; then
    if [[ -n "${PGPASSWORD:-}" ]]; then
      printf 'ecto://%s:%s@localhost/%s?socket_dir=%s&port=%s\n' \
        "$pg_user" "$PGPASSWORD" "$database_name" "$pg_host" "$pg_port"
    else
      printf 'ecto://%s@localhost/%s?socket_dir=%s&port=%s\n' \
        "$pg_user" "$database_name" "$pg_host" "$pg_port"
    fi
  else
    if [[ -n "${PGPASSWORD:-}" ]]; then
      printf 'ecto://%s:%s@%s:%s/%s\n' \
        "$pg_user" "$PGPASSWORD" "$pg_host" "$pg_port" "$database_name"
    else
      printf 'ecto://%s@%s:%s/%s\n' \
        "$pg_user" "$pg_host" "$pg_port" "$database_name"
    fi
  fi
}

DATABASE_URL_A="$(database_url_for "$DB_NAME_A")"
DATABASE_URL_B="$(database_url_for "$DB_NAME_B")"
printf -v PROTECTED_FILTERS_JSON '[{"kinds":[5000],"#r":["%s"]}]' "$RESOURCE"

cleanup() {
  if [[ -n "${NODE_A_PID:-}" ]] && kill -0 "$NODE_A_PID" 2>/dev/null; then
    kill "$NODE_A_PID" 2>/dev/null || true
    wait "$NODE_A_PID" 2>/dev/null || true
  fi

  if [[ -n "${NODE_B_PID:-}" ]] && kill -0 "$NODE_B_PID" 2>/dev/null; then
    kill "$NODE_B_PID" 2>/dev/null || true
    wait "$NODE_B_PID" 2>/dev/null || true
  fi

  if [[ "${PARRHESIA_NODE_SYNC_E2E_DROP_DB_ON_EXIT:-1}" == "1" ]]; then
    DATABASE_URL="$DATABASE_URL_A" MIX_ENV=prod mix ecto.drop --quiet --force || true
    DATABASE_URL="$DATABASE_URL_B" MIX_ENV=prod mix ecto.drop --quiet --force || true
  fi

  if [[ "${PARRHESIA_NODE_SYNC_E2E_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT INT TERM

wait_for_health() {
  local port="$1"
  local label="$2"

  for _ in {1..150}; do
    if curl -fsS "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      return
    fi

    sleep 0.1
  done

  echo "${label} did not become healthy on port ${port}" >&2
  exit 1
}

setup_database() {
  local database_url="$1"

  DATABASE_URL="$database_url" MIX_ENV=prod mix ecto.drop --quiet --force || true
  DATABASE_URL="$database_url" MIX_ENV=prod mix ecto.create --quiet
  DATABASE_URL="$database_url" MIX_ENV=prod mix ecto.migrate --quiet
}

start_node() {
  local node_name="$1"
  local port="$2"
  local database_url="$3"
  local relay_url="$4"
  local identity_path="$5"
  local sync_path="$6"
  local log_path="$7"

  DATABASE_URL="$database_url" \
    PORT="$port" \
    PARRHESIA_RELAY_URL="$relay_url" \
    PARRHESIA_ACL_PROTECTED_FILTERS="$PROTECTED_FILTERS_JSON" \
    PARRHESIA_IDENTITY_PATH="$identity_path" \
    PARRHESIA_SYNC_PATH="$sync_path" \
    MIX_ENV=prod \
    mix run --no-compile --no-halt >"$log_path" 2>&1 &

  if [[ "$node_name" == "a" ]]; then
    NODE_A_PID=$!
  else
    NODE_B_PID=$!
  fi
}

run_runner() {
  ERL_LIBS="_build/${RUNNER_MIX_ENV}/lib" \
    elixir scripts/node_sync_e2e.exs "$@" --state-file "$STATE_FILE"
}

export DATABASE_URL="$DATABASE_URL_A"
MIX_ENV=prod mix compile
MIX_ENV="$RUNNER_MIX_ENV" mix compile >/dev/null

setup_database "$DATABASE_URL_A"
setup_database "$DATABASE_URL_B"

NODE_A_HTTP_URL="http://127.0.0.1:${NODE_A_PORT}"
NODE_B_HTTP_URL="http://127.0.0.1:${NODE_B_PORT}"
NODE_A_WS_URL="ws://127.0.0.1:${NODE_A_PORT}/relay"
NODE_B_WS_URL="ws://127.0.0.1:${NODE_B_PORT}/relay"

start_node \
  a \
  "$NODE_A_PORT" \
  "$DATABASE_URL_A" \
  "$NODE_A_WS_URL" \
  "$TMP_DIR/node-a-identity.json" \
  "$TMP_DIR/node-a-sync.json" \
  "$LOG_DIR/node-a.log"

start_node \
  b \
  "$NODE_B_PORT" \
  "$DATABASE_URL_B" \
  "$NODE_B_WS_URL" \
  "$TMP_DIR/node-b-identity.json" \
  "$TMP_DIR/node-b-sync.json" \
  "$LOG_DIR/node-b.log"

wait_for_health "$NODE_A_PORT" "Node A"
wait_for_health "$NODE_B_PORT" "Node B"

export PARRHESIA_NODE_SYNC_E2E_RUN_ID="$RUN_ID"
export PARRHESIA_NODE_SYNC_E2E_RESOURCE="$RESOURCE"
export PARRHESIA_NODE_A_HTTP_URL="$NODE_A_HTTP_URL"
export PARRHESIA_NODE_B_HTTP_URL="$NODE_B_HTTP_URL"
export PARRHESIA_NODE_A_WS_URL="$NODE_A_WS_URL"
export PARRHESIA_NODE_B_WS_URL="$NODE_B_WS_URL"
export PARRHESIA_NODE_A_RELAY_AUTH_URL="$NODE_A_WS_URL"
export PARRHESIA_NODE_B_RELAY_AUTH_URL="$NODE_B_WS_URL"
export PARRHESIA_NODE_A_SYNC_URL="$NODE_A_WS_URL"
export PARRHESIA_NODE_B_SYNC_URL="$NODE_B_WS_URL"

run_runner bootstrap

kill "$NODE_B_PID"
wait "$NODE_B_PID" 2>/dev/null || true
unset NODE_B_PID

run_runner publish-resume

start_node \
  b \
  "$NODE_B_PORT" \
  "$DATABASE_URL_B" \
  "$NODE_B_WS_URL" \
  "$TMP_DIR/node-b-identity.json" \
  "$TMP_DIR/node-b-sync.json" \
  "$LOG_DIR/node-b.log"

wait_for_health "$NODE_B_PORT" "Node B"
run_runner verify-resume

printf 'node-sync-e2e local run completed\nlogs: %s\n' "$LOG_DIR"
