#!/usr/bin/env bash
set -euo pipefail

PARRHESIA_IMAGE="${PARRHESIA_IMAGE:-parrhesia:latest}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18}"
STRFRY_IMAGE="${STRFRY_IMAGE:-ghcr.io/hoytech/strfry:latest}"
NOSTR_RS_IMAGE="${NOSTR_RS_IMAGE:-scsibug/nostr-rs-relay:latest}"
NOSTREAM_REPO="${NOSTREAM_REPO:-https://github.com/Cameri/nostream.git}"
NOSTREAM_REF="${NOSTREAM_REF:-main}"
NOSTREAM_REDIS_IMAGE="${NOSTREAM_REDIS_IMAGE:-redis:7.0.5-alpine3.16}"
HAVEN_IMAGE="${HAVEN_IMAGE:-holgerhatgarkeinenode/haven-docker:latest}"
HAVEN_RELAY_URL="${HAVEN_RELAY_URL:-127.0.0.1:3355}"

NOSTREAM_SECRET="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
HAVEN_OWNER_NPUB="npub1utx00neqgqln72j22kej3ux7803c2k986henvvha4thuwfkper4s7r50e8"

cleanup_containers() {
  docker rm -f parrhesia pg strfry nostr-rs nostream nostream-db nostream-cache haven >/dev/null 2>&1 || true
}

ensure_benchnet() {
  docker network create benchnet >/dev/null 2>&1 || true
}

wait_http() {
  local url="$1"
  local timeout="${2:-60}"
  local log_container="${3:-}"

  for _ in $(seq 1 "$timeout"); do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  if [[ -n "$log_container" ]]; then
    docker logs --tail 200 "$log_container" >&2 || true
  fi

  echo "Timed out waiting for HTTP endpoint: $url" >&2
  return 1
}

wait_pg() {
  local timeout="${1:-90}"
  for _ in $(seq 1 "$timeout"); do
    if docker exec pg pg_isready -U parrhesia -d parrhesia >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs --tail 200 pg >&2 || true
  echo "Timed out waiting for Postgres" >&2
  return 1
}

wait_nostream_pg() {
  local timeout="${1:-90}"
  for _ in $(seq 1 "$timeout"); do
    if docker exec nostream-db pg_isready -U nostr_ts_relay -d nostr_ts_relay >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs --tail 200 nostream-db >&2 || true
  echo "Timed out waiting for nostream Postgres" >&2
  return 1
}

wait_nostream_redis() {
  local timeout="${1:-60}"
  for _ in $(seq 1 "$timeout"); do
    if docker exec nostream-cache redis-cli -a nostr_ts_relay ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs --tail 200 nostream-cache >&2 || true
  echo "Timed out waiting for nostream Redis" >&2
  return 1
}

wait_port() {
  local port="$1"
  local timeout="${2:-60}"
  local log_container="${3:-}"

  for _ in $(seq 1 "$timeout"); do
    if ss -ltn | grep -q ":${port} "; then
      return 0
    fi
    sleep 1
  done

  if [[ -n "$log_container" ]]; then
    docker logs --tail 200 "$log_container" >&2 || true
  fi

  echo "Timed out waiting for port: $port" >&2
  return 1
}

clamp() {
  local value="$1"
  local min="$2"
  local max="$3"

  if (( value < min )); then
    echo "$min"
  elif (( value > max )); then
    echo "$max"
  else
    echo "$value"
  fi
}

