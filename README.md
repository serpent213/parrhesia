# Parrhesia

<img alt="Parrhesia Logo" src="./docs/logo.svg" width="150" align="right">

Parrhesia is a Nostr relay server written in Elixir/OTP with PostgreSQL storage.

It exposes:
- a WebSocket relay endpoint at `/relay`
- NIP-11 relay info on `GET /relay` with `Accept: application/nostr+json`
- operational HTTP endpoints (`/health`, `/ready`, `/metrics`)
  - `/metrics` is restricted by default to private/loopback source IPs
- a NIP-86-style management API at `POST /management` (NIP-98 auth)

## Supported NIPs

Current `supported_nips` list:

`1, 9, 11, 13, 17, 40, 42, 43, 44, 45, 50, 59, 62, 66, 70, 77, 86, 98`

## Requirements

- Elixir `~> 1.19`
- Erlang/OTP 28
- PostgreSQL (18 used in the dev environment; 16+ recommended)
- Docker or Podman plus Docker Compose support if you want to run the published container image

---

## Run locally

### 1) Prepare the database

Parrhesia uses these defaults in `dev`:
- `PGDATABASE=parrhesia_dev`
- `PGHOST=localhost`
- `PGPORT=5432`
- `PGUSER=$USER`

Create the DB and run migrations/seeds:

```bash
mix setup
```

### 2) Start the server

```bash
mix run --no-halt
```

Server listens on `http://localhost:4413` by default.

WebSocket clients should connect to:

```text
ws://localhost:4413/relay
```

### Useful endpoints

- `GET /health` -> `ok`
- `GET /ready` -> readiness status
- `GET /metrics` -> Prometheus metrics (private/loopback source IPs by default)
- `GET /relay` + `Accept: application/nostr+json` -> NIP-11 document
- `POST /management` -> management API (requires NIP-98 auth)

---

## Production configuration

### Minimal setup

Before a Nostr client can publish its first event successfully, make sure these pieces are in place:

1. PostgreSQL is reachable from Parrhesia.
   Set `DATABASE_URL` and create/migrate the database with `Parrhesia.Release.migrate()` or `mix ecto.migrate`.

2. Parrhesia is reachable behind your reverse proxy.
   Parrhesia itself listens on plain HTTP on port `4413`, and the reverse proxy is expected to terminate TLS and forward WebSocket traffic to `/relay`.

3. `:relay_url` matches the public relay URL clients should use.
   Set `PARRHESIA_RELAY_URL` to the public relay URL exposed by the reverse proxy.
   In the normal deployment model, this should be your public `wss://.../relay` URL.

4. The database schema is migrated before starting normal traffic.
   The app image does not auto-run migrations on boot.

That is the actual minimum. With default policy settings, writes do not require auth, event signatures are verified, and no extra Nostr-specific bootstrap step is needed before posting ordinary events.

In `prod`, these environment variables are used:

- `DATABASE_URL` (**required**), e.g. `ecto://USER:PASS@HOST/parrhesia_prod`
- `POOL_SIZE` (optional, default `32`)
- `PORT` (optional, default `4413`)
- `PARRHESIA_*` runtime overrides for relay config, limits, policies, metrics, and features
- `PARRHESIA_EXTRA_CONFIG` (optional path to an extra runtime config file)

`config/runtime.exs` reads these values at runtime in production releases.

### Runtime env naming

For runtime overrides, use the `PARRHESIA_...` prefix:

- `PARRHESIA_RELAY_URL`
- `PARRHESIA_MODERATION_CACHE_ENABLED`
- `PARRHESIA_ENABLE_EXPIRATION_WORKER`
- `PARRHESIA_LIMITS_*`
- `PARRHESIA_POLICIES_*`
- `PARRHESIA_METRICS_*`
- `PARRHESIA_FEATURES_*`
- `PARRHESIA_METRICS_ENDPOINT_*`

Examples:

