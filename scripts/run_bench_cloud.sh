#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_bench_cloud.sh [options] [-- extra args for cloud_bench_orchestrate.mjs]

Friendly wrapper around scripts/cloud_bench_orchestrate.mjs.

Defaults (override via env or flags):
  datacenter: fsn1-dc14
  server/client type: cx23
  clients: 3
  runs: 3
  targets: parrhesia-pg,parrhesia-memory,strfry,nostr-rs-relay

Flags:
  --quick                     Quick smoke profile (1 run, 1 client, lower load)
  --clients N                 Override client count
  --runs N                    Override run count
  --targets CSV               Override targets
  --datacenter NAME           Override datacenter
  --server-type NAME          Override server type
  --client-type NAME          Override client type
  --image IMAGE               Use remote Parrhesia image (e.g. ghcr.io/...)
  --git-ref REF               Build Parrhesia image from git ref (default: HEAD)
  --keep                      Keep cloud resources after run
  -h, --help

Environment overrides:
  PARRHESIA_CLOUD_DATACENTER      (default: fsn1-dc14)
  PARRHESIA_CLOUD_SERVER_TYPE     (default: cx23)
  PARRHESIA_CLOUD_CLIENT_TYPE     (default: cx23)
  PARRHESIA_CLOUD_CLIENTS         (default: 3)
  PARRHESIA_BENCH_RUNS            (default: 3)
  PARRHESIA_CLOUD_TARGETS         (default: all 4)
  PARRHESIA_CLOUD_PARRHESIA_IMAGE (optional)
  PARRHESIA_CLOUD_GIT_REF         (default: HEAD)

Bench knobs (forwarded):
  PARRHESIA_BENCH_CONNECT_COUNT
  PARRHESIA_BENCH_CONNECT_RATE
  PARRHESIA_BENCH_ECHO_COUNT
  PARRHESIA_BENCH_ECHO_RATE
  PARRHESIA_BENCH_ECHO_SIZE
  PARRHESIA_BENCH_EVENT_COUNT
  PARRHESIA_BENCH_EVENT_RATE
  PARRHESIA_BENCH_REQ_COUNT
  PARRHESIA_BENCH_REQ_RATE
  PARRHESIA_BENCH_REQ_LIMIT
  PARRHESIA_BENCH_KEEPALIVE_SECONDS

Examples:
  # Default full cloud run
  ./scripts/run_bench_cloud.sh

  # Quick smoke
  ./scripts/run_bench_cloud.sh --quick

  # Use a GHCR image
  ./scripts/run_bench_cloud.sh --image ghcr.io/owner/parrhesia:latest
EOF
}

DATACENTER="${PARRHESIA_CLOUD_DATACENTER:-fsn1-dc14}"
SERVER_TYPE="${PARRHESIA_CLOUD_SERVER_TYPE:-cx23}"
CLIENT_TYPE="${PARRHESIA_CLOUD_CLIENT_TYPE:-cx23}"
CLIENTS="${PARRHESIA_CLOUD_CLIENTS:-3}"
RUNS="${PARRHESIA_BENCH_RUNS:-3}"
TARGETS="${PARRHESIA_CLOUD_TARGETS:-parrhesia-pg,parrhesia-memory,strfry,nostr-rs-relay}"
PARRHESIA_IMAGE="${PARRHESIA_CLOUD_PARRHESIA_IMAGE:-}"
GIT_REF="${PARRHESIA_CLOUD_GIT_REF:-HEAD}"
KEEP=0
QUICK=0

EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --quick)
      QUICK=1
      shift
      ;;
    --clients)
      CLIENTS="$2"
      shift 2
      ;;
    --runs)
      RUNS="$2"
      shift 2
      ;;
    --targets)
      TARGETS="$2"
      shift 2
      ;;
    --datacenter)
      DATACENTER="$2"
      shift 2
      ;;
    --server-type)
      SERVER_TYPE="$2"
      shift 2
      ;;
    --client-type)
      CLIENT_TYPE="$2"
      shift 2
      ;;
    --image)
      PARRHESIA_IMAGE="$2"
      shift 2
      ;;
    --git-ref)
      GIT_REF="$2"
      shift 2
      ;;
    --keep)
      KEEP=1
      shift
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$QUICK" == "1" ]]; then
  RUNS=1
  CLIENTS=1
  : "${PARRHESIA_BENCH_CONNECT_COUNT:=20}"
  : "${PARRHESIA_BENCH_CONNECT_RATE:=20}"
  : "${PARRHESIA_BENCH_ECHO_COUNT:=20}"
  : "${PARRHESIA_BENCH_ECHO_RATE:=20}"
  : "${PARRHESIA_BENCH_ECHO_SIZE:=512}"
  : "${PARRHESIA_BENCH_EVENT_COUNT:=20}"
  : "${PARRHESIA_BENCH_EVENT_RATE:=20}"
  : "${PARRHESIA_BENCH_REQ_COUNT:=20}"
  : "${PARRHESIA_BENCH_REQ_RATE:=20}"
  : "${PARRHESIA_BENCH_REQ_LIMIT:=10}"
  : "${PARRHESIA_BENCH_KEEPALIVE_SECONDS:=2}"
fi

CMD=(
  node scripts/cloud_bench_orchestrate.mjs
  --datacenter "$DATACENTER"
  --server-type "$SERVER_TYPE"
  --client-type "$CLIENT_TYPE"
  --clients "$CLIENTS"
  --runs "$RUNS"
  --targets "$TARGETS"
)

if [[ -n "$PARRHESIA_IMAGE" ]]; then
  CMD+=(--parrhesia-image "$PARRHESIA_IMAGE")
else
  CMD+=(--git-ref "$GIT_REF")
fi

if [[ "$KEEP" == "1" ]]; then
  CMD+=(--keep)
fi

# Forward bench knob envs if set
for kv in \
  PARRHESIA_BENCH_CONNECT_COUNT \
  PARRHESIA_BENCH_CONNECT_RATE \
  PARRHESIA_BENCH_ECHO_COUNT \
  PARRHESIA_BENCH_ECHO_RATE \
  PARRHESIA_BENCH_ECHO_SIZE \
  PARRHESIA_BENCH_EVENT_COUNT \
  PARRHESIA_BENCH_EVENT_RATE \
  PARRHESIA_BENCH_REQ_COUNT \
  PARRHESIA_BENCH_REQ_RATE \
  PARRHESIA_BENCH_REQ_LIMIT \
  PARRHESIA_BENCH_KEEPALIVE_SECONDS
 do
  if [[ -n "${!kv:-}" ]]; then
    flag="--$(echo "$kv" | tr '[:upper:]' '[:lower:]' | sed -E 's/^parrhesia_bench_//' | tr '_' '-')"
    CMD+=("$flag" "${!kv}")
  fi
 done

CMD+=("${EXTRA_ARGS[@]}")

printf 'Running cloud bench:\n  %q' "${CMD[0]}"
for ((i=1; i<${#CMD[@]}; i++)); do
  printf ' %q' "${CMD[$i]}"
done
printf '\n\n'

"${CMD[@]}"