derive_resource_tuning() {
  local mem_kb
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"

  if [[ -z "$mem_kb" || ! "$mem_kb" =~ ^[0-9]+$ ]]; then
    mem_kb=4194304
  fi

  HOST_MEM_MB=$((mem_kb / 1024))
  HOST_CPU_CORES=$(nproc 2>/dev/null || echo 2)

  local computed_pg_max_connections=$((HOST_CPU_CORES * 50))
  local computed_pg_shared_buffers_mb=$((HOST_MEM_MB / 4))
  local computed_pg_effective_cache_size_mb=$((HOST_MEM_MB * 3 / 4))
  local computed_pg_maintenance_work_mem_mb=$((HOST_MEM_MB / 16))
  local computed_pg_max_wal_size_gb=$((HOST_MEM_MB / 8192))

  computed_pg_max_connections=$(clamp "$computed_pg_max_connections" 200 1000)
  computed_pg_shared_buffers_mb=$(clamp "$computed_pg_shared_buffers_mb" 512 32768)
  computed_pg_effective_cache_size_mb=$(clamp "$computed_pg_effective_cache_size_mb" 1024 98304)
  computed_pg_maintenance_work_mem_mb=$(clamp "$computed_pg_maintenance_work_mem_mb" 256 2048)
  computed_pg_max_wal_size_gb=$(clamp "$computed_pg_max_wal_size_gb" 4 64)

  local computed_pg_min_wal_size_gb=$((computed_pg_max_wal_size_gb / 4))
  computed_pg_min_wal_size_gb=$(clamp "$computed_pg_min_wal_size_gb" 1 16)

  local computed_pg_work_mem_mb=$(((HOST_MEM_MB - computed_pg_shared_buffers_mb) / (computed_pg_max_connections * 3)))
  computed_pg_work_mem_mb=$(clamp "$computed_pg_work_mem_mb" 4 128)

  local computed_parrhesia_pool_size=$((HOST_CPU_CORES * 8))
  computed_parrhesia_pool_size=$(clamp "$computed_parrhesia_pool_size" 20 200)

  local computed_nostream_db_min_pool_size=$((HOST_CPU_CORES * 4))
  computed_nostream_db_min_pool_size=$(clamp "$computed_nostream_db_min_pool_size" 16 128)

  local computed_nostream_db_max_pool_size=$((HOST_CPU_CORES * 16))
  computed_nostream_db_max_pool_size=$(clamp "$computed_nostream_db_max_pool_size" 64 512)

  if (( computed_nostream_db_max_pool_size < computed_nostream_db_min_pool_size )); then
    computed_nostream_db_max_pool_size="$computed_nostream_db_min_pool_size"
  fi

  local computed_redis_maxmemory_mb=$((HOST_MEM_MB / 3))
  computed_redis_maxmemory_mb=$(clamp "$computed_redis_maxmemory_mb" 256 65536)

  PG_MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-$computed_pg_max_connections}"
  PG_SHARED_BUFFERS_MB="${PG_SHARED_BUFFERS_MB:-$computed_pg_shared_buffers_mb}"
  PG_EFFECTIVE_CACHE_SIZE_MB="${PG_EFFECTIVE_CACHE_SIZE_MB:-$computed_pg_effective_cache_size_mb}"
  PG_MAINTENANCE_WORK_MEM_MB="${PG_MAINTENANCE_WORK_MEM_MB:-$computed_pg_maintenance_work_mem_mb}"
  PG_WORK_MEM_MB="${PG_WORK_MEM_MB:-$computed_pg_work_mem_mb}"
  PG_MIN_WAL_SIZE_GB="${PG_MIN_WAL_SIZE_GB:-$computed_pg_min_wal_size_gb}"
  PG_MAX_WAL_SIZE_GB="${PG_MAX_WAL_SIZE_GB:-$computed_pg_max_wal_size_gb}"
  PARRHESIA_POOL_SIZE="${PARRHESIA_POOL_SIZE:-$computed_parrhesia_pool_size}"
  NOSTREAM_DB_MIN_POOL_SIZE="${NOSTREAM_DB_MIN_POOL_SIZE:-$computed_nostream_db_min_pool_size}"
  NOSTREAM_DB_MAX_POOL_SIZE="${NOSTREAM_DB_MAX_POOL_SIZE:-$computed_nostream_db_max_pool_size}"
  REDIS_MAXMEMORY_MB="${REDIS_MAXMEMORY_MB:-$computed_redis_maxmemory_mb}"

  PG_TUNING_ARGS=(
    -c max_connections="$PG_MAX_CONNECTIONS"
    -c shared_buffers="${PG_SHARED_BUFFERS_MB}MB"
    -c effective_cache_size="${PG_EFFECTIVE_CACHE_SIZE_MB}MB"
    -c maintenance_work_mem="${PG_MAINTENANCE_WORK_MEM_MB}MB"
    -c work_mem="${PG_WORK_MEM_MB}MB"
    -c min_wal_size="${PG_MIN_WAL_SIZE_GB}GB"
    -c max_wal_size="${PG_MAX_WAL_SIZE_GB}GB"
    -c checkpoint_completion_target=0.9
    -c wal_compression=on
  )

  echo "[server] resource profile: mem_mb=$HOST_MEM_MB cpu_cores=$HOST_CPU_CORES"
  echo "[server] postgres tuning: max_connections=$PG_MAX_CONNECTIONS shared_buffers=${PG_SHARED_BUFFERS_MB}MB effective_cache_size=${PG_EFFECTIVE_CACHE_SIZE_MB}MB work_mem=${PG_WORK_MEM_MB}MB"
  echo "[server] app tuning: parrhesia_pool=$PARRHESIA_POOL_SIZE nostream_db_pool=${NOSTREAM_DB_MIN_POOL_SIZE}-${NOSTREAM_DB_MAX_POOL_SIZE} redis_maxmemory=${REDIS_MAXMEMORY_MB}MB"
}

