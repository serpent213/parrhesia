#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_bench_cloud.sh [options] [-- extra args for cloud_bench_orchestrate.mjs]

Friendly wrapper around scripts/cloud_bench_orchestrate.mjs.

The orchestrator checks datacenter availability for your server/client types,
shows estimated 30m pricing, and asks for selection/confirmation in interactive terminals.

Defaults:
  Inherited from scripts/cloud_bench_orchestrate.mjs.
  This wrapper only passes explicit overrides (flags/env), plus --quick profile overrides.

Flags:
  --quick                     Quick smoke profile (cx23/cx23, 1 run, 1 client, lower load)
  --clients N                 Override client count
  --runs N                    Override run count
  --targets CSV               Override targets
  --datacenter NAME           Override datacenter
  --server-type NAME          Override server type
  --client-type NAME          Override client type
  --image IMAGE               Use remote Parrhesia image (e.g. ghcr.io/...)
  --git-ref REF               Build Parrhesia image from git ref (default: HEAD)
  --nostream-repo URL         Override nostream repo (default: Cameri/nostream)
  --nostream-ref REF          Override nostream ref (default: main)
  --haven-image IMAGE         Override Haven image
  --threads N                 Override nostr-bench worker threads (0 = auto)
  --keep                      Keep cloud resources after run
  -h, --help

Environment overrides (all optional):
  PARRHESIA_CLOUD_DATACENTER
  PARRHESIA_CLOUD_SERVER_TYPE
  PARRHESIA_CLOUD_CLIENT_TYPE
  PARRHESIA_CLOUD_CLIENTS
  PARRHESIA_BENCH_RUNS
  PARRHESIA_CLOUD_TARGETS
  PARRHESIA_CLOUD_PARRHESIA_IMAGE
  PARRHESIA_CLOUD_GIT_REF
  PARRHESIA_CLOUD_NOSTREAM_REPO
  PARRHESIA_CLOUD_NOSTREAM_REF
  PARRHESIA_CLOUD_HAVEN_IMAGE

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
  PARRHESIA_BENCH_THREADS

Examples:
  # Default full cloud run
  ./scripts/run_bench_cloud.sh

  # Quick smoke
  ./scripts/run_bench_cloud.sh --quick

  # Use a GHCR image
  ./scripts/run_bench_cloud.sh --image ghcr.io/owner/parrhesia:latest
EOF
}

DATACENTER="${PARRHESIA_CLOUD_DATACENTER:-}"
SERVER_TYPE="${PARRHESIA_CLOUD_SERVER_TYPE:-}"
CLIENT_TYPE="${PARRHESIA_CLOUD_CLIENT_TYPE:-}"
CLIENTS="${PARRHESIA_CLOUD_CLIENTS:-}"
RUNS="${PARRHESIA_BENCH_RUNS:-}"
TARGETS="${PARRHESIA_CLOUD_TARGETS:-}"
PARRHESIA_IMAGE="${PARRHESIA_CLOUD_PARRHESIA_IMAGE:-}"
GIT_REF="${PARRHESIA_CLOUD_GIT_REF:-}"
NOSTREAM_REPO="${PARRHESIA_CLOUD_NOSTREAM_REPO:-}"
NOSTREAM_REF="${PARRHESIA_CLOUD_NOSTREAM_REF:-}"
HAVEN_IMAGE="${PARRHESIA_CLOUD_HAVEN_IMAGE:-}"
THREADS="${PARRHESIA_BENCH_THREADS:-}"
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
    --nostream-repo)
      NOSTREAM_REPO="$2"
      shift 2
      ;;
    --nostream-ref)
      NOSTREAM_REF="$2"
      shift 2
      ;;
    --haven-image)
      HAVEN_IMAGE="$2"
      shift 2
      ;;
    --threads)
      THREADS="$2"
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
  : "${SERVER_TYPE:=cx23}"
  : "${CLIENT_TYPE:=cx23}"
  : "${RUNS:=1}"
  : "${CLIENTS:=1}"

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

CMD=(node scripts/cloud_bench_orchestrate.mjs)

if [[ -n "$DATACENTER" ]]; then
  CMD+=(--datacenter "$DATACENTER")
fi
if [[ -n "$SERVER_TYPE" ]]; then
  CMD+=(--server-type "$SERVER_TYPE")
fi
if [[ -n "$CLIENT_TYPE" ]]; then
  CMD+=(--client-type "$CLIENT_TYPE")
fi
if [[ -n "$CLIENTS" ]]; then
  CMD+=(--clients "$CLIENTS")
fi
if [[ -n "$RUNS" ]]; then
  CMD+=(--runs "$RUNS")
fi
if [[ -n "$TARGETS" ]]; then
  CMD+=(--targets "$TARGETS")
fi
if [[ -n "$NOSTREAM_REPO" ]]; then
  CMD+=(--nostream-repo "$NOSTREAM_REPO")
fi
if [[ -n "$NOSTREAM_REF" ]]; then
  CMD+=(--nostream-ref "$NOSTREAM_REF")
fi
if [[ -n "$HAVEN_IMAGE" ]]; then
  CMD+=(--haven-image "$HAVEN_IMAGE")
fi
if [[ -n "$THREADS" ]]; then
  CMD+=(--threads "$THREADS")
fi

if [[ -n "$PARRHESIA_IMAGE" ]]; then
  CMD+=(--parrhesia-image "$PARRHESIA_IMAGE")
elif [[ -n "$GIT_REF" ]]; then
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