```bash
export PARRHESIA_POLICIES_AUTH_REQUIRED_FOR_WRITES=true
export PARRHESIA_FEATURES_VERIFY_EVENT_SIGNATURES=true
export PARRHESIA_METRICS_ALLOWED_CIDRS="10.0.0.0/8,192.168.0.0/16"
export PARRHESIA_LIMITS_OUTBOUND_OVERFLOW_STRATEGY=drop_oldest
```

For settings that are awkward to express as env vars, mount an extra config file and set `PARRHESIA_EXTRA_CONFIG` to its path inside the container.

### Config reference

CSV env vars use comma-separated values. Boolean env vars accept `1/0`, `true/false`, `yes/no`, or `on/off`.

#### Top-level `:parrhesia`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:relay_url` | `PARRHESIA_RELAY_URL` | `ws://localhost:4413/relay` | Advertised relay URL and auth relay tag target |
| `:moderation_cache_enabled` | `PARRHESIA_MODERATION_CACHE_ENABLED` | `true` | Toggle moderation cache |
| `:enable_expiration_worker` | `PARRHESIA_ENABLE_EXPIRATION_WORKER` | `true` | Toggle background expiration worker |
| `:limits` | `PARRHESIA_LIMITS_*` | see table below | Runtime override group |
| `:policies` | `PARRHESIA_POLICIES_*` | see table below | Runtime override group |
| `:metrics` | `PARRHESIA_METRICS_*` | see table below | Runtime override group |
| `:features` | `PARRHESIA_FEATURES_*` | see table below | Runtime override group |
| `:storage.events` | `-` | `Parrhesia.Storage.Adapters.Postgres.Events` | Config-file override only |
| `:storage.moderation` | `-` | `Parrhesia.Storage.Adapters.Postgres.Moderation` | Config-file override only |
| `:storage.groups` | `-` | `Parrhesia.Storage.Adapters.Postgres.Groups` | Config-file override only |
| `:storage.admin` | `-` | `Parrhesia.Storage.Adapters.Postgres.Admin` | Config-file override only |

#### `Parrhesia.Repo`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:url` | `DATABASE_URL` | required | Example: `ecto://USER:PASS@HOST/DATABASE` |
| `:pool_size` | `POOL_SIZE` | `32` | DB connection pool size |
| `:queue_target` | `DB_QUEUE_TARGET_MS` | `1000` | Ecto queue target in ms |
| `:queue_interval` | `DB_QUEUE_INTERVAL_MS` | `5000` | Ecto queue interval in ms |
| `:types` | `-` | `Parrhesia.PostgresTypes` | Internal config-file setting |

#### `Parrhesia.Web.Endpoint`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:port` | `PORT` | `4413` | Main HTTP/WebSocket listener |

#### `Parrhesia.Web.MetricsEndpoint`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:enabled` | `PARRHESIA_METRICS_ENDPOINT_ENABLED` | `false` | Enables dedicated metrics listener |
| `:ip` | `PARRHESIA_METRICS_ENDPOINT_IP` | `127.0.0.1` | IPv4 only |
| `:port` | `PARRHESIA_METRICS_ENDPOINT_PORT` | `9568` | Dedicated metrics port |

#### `:limits`