tune_nostream_settings() {
  local settings_path="/root/nostream-config/settings.yaml"

  if [[ ! -f "$settings_path" ]]; then
    return 1
  fi

  python3 - "$settings_path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

def replace_after(marker: str, old: str, new: str) -> None:
    global text
    marker_idx = text.find(marker)
    if marker_idx == -1:
        return

    old_idx = text.find(old, marker_idx)
    if old_idx == -1:
        return

    text = text[:old_idx] + new + text[old_idx + len(old):]

text = text.replace("  remoteIpHeader: x-forwarded-for", "  # remoteIpHeader disabled for direct bench traffic")

text = text.replace(
    "  connection:\\n    rateLimits:\\n      - period: 1000\\n        rate: 12\\n      - period: 60000\\n        rate: 48",
    "  connection:\\n    rateLimits:\\n      - period: 1000\\n        rate: 300\\n      - period: 60000\\n        rate: 12000",
)

replace_after("description: 30 admission checks/min or 1 check every 2 seconds", "rate: 30", "rate: 3000")
replace_after("description: 6 events/min for event kinds 0, 3, 40 and 41", "rate: 6", "rate: 600")
replace_after("description: 12 events/min for event kinds 1, 2, 4 and 42", "rate: 12", "rate: 1200")
replace_after("description: 30 events/min for event kind ranges 5-7 and 43-49", "rate: 30", "rate: 3000")
replace_after("description: 24 events/min for replaceable events and parameterized replaceable", "rate: 24", "rate: 2400")
replace_after("description: 60 events/min for ephemeral events", "rate: 60", "rate: 6000")
replace_after("description: 720 events/hour for all events", "rate: 720", "rate: 72000")
replace_after("description: 240 raw messages/min", "rate: 240", "rate: 120000")

text = text.replace("maxSubscriptions: 10", "maxSubscriptions: 512")
text = text.replace("maxFilters: 10", "maxFilters: 128")
text = text.replace("maxFilterValues: 2500", "maxFilterValues: 100000")
text = text.replace("maxLimit: 5000", "maxLimit: 50000")

path.write_text(text, encoding="utf-8")
PY
}

