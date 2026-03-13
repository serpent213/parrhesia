# Parrhesia

Parrhesia is a Nostr relay server written in Elixir/OTP with PostgreSQL storage.

It exposes:
- a WebSocket relay endpoint at `/relay`
- NIP-11 relay info on `GET /relay` with `Accept: application/nostr+json`
- operational HTTP endpoints (`/health`, `/ready`, `/metrics`)
- a NIP-86-style management API at `POST /management` (NIP-98 auth)

## Supported NIPs

Current `supported_nips` list:

`1, 9, 11, 13, 17, 40, 42, 43, 44, 45, 50, 59, 62, 66, 70, 77, 86, 98`

## Requirements

- Elixir `~> 1.19`
- Erlang/OTP 28
- PostgreSQL (18 used in the dev environment; 16+ recommended)

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

Server listens on `http://localhost:4000` by default.

WebSocket clients should connect to:

```text
ws://localhost:4000/relay
```

### Useful endpoints

- `GET /health` -> `ok`
- `GET /ready` -> readiness status
- `GET /metrics` -> Prometheus metrics
- `GET /relay` + `Accept: application/nostr+json` -> NIP-11 document
- `POST /management` -> management API (requires NIP-98 auth)

---

## Production configuration

In `prod`, these environment variables are used:

- `DATABASE_URL` (**required**), e.g. `ecto://USER:PASS@HOST/parrhesia_prod`
- `POOL_SIZE` (optional, default `10`)
- `PORT` (optional, default `4000`)

`config/runtime.exs` reads these values at runtime in production releases.

### Typical relay config

Add/override in config files (for example in `config/prod.exs` or a `config/runtime.exs`):

```elixir
config :parrhesia, Parrhesia.Web.Endpoint,
  ip: {0, 0, 0, 0},
  port: 4000

config :parrhesia,
  limits: [
    max_frame_bytes: 1_048_576,
    max_event_bytes: 262_144,
    max_filters_per_req: 16,
    max_filter_limit: 500,
    max_subscriptions_per_connection: 32,
    max_event_future_skew_seconds: 900,
    max_outbound_queue: 256,
    outbound_drain_batch_size: 64,
    outbound_overflow_strategy: :close
  ],
  policies: [
    auth_required_for_writes: false,
    auth_required_for_reads: false,
    min_pow_difficulty: 0,
    accept_ephemeral_events: true,
    mls_group_event_ttl_seconds: 300,
    marmot_require_h_for_group_queries: true,
    marmot_group_max_h_values_per_filter: 32,
    marmot_group_max_query_window_seconds: 2_592_000,
    marmot_media_max_imeta_tags_per_event: 8,
    marmot_media_max_field_value_bytes: 1024,
    marmot_media_max_url_bytes: 2048,
    marmot_media_allowed_mime_prefixes: [],
    marmot_media_reject_mip04_v1: true,
    marmot_push_server_pubkeys: [],
    marmot_push_max_relay_tags: 16,
    marmot_push_max_payload_bytes: 65_536,
    marmot_push_max_trigger_age_seconds: 120,
    marmot_push_require_expiration: true,
    marmot_push_max_expiration_window_seconds: 120,
    marmot_push_max_server_recipients: 1
  ],
  features: [
    nip_45_count: true,
    nip_50_search: true,
    nip_77_negentropy: true,
    marmot_push_notifications: false
  ]
```

---

## Deploy

### Option A: Elixir release

```bash
export MIX_ENV=prod
export DATABASE_URL="ecto://USER:PASS@HOST/parrhesia_prod"
export POOL_SIZE=20

mix deps.get --only prod
mix compile
mix ecto.migrate
mix release

_build/prod/rel/parrhesia/bin/parrhesia foreground
```

For systemd/process managers, run the release command in foreground mode.

### Option B: Nix package (`default.nix`)

Build:

```bash
nix-build
```

Run the built release from `./result/bin/parrhesia` (release command interface).

---

## Development quality checks

Before opening a PR:

```bash
mix precommit
```

For external CLI end-to-end checks with `nak`:

```bash
mix test.nak_e2e
```

For Marmot client end-to-end checks (TypeScript/Node suite using `marmot-ts`):

```bash
mix test.marmot_e2e
```