| Atom key | ENV | Default |
| --- | --- | --- |
| `:max_frame_bytes` | `PARRHESIA_LIMITS_MAX_FRAME_BYTES` | `1048576` |
| `:max_event_bytes` | `PARRHESIA_LIMITS_MAX_EVENT_BYTES` | `262144` |
| `:max_filters_per_req` | `PARRHESIA_LIMITS_MAX_FILTERS_PER_REQ` | `16` |
| `:max_filter_limit` | `PARRHESIA_LIMITS_MAX_FILTER_LIMIT` | `500` |
| `:max_subscriptions_per_connection` | `PARRHESIA_LIMITS_MAX_SUBSCRIPTIONS_PER_CONNECTION` | `32` |
| `:max_event_future_skew_seconds` | `PARRHESIA_LIMITS_MAX_EVENT_FUTURE_SKEW_SECONDS` | `900` |
| `:max_event_ingest_per_window` | `PARRHESIA_LIMITS_MAX_EVENT_INGEST_PER_WINDOW` | `120` |
| `:event_ingest_window_seconds` | `PARRHESIA_LIMITS_EVENT_INGEST_WINDOW_SECONDS` | `1` |
| `:auth_max_age_seconds` | `PARRHESIA_LIMITS_AUTH_MAX_AGE_SECONDS` | `600` |
| `:max_outbound_queue` | `PARRHESIA_LIMITS_MAX_OUTBOUND_QUEUE` | `256` |
| `:outbound_drain_batch_size` | `PARRHESIA_LIMITS_OUTBOUND_DRAIN_BATCH_SIZE` | `64` |
| `:outbound_overflow_strategy` | `PARRHESIA_LIMITS_OUTBOUND_OVERFLOW_STRATEGY` | `:close` |
| `:max_negentropy_payload_bytes` | `PARRHESIA_LIMITS_MAX_NEGENTROPY_PAYLOAD_BYTES` | `4096` |
| `:max_negentropy_sessions_per_connection` | `PARRHESIA_LIMITS_MAX_NEGENTROPY_SESSIONS_PER_CONNECTION` | `8` |
| `:max_negentropy_total_sessions` | `PARRHESIA_LIMITS_MAX_NEGENTROPY_TOTAL_SESSIONS` | `10000` |
| `:negentropy_session_idle_timeout_seconds` | `PARRHESIA_LIMITS_NEGENTROPY_SESSION_IDLE_TIMEOUT_SECONDS` | `60` |
| `:negentropy_session_sweep_interval_seconds` | `PARRHESIA_LIMITS_NEGENTROPY_SESSION_SWEEP_INTERVAL_SECONDS` | `10` |

#### `:policies`

| Atom key | ENV | Default |
| --- | --- | --- |
| `:auth_required_for_writes` | `PARRHESIA_POLICIES_AUTH_REQUIRED_FOR_WRITES` | `false` |
| `:auth_required_for_reads` | `PARRHESIA_POLICIES_AUTH_REQUIRED_FOR_READS` | `false` |
| `:min_pow_difficulty` | `PARRHESIA_POLICIES_MIN_POW_DIFFICULTY` | `0` |
| `:accept_ephemeral_events` | `PARRHESIA_POLICIES_ACCEPT_EPHEMERAL_EVENTS` | `true` |
| `:mls_group_event_ttl_seconds` | `PARRHESIA_POLICIES_MLS_GROUP_EVENT_TTL_SECONDS` | `300` |
| `:marmot_require_h_for_group_queries` | `PARRHESIA_POLICIES_MARMOT_REQUIRE_H_FOR_GROUP_QUERIES` | `true` |
| `:marmot_group_max_h_values_per_filter` | `PARRHESIA_POLICIES_MARMOT_GROUP_MAX_H_VALUES_PER_FILTER` | `32` |
| `:marmot_group_max_query_window_seconds` | `PARRHESIA_POLICIES_MARMOT_GROUP_MAX_QUERY_WINDOW_SECONDS` | `2592000` |
| `:marmot_media_max_imeta_tags_per_event` | `PARRHESIA_POLICIES_MARMOT_MEDIA_MAX_IMETA_TAGS_PER_EVENT` | `8` |
| `:marmot_media_max_field_value_bytes` | `PARRHESIA_POLICIES_MARMOT_MEDIA_MAX_FIELD_VALUE_BYTES` | `1024` |
| `:marmot_media_max_url_bytes` | `PARRHESIA_POLICIES_MARMOT_MEDIA_MAX_URL_BYTES` | `2048` |
| `:marmot_media_allowed_mime_prefixes` | `PARRHESIA_POLICIES_MARMOT_MEDIA_ALLOWED_MIME_PREFIXES` | `[]` |
| `:marmot_media_reject_mip04_v1` | `PARRHESIA_POLICIES_MARMOT_MEDIA_REJECT_MIP04_V1` | `true` |
| `:marmot_push_server_pubkeys` | `PARRHESIA_POLICIES_MARMOT_PUSH_SERVER_PUBKEYS` | `[]` |
| `:marmot_push_max_relay_tags` | `PARRHESIA_POLICIES_MARMOT_PUSH_MAX_RELAY_TAGS` | `16` |
| `:marmot_push_max_payload_bytes` | `PARRHESIA_POLICIES_MARMOT_PUSH_MAX_PAYLOAD_BYTES` | `65536` |
| `:marmot_push_max_trigger_age_seconds` | `PARRHESIA_POLICIES_MARMOT_PUSH_MAX_TRIGGER_AGE_SECONDS` | `120` |
| `:marmot_push_require_expiration` | `PARRHESIA_POLICIES_MARMOT_PUSH_REQUIRE_EXPIRATION` | `true` |
| `:marmot_push_max_expiration_window_seconds` | `PARRHESIA_POLICIES_MARMOT_PUSH_MAX_EXPIRATION_WINDOW_SECONDS` | `120` |
| `:marmot_push_max_server_recipients` | `PARRHESIA_POLICIES_MARMOT_PUSH_MAX_SERVER_RECIPIENTS` | `1` |
| `:management_auth_required` | `PARRHESIA_POLICIES_MANAGEMENT_AUTH_REQUIRED` | `true` |