common_parrhesia_env=()
common_parrhesia_env+=( -e PARRHESIA_ENABLE_EXPIRATION_WORKER=0 )
common_parrhesia_env+=( -e PARRHESIA_ENABLE_PARTITION_RETENTION_WORKER=0 )
common_parrhesia_env+=( -e PARRHESIA_PUBLIC_MAX_CONNECTIONS=infinity )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_FRAME_BYTES=16777216 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_EVENT_BYTES=4194304 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_FILTERS_PER_REQ=1024 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_FILTER_LIMIT=100000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_TAGS_PER_EVENT=4096 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_TAG_VALUES_PER_FILTER=4096 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_IP_MAX_EVENT_INGEST_PER_WINDOW=1000000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_RELAY_MAX_EVENT_INGEST_PER_WINDOW=1000000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_SUBSCRIPTIONS_PER_CONNECTION=4096 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_EVENT_FUTURE_SKEW_SECONDS=31536000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_EVENT_INGEST_PER_WINDOW=1000000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_AUTH_MAX_AGE_SECONDS=31536000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_OUTBOUND_QUEUE=65536 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_OUTBOUND_DRAIN_BATCH_SIZE=4096 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_NEGENTROPY_PAYLOAD_BYTES=1048576 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_NEGENTROPY_SESSIONS_PER_CONNECTION=256 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_NEGENTROPY_TOTAL_SESSIONS=100000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_NEGENTROPY_ITEMS_PER_SESSION=1000000 )

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  echo "usage: cloud-bench-server.sh <start-*|wipe-data-*|cleanup>" >&2
  exit 1
fi

derive_resource_tuning

case "$cmd" in
  start-parrhesia-pg)
    cleanup_containers
    docker network create benchnet >/dev/null 2>&1 || true

    docker run -d --name pg --network benchnet \
      --ulimit nofile=262144:262144 \
      -e POSTGRES_DB=parrhesia \
      -e POSTGRES_USER=parrhesia \
      -e POSTGRES_PASSWORD=parrhesia \
      "$POSTGRES_IMAGE" \
      "${PG_TUNING_ARGS[@]}" >/dev/null

    wait_pg 90

    docker run --rm --network benchnet \
      -e DATABASE_URL=ecto://parrhesia:parrhesia@pg:5432/parrhesia \
      "$PARRHESIA_IMAGE" \
      eval "Parrhesia.Release.migrate()"

    docker run -d --name parrhesia --network benchnet \
      --ulimit nofile=262144:262144 \
      -p 4413:4413 \
      -e DATABASE_URL=ecto://parrhesia:parrhesia@pg:5432/parrhesia \
      -e POOL_SIZE="$PARRHESIA_POOL_SIZE" \
      "${common_parrhesia_env[@]}" \
      "$PARRHESIA_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:4413/health" 120 parrhesia
    ;;

  start-parrhesia-memory)
    cleanup_containers

    docker run -d --name parrhesia \
      --ulimit nofile=262144:262144 \
      -p 4413:4413 \
      -e PARRHESIA_STORAGE_BACKEND=memory \
      -e PARRHESIA_MODERATION_CACHE_ENABLED=0 \
      "${common_parrhesia_env[@]}" \
      "$PARRHESIA_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:4413/health" 120 parrhesia
    ;;

  start-strfry)
    cleanup_containers

    rm -rf /root/strfry-data
    mkdir -p /root/strfry-data/strfry
    cat > /root/strfry.conf <<'EOF'
# generated by cloud bench script
db = "/data/strfry"
relay {
  bind = "0.0.0.0"
  port = 7777
  nofiles = 131072
}
EOF

    docker run -d --name strfry \
      --ulimit nofile=262144:262144 \
      -p 7777:7777 \
      -v /root/strfry.conf:/etc/strfry.conf:ro \
      -v /root/strfry-data:/data \
      "$STRFRY_IMAGE" \
      --config /etc/strfry.conf relay >/dev/null

    wait_port 7777 60 strfry
    ;;

  start-nostr-rs-relay)
    cleanup_containers

    cat > /root/nostr-rs.toml <<'EOF'
