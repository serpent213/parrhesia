#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

RUN_ID="${PARRHESIA_NODE_SYNC_E2E_RUN_ID:-docker-$(date +%s)}"
RESOURCE="${PARRHESIA_NODE_SYNC_E2E_RESOURCE:-tribes.accounts.user}"
RUNNER_MIX_ENV="${PARRHESIA_NODE_SYNC_E2E_RUNNER_MIX_ENV:-test}"
TMP_DIR="${PARRHESIA_NODE_SYNC_E2E_TMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/parrhesia-node-sync-docker-e2e.XXXXXX")}"
STATE_FILE="$TMP_DIR/state.json"
COMPOSE_FILE="$ROOT_DIR/compose.node-sync-e2e.yaml"
COMPOSE_PROJECT_SUFFIX="$(basename "$TMP_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '_')"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-parrhesia-node-sync-e2e-${COMPOSE_PROJECT_SUFFIX}}"
export COMPOSE_PROJECT_NAME

NODE_A_HOST_PORT="${PARRHESIA_NODE_A_HOST_PORT:-45131}"
NODE_B_HOST_PORT="${PARRHESIA_NODE_B_HOST_PORT:-45132}"
NODE_A_HTTP_URL="http://127.0.0.1:${NODE_A_HOST_PORT}"
NODE_B_HTTP_URL="http://127.0.0.1:${NODE_B_HOST_PORT}"
NODE_A_WS_URL="ws://127.0.0.1:${NODE_A_HOST_PORT}/relay"
NODE_B_WS_URL="ws://127.0.0.1:${NODE_B_HOST_PORT}/relay"
NODE_A_INTERNAL_RELAY_URL="${PARRHESIA_NODE_A_INTERNAL_RELAY_URL:-ws://parrhesia-a:4413/relay}"
NODE_B_INTERNAL_RELAY_URL="${PARRHESIA_NODE_B_INTERNAL_RELAY_URL:-ws://parrhesia-b:4413/relay}"
printf -v PROTECTED_FILTERS_JSON '[{"kinds":[5000],"#r":["%s"]}]' "$RESOURCE"

cleanup() {
  docker compose -f "$COMPOSE_FILE" down -v >/dev/null 2>&1 || true

  if [[ "${PARRHESIA_NODE_SYNC_E2E_KEEP_TMP:-0}" != "1" ]]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT INT TERM

load_docker_image() {
  if [[ -n "${PARRHESIA_IMAGE:-}" ]]; then
    return
  fi

  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "PARRHESIA_IMAGE must be set on non-Linux hosts; .#dockerImage is Linux-only." >&2
    exit 1
  fi

  local image_path
  image_path="$(nix build .#dockerImage --print-out-paths --no-link)"
  docker load <"$image_path" >/dev/null
  export PARRHESIA_IMAGE="parrhesia:latest"
}

wait_for_health() {
  local url="$1"
  local label="$2"

  for _ in {1..150}; do
    if curl -fsS "$url/health" >/dev/null 2>&1; then
      return
    fi

    sleep 0.2
  done

  echo "${label} did not become healthy at ${url}" >&2
  exit 1
}

run_runner() {
  ERL_LIBS="_build/${RUNNER_MIX_ENV}/lib" \
    elixir scripts/node_sync_e2e.exs "$@" --state-file "$STATE_FILE"
}

load_docker_image
MIX_ENV="$RUNNER_MIX_ENV" mix compile >/dev/null

export PARRHESIA_NODE_A_HOST_PORT
export PARRHESIA_NODE_B_HOST_PORT
export PARRHESIA_NODE_A_RELAY_URL="$NODE_A_INTERNAL_RELAY_URL"
export PARRHESIA_NODE_B_RELAY_URL="$NODE_B_INTERNAL_RELAY_URL"
export PARRHESIA_ACL_PROTECTED_FILTERS="$PROTECTED_FILTERS_JSON"

docker compose -f "$COMPOSE_FILE" up -d db-a db-b
docker compose -f "$COMPOSE_FILE" run -T --rm migrate-a
docker compose -f "$COMPOSE_FILE" run -T --rm migrate-b
docker compose -f "$COMPOSE_FILE" up -d parrhesia-a parrhesia-b

wait_for_health "$NODE_A_HTTP_URL" "Node A"
wait_for_health "$NODE_B_HTTP_URL" "Node B"

export PARRHESIA_NODE_SYNC_E2E_RUN_ID="$RUN_ID"
export PARRHESIA_NODE_SYNC_E2E_RESOURCE="$RESOURCE"
export PARRHESIA_NODE_A_HTTP_URL="$NODE_A_HTTP_URL"
export PARRHESIA_NODE_B_HTTP_URL="$NODE_B_HTTP_URL"
export PARRHESIA_NODE_A_WS_URL="$NODE_A_WS_URL"
export PARRHESIA_NODE_B_WS_URL="$NODE_B_WS_URL"
export PARRHESIA_NODE_A_RELAY_AUTH_URL="$NODE_A_WS_URL"
export PARRHESIA_NODE_B_RELAY_AUTH_URL="$NODE_B_WS_URL"
export PARRHESIA_NODE_A_SYNC_URL="$NODE_A_INTERNAL_RELAY_URL"
export PARRHESIA_NODE_B_SYNC_URL="$NODE_B_INTERNAL_RELAY_URL"

run_runner bootstrap

docker compose -f "$COMPOSE_FILE" stop parrhesia-b
run_runner publish-resume
docker compose -f "$COMPOSE_FILE" up -d parrhesia-b

wait_for_health "$NODE_B_HTTP_URL" "Node B"
run_runner verify-resume

printf 'node-sync-e2e docker run completed\nstate: %s\n' "$STATE_FILE"