#### `:metrics`

| Atom key | ENV | Default |
| --- | --- | --- |
| `:enabled_on_main_endpoint` | `PARRHESIA_METRICS_ENABLED_ON_MAIN_ENDPOINT` | `true` |
| `:public` | `PARRHESIA_METRICS_PUBLIC` | `false` |
| `:private_networks_only` | `PARRHESIA_METRICS_PRIVATE_NETWORKS_ONLY` | `true` |
| `:allowed_cidrs` | `PARRHESIA_METRICS_ALLOWED_CIDRS` | `[]` |
| `:auth_token` | `PARRHESIA_METRICS_AUTH_TOKEN` | `nil` |

#### `:features`

| Atom key | ENV | Default |
| --- | --- | --- |
| `:verify_event_signatures` | `PARRHESIA_FEATURES_VERIFY_EVENT_SIGNATURES` | `true` |
| `:nip_45_count` | `PARRHESIA_FEATURES_NIP_45_COUNT` | `true` |
| `:nip_50_search` | `PARRHESIA_FEATURES_NIP_50_SEARCH` | `true` |
| `:nip_77_negentropy` | `PARRHESIA_FEATURES_NIP_77_NEGENTROPY` | `true` |
| `:marmot_push_notifications` | `PARRHESIA_FEATURES_MARMOT_PUSH_NOTIFICATIONS` | `false` |

#### Extra runtime config

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| extra runtime config file | `PARRHESIA_EXTRA_CONFIG` | unset | Imports an additional runtime `.exs` file |

---

## Deploy

### Option A: Elixir release

```bash
export MIX_ENV=prod
export DATABASE_URL="ecto://USER:PASS@HOST/parrhesia_prod"
export POOL_SIZE=20

mix deps.get --only prod
mix compile
mix release

_build/prod/rel/parrhesia/bin/parrhesia eval "Parrhesia.Release.migrate()"
_build/prod/rel/parrhesia/bin/parrhesia foreground
```

For systemd/process managers, run the release command in foreground mode.

### Option B: Nix release package (`default.nix`)

Build:

```bash
nix-build
```

Run the built release from `./result/bin/parrhesia` (release command interface).

### Option C: Docker image via Nix flake

Build the image tarball:

```bash
nix build .#dockerImage
# or with explicit build target:
nix build .#packages.x86_64-linux.dockerImage
```

Load it into Docker:

```bash
docker load < result
```

Run database migrations:

```bash
docker run --rm \
  -e DATABASE_URL="ecto://USER:PASS@HOST/parrhesia_prod" \
  parrhesia:latest \
  eval "Parrhesia.Release.migrate()"
```

Start the relay:

```bash
docker run --rm \
  -p 4413:4413 \
  -e DATABASE_URL="ecto://USER:PASS@HOST/parrhesia_prod" \
  -e POOL_SIZE=20 \
  parrhesia:latest
```

### Option D: Docker Compose with PostgreSQL

The repo includes [`compose.yaml`](./compose.yaml) and [`.env.example`](./.env.example) so Docker users can run Postgres and Parrhesia together.

Set up the environment file:

```bash
cp .env.example .env
```

If you are building locally from source, build and load the image first:

```bash
nix build .#dockerImage
docker load < result
```

Then start the stack:

```bash
docker compose up -d db
docker compose run --rm migrate
docker compose up -d parrhesia
```

The relay will be available on:

```text
ws://localhost:4413/relay
```

Notes:

- `compose.yaml` keeps PostgreSQL in a separate container; the Parrhesia image only runs the app release.
- The container listens on port `4413`; use `PARRHESIA_HOST_PORT` if you want a different published host port.
- Migrations are run explicitly through the one-shot `migrate` service instead of on every app boot.
- Common runtime overrides can go straight into `.env`; see [`.env.example`](./.env.example) for examples.
- For more specialized overrides, mount a file and set `PARRHESIA_EXTRA_CONFIG=/path/in/container/runtime.exs`.
- When a GHCR image is published, set `PARRHESIA_IMAGE=ghcr.io/<owner>/parrhesia:<tag>` in `.env` and reuse the same compose flow.

---

## Benchmark

The benchmark compares Parrhesia against [`strfry`](https://github.com/hoytech/strfry) and [`nostr-rs-relay`](https://sr.ht/~gheartsfield/nostr-rs-relay/) using [`nostr-bench`](https://github.com/rnostr/nostr-bench).

Run it with:

```bash
mix bench
```

Current comparison results from [BENCHMARK.md](./BENCHMARK.md):

| metric | parrhesia | strfry | nostr-rs-relay | strfry/parrhesia | nostr-rs/parrhesia |
| --- | ---: | ---: | ---: | ---: | ---: |
| connect avg latency (ms) ↓ | 13.50 | 3.00 | 2.00 | **0.22x** | **0.15x** |
| connect max latency (ms) ↓ | 22.50 | 5.50 | 3.00 | **0.24x** | **0.13x** |
| echo throughput (TPS) ↑ | 80385.00 | 61673.00 | 164516.00 | 0.77x | **2.05x** |
| echo throughput (MiB/s) ↑ | 44.00 | 34.45 | 90.10 | 0.78x | **2.05x** |
| event throughput (TPS) ↑ | 2000.00 | 3404.50 | 788.00 | **1.70x** | 0.39x |
| event throughput (MiB/s) ↑ | 1.30 | 2.20 | 0.50 | **1.69x** | 0.38x |
| req throughput (TPS) ↑ | 3664.00 | 1808.50 | 877.50 | 0.49x | 0.24x |
| req throughput (MiB/s) ↑ | 20.75 | 11.75 | 2.45 | 0.57x | 0.12x |

Higher is better for `↑` metrics. Lower is better for `↓` metrics.

(Results from a Linux container on a 6-core Intel i5-8400T with NVMe drive)

---

## Development quality checks

Before opening a PR:

```bash
mix precommit
```

Additional external CLI end-to-end checks with `nak`:

```bash
mix test.nak_e2e
```

For Marmot client end-to-end checks (TypeScript/Node suite using `marmot-ts`, included in `precommit`):

```bash
mix test.marmot_e2e
```