[database]
engine = "sqlite"

[network]
address = "0.0.0.0"
port = 8080
ping_interval = 120

[options]
reject_future_seconds = 1800

[limits]
messages_per_sec = 5000
subscriptions_per_min = 6000
max_event_bytes = 1048576
max_ws_message_bytes = 16777216
max_ws_frame_bytes = 16777216
broadcast_buffer = 65536
event_persist_buffer = 16384
limit_scrapers = false
EOF

    docker run -d --name nostr-rs \
      --ulimit nofile=262144:262144 \
      -p 8080:8080 \
      -v /root/nostr-rs.toml:/usr/src/app/config.toml:ro \
      "$NOSTR_RS_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:8080/" 60 nostr-rs
    ;;

  start-nostream)
    cleanup_containers
    ensure_benchnet

    if [[ ! -d /root/nostream-src/.git ]]; then
      git clone --depth 1 "$NOSTREAM_REPO" /root/nostream-src >/dev/null
    fi

    git -C /root/nostream-src fetch --depth 1 origin "$NOSTREAM_REF" >/dev/null 2>&1 || true
    if git -C /root/nostream-src rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
      git -C /root/nostream-src checkout --force FETCH_HEAD >/dev/null
    else
      git -C /root/nostream-src checkout --force "$NOSTREAM_REF" >/dev/null
    fi

    nostream_ref_marker=/root/nostream-src/.bench_ref
    should_build_nostream=0
    if ! docker image inspect nostream:bench >/dev/null 2>&1; then
      should_build_nostream=1
    elif [[ ! -f "$nostream_ref_marker" ]] || [[ "$(cat "$nostream_ref_marker")" != "$NOSTREAM_REF" ]]; then
      should_build_nostream=1
    fi

    if [[ "$should_build_nostream" == "1" ]]; then
      docker build -t nostream:bench /root/nostream-src >/dev/null
      printf '%s\n' "$NOSTREAM_REF" > "$nostream_ref_marker"
    fi

    mkdir -p /root/nostream-config
    if [[ ! -f /root/nostream-config/settings.yaml ]]; then
      cp /root/nostream-src/resources/default-settings.yaml /root/nostream-config/settings.yaml
    fi

    tune_nostream_settings

    docker run -d --name nostream-db --network benchnet \
      --ulimit nofile=262144:262144 \
      -e POSTGRES_DB=nostr_ts_relay \
      -e POSTGRES_USER=nostr_ts_relay \
      -e POSTGRES_PASSWORD=nostr_ts_relay \
      "$POSTGRES_IMAGE" \
      "${PG_TUNING_ARGS[@]}" >/dev/null

    wait_nostream_pg 90

    docker run -d --name nostream-cache --network benchnet \
      "$NOSTREAM_REDIS_IMAGE" \
      redis-server \
      --loglevel warning \
      --requirepass nostr_ts_relay \
      --maxmemory "${REDIS_MAXMEMORY_MB}mb" \
      --maxmemory-policy noeviction >/dev/null

    wait_nostream_redis 60

    docker run --rm --network benchnet \
      -e DB_HOST=nostream-db \
      -e DB_PORT=5432 \
      -e DB_USER=nostr_ts_relay \
      -e DB_PASSWORD=nostr_ts_relay \
      -e DB_NAME=nostr_ts_relay \
      -v /root/nostream-src/migrations:/code/migrations:ro \
      -v /root/nostream-src/knexfile.js:/code/knexfile.js:ro \
      node:18-alpine3.16 \
      sh -lc 'cd /code && npm install --no-save --quiet knex@2.4.0 pg@8.8.0 && npx knex migrate:latest'

    docker run -d --name nostream --network benchnet \
      --ulimit nofile=262144:262144 \
      -p 8008:8008 \
      -e SECRET="$NOSTREAM_SECRET" \
      -e RELAY_PORT=8008 \
      -e NOSTR_CONFIG_DIR=/home/node/.nostr \
      -e DB_HOST=nostream-db \
      -e DB_PORT=5432 \
      -e DB_USER=nostr_ts_relay \
      -e DB_PASSWORD=nostr_ts_relay \
      -e DB_NAME=nostr_ts_relay \
      -e DB_MIN_POOL_SIZE="$NOSTREAM_DB_MIN_POOL_SIZE" \
      -e DB_MAX_POOL_SIZE="$NOSTREAM_DB_MAX_POOL_SIZE" \
      -e DB_ACQUIRE_CONNECTION_TIMEOUT=60000 \
      -e REDIS_HOST=nostream-cache \
      -e REDIS_PORT=6379 \
      -e REDIS_USER=default \
      -e REDIS_PASSWORD=nostr_ts_relay \
      -v /root/nostream-config:/home/node/.nostr:ro \
      nostream:bench >/dev/null

    wait_port 8008 180 nostream
    ;;

  start-haven)
    cleanup_containers

    rm -rf /root/haven-bench
    mkdir -p /root/haven-bench/db
    mkdir -p /root/haven-bench/blossom
    mkdir -p /root/haven-bench/templates/static

    if [[ ! -f /root/haven-bench/templates/index.html ]]; then
      cat > /root/haven-bench/templates/index.html <<'EOF'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Haven</title>
  </head>
  <body>
    <h1>Haven</h1>
  </body>
</html>
EOF
    fi

    printf '[]\n' > /root/haven-bench/relays_import.json
    printf '[]\n' > /root/haven-bench/relays_blastr.json
    printf '[]\n' > /root/haven-bench/blacklisted_npubs.json
    printf '[]\n' > /root/haven-bench/whitelisted_npubs.json

    cat > /root/haven-bench/haven.env <<EOF
OWNER_NPUB=$HAVEN_OWNER_NPUB
RELAY_URL=$HAVEN_RELAY_URL
RELAY_PORT=3355
RELAY_BIND_ADDRESS=0.0.0.0
DB_ENGINE=badger
LMDB_MAPSIZE=0
BLOSSOM_PATH=blossom/
PRIVATE_RELAY_NAME=Private Relay
PRIVATE_RELAY_NPUB=$HAVEN_OWNER_NPUB
PRIVATE_RELAY_DESCRIPTION=Private relay for benchmarking
PRIVATE_RELAY_ICON=https://example.com/icon.png
PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=1000
PRIVATE_RELAY_EVENT_IP_LIMITER_INTERVAL=1
PRIVATE_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=5000
PRIVATE_RELAY_ALLOW_EMPTY_FILTERS=true
PRIVATE_RELAY_ALLOW_COMPLEX_FILTERS=true
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=500
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=2000
CHAT_RELAY_NAME=Chat Relay
CHAT_RELAY_NPUB=$HAVEN_OWNER_NPUB
CHAT_RELAY_DESCRIPTION=Chat relay for benchmarking
CHAT_RELAY_ICON=https://example.com/icon.png
CHAT_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=1000
CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL=1
CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=5000
CHAT_RELAY_ALLOW_EMPTY_FILTERS=true
CHAT_RELAY_ALLOW_COMPLEX_FILTERS=true
CHAT_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=500
CHAT_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
CHAT_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=2000
OUTBOX_RELAY_NAME=Outbox Relay
OUTBOX_RELAY_NPUB=$HAVEN_OWNER_NPUB
OUTBOX_RELAY_DESCRIPTION=Outbox relay for benchmarking
OUTBOX_RELAY_ICON=https://example.com/icon.png
OUTBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=1000
OUTBOX_RELAY_EVENT_IP_LIMITER_INTERVAL=1
OUTBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=5000
OUTBOX_RELAY_ALLOW_EMPTY_FILTERS=true
OUTBOX_RELAY_ALLOW_COMPLEX_FILTERS=true
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=500
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=2000
INBOX_RELAY_NAME=Inbox Relay
INBOX_RELAY_NPUB=$HAVEN_OWNER_NPUB
INBOX_RELAY_DESCRIPTION=Inbox relay for benchmarking
INBOX_RELAY_ICON=https://example.com/icon.png
INBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=1000
INBOX_RELAY_EVENT_IP_LIMITER_INTERVAL=1
INBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=5000
INBOX_RELAY_ALLOW_EMPTY_FILTERS=true
INBOX_RELAY_ALLOW_COMPLEX_FILTERS=true
INBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=500
INBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
INBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=2000
INBOX_PULL_INTERVAL_SECONDS=600
IMPORT_START_DATE=2023-01-20
IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS=60
IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS=120
IMPORT_SEED_RELAYS_FILE=/app/relays_import.json
BACKUP_PROVIDER=none
BACKUP_INTERVAL_HOURS=24
BLASTR_RELAYS_FILE=/app/relays_blastr.json
BLASTR_TIMEOUT_SECONDS=5
WOT_DEPTH=3
WOT_MINIMUM_FOLLOWERS=0
WOT_FETCH_TIMEOUT_SECONDS=30
WOT_REFRESH_INTERVAL=24h
WHITELISTED_NPUBS_FILE=
BLACKLISTED_NPUBS_FILE=
HAVEN_LOG_LEVEL=INFO
EOF

    chmod -R a+rwX /root/haven-bench

    docker run -d --name haven \
      --ulimit nofile=262144:262144 \
      -p 3355:3355 \
      --env-file /root/haven-bench/haven.env \
      -v /root/haven-bench/db:/app/db \
      -v /root/haven-bench/blossom:/app/blossom \
      -v /root/haven-bench/templates:/app/templates \
      -v /root/haven-bench/relays_import.json:/app/relays_import.json \
      -v /root/haven-bench/relays_blastr.json:/app/relays_blastr.json \
      -v /root/haven-bench/blacklisted_npubs.json:/app/blacklisted_npubs.json \
      -v /root/haven-bench/whitelisted_npubs.json:/app/whitelisted_npubs.json \
      "$HAVEN_IMAGE" >/dev/null

    wait_port 3355 120 haven
    ;;

  wipe-data-parrhesia-pg)
    docker exec pg psql -U parrhesia -d parrhesia -c \
      "TRUNCATE event_ids, event_tags, events, replaceable_event_state, addressable_event_state CASCADE"
    ;;

  wipe-data-parrhesia-memory)
    docker restart parrhesia
    wait_http "http://127.0.0.1:4413/health" 120 parrhesia
    ;;

  wipe-data-strfry)
    docker stop strfry
    rm -rf /root/strfry-data/strfry/*
    docker start strfry
    wait_port 7777 60 strfry
    ;;

  wipe-data-nostr-rs-relay)
    docker rm -f nostr-rs
    docker run -d --name nostr-rs \
      --ulimit nofile=262144:262144 \
      -p 8080:8080 \
      -v /root/nostr-rs.toml:/usr/src/app/config.toml:ro \
      "$NOSTR_RS_IMAGE" >/dev/null
    wait_http "http://127.0.0.1:8080/" 60 nostr-rs
    ;;

  wipe-data-nostream)
    docker exec nostream-db psql -U nostr_ts_relay -d nostr_ts_relay -c \
      "TRUNCATE events CASCADE"
    ;;

  wipe-data-haven)
    docker stop haven
    rm -rf /root/haven-bench/db/*
    docker start haven
    wait_port 3355 120 haven
    ;;

  cleanup)
    cleanup_containers
    ;;

  *)
    echo "unknown command: $cmd" >&2
    exit 1
    ;;
esac
