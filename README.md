# Parrhesia

<img alt="Parrhesia Logo" src="./docs/logo.svg" width="150" align="right">

Parrhesia is a Nostr relay server written in Elixir/OTP.

Supported storage backends:

- PostgreSQL, which is the primary and production-oriented backend
- in-memory storage, which is useful for tests, local experiments, and benchmarks

**BETA CONDITION – BREAKING CHANGES MAY STILL HAPPEN!**

- Advanced Querying: Full-text search (NIP-50) and COUNT queries (NIP-45).
- Secure Messaging: First-class support for Marmot MLS-encrypted groups and NIP-17/44/59 gift-wrapped DMs.
- Identity & Auth: NIP-42 authentication flows and NIP-86 management API with NIP-98 HTTP auth.
- Data Integrity: Negentropy-based synchronization and NIP-62 vanish flows.

It exposes:

- listener-configurable WS/HTTP ingress, with a default `public` listener on port `4413`
- a WebSocket relay endpoint at `/relay` on listeners that enable the `nostr` feature
- NIP-11 relay info on `GET /relay` with `Accept: application/nostr+json`
- operational HTTP endpoints such as `/health`, `/ready`, and `/metrics` on listeners that enable them
- a NIP-86-style management API at `POST /management` on listeners that enable the `admin` feature

Listeners can run in plain HTTP, HTTPS, mutual TLS, or proxy-terminated TLS modes. The current TLS implementation supports:

- server TLS on listener sockets
- optional client certificate admission with listener-side client pin checks
- proxy-asserted client TLS identity on trusted proxy hops
- admin-triggered certificate reload by restarting an individual listener from disk

## Supported NIPs

Current `supported_nips` list:

`1, 9, 11, 13, 17, 40, 42, 43, 44, 45, 50, 59, 62, 66, 70, 77, 86, 98`

`43` is advertised when the built-in NIP-43 relay access flow is enabled. Parrhesia generates relay-signed `28935` invite responses on `REQ`, validates join and leave requests locally, and publishes the resulting signed `8000`, `8001`, and `13534` relay membership events into its own local event store.

`50` uses ranked PostgreSQL full-text search over event `content` by default. Parrhesia applies the filter `limit` after ordering by match quality, and falls back to trigram-backed substring matching for short or symbol-heavy queries such as search-as-you-type prefixes, domains, and punctuation-rich tokens.

`66` is advertised when the built-in NIP-66 publisher is enabled and has at least one relay target. The default config enables it for the `public` relay URL. Parrhesia probes those target relays, collects the resulting NIP-11 / websocket liveness data, and then publishes the signed `10166` and `30166` events locally on this relay.

## Requirements

- Elixir `~> 1.18`
- Erlang/OTP 28
- PostgreSQL (18 used in the dev environment; 16+ recommended)
- [`just`](https://github.com/casey/just) for the command runner used in this repo
- Docker or Podman plus Docker Compose support if you want to run the published container image

---

## Command runner (`just`)

This repo includes a `justfile` that provides a grouped command/subcommand CLI over common mix tasks and scripts.

```bash
just
just help bench
just help e2e
```

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

The default `public` listener binds to `http://localhost:4413`.

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

## Test suites

Primary test entrypoints:

- `mix test` for the ExUnit suite
- `just e2e marmot` for the Marmot client end-to-end suite
- `just e2e node-sync` for the two-node relay sync end-to-end suite
- `just e2e node-sync-docker` for the release-image Docker two-node relay sync suite

The node-sync harnesses are driven by:

- [`scripts/run_node_sync_e2e.sh`](./scripts/run_node_sync_e2e.sh)
- [`scripts/run_node_sync_docker_e2e.sh`](./scripts/run_node_sync_docker_e2e.sh)
- [`scripts/node_sync_e2e.exs`](./scripts/node_sync_e2e.exs)
- [`compose.node-sync-e2e.yaml`](./compose.node-sync-e2e.yaml)

`just e2e node-sync` runs two real Parrhesia nodes against separate PostgreSQL databases, verifies catch-up and live sync, restarts one node, and verifies persisted resume behavior. `just e2e node-sync-docker` runs the same scenario against the release Docker image.

GitHub CI currently runs the non-Docker node-sync e2e on the main Linux matrix job. The Docker node-sync e2e remains an explicit/manual check because it depends on release-image build/runtime fidelity and a working Docker host.

---

## Embedding in another Elixir app

Parrhesia is usable as an embedded OTP dependency, not just as a standalone relay process.
The intended in-process surface is `Parrhesia.API.*`, especially:

- `Parrhesia.API.Events` for publish, query, and count
- `Parrhesia.API.Stream` for local REQ-like subscriptions
- `Parrhesia.API.Admin` for management operations
- `Parrhesia.API.Identity`, `Parrhesia.API.ACL`, and `Parrhesia.API.Sync` for relay identity, protected sync ACLs, and outbound relay sync

For host-managed HTTP/WebSocket ingress mounting, use `Parrhesia.Plug`.

Start with:

- [`docs/LOCAL_API.md`](./docs/LOCAL_API.md) for the embedding model and a minimal host setup
- generated ExDoc for the `Embedded API` module group when running `mix docs`

Important caveats for host applications:

- Parrhesia is beta software; expect some API and config churn as the runtime stabilizes.
- Parrhesia currently assumes a single runtime per BEAM node and uses globally registered process names.
- The defaults in this repo's `config/*.exs` are not imported automatically when Parrhesia is used as a dependency. A host app must set `config :parrhesia, ...` explicitly.
- The host app is responsible for migrating Parrhesia's schema, for example with `Parrhesia.Release.migrate()` or `mix ecto.migrate -r Parrhesia.Repo`.

### Official embedding boundary

For embedded use, the stable boundaries are:

- `Parrhesia.API.*` for in-process publish/query/admin/sync operations
- `Parrhesia.Plug` for host-managed HTTP/WebSocket ingress mounting

If your host app owns the public HTTPS endpoint, keep this as the baseline runtime config:

```elixir
config :parrhesia, :listeners, %{}
```

Notes:

- `listeners: %{}` disables Parrhesia-managed HTTP/WebSocket ingress (`/relay`, `/management`, `/metrics`, etc.).
- Mount `Parrhesia.Plug` in your host endpoint/router when you still want Parrhesia ingress under the host's single HTTPS surface.
- `Parrhesia.Web.*` modules remain internal runtime wiring. Use `Parrhesia.Plug` as the documented mount API.

The config reference below still applies when embedded. That is the primary place to document basic setup and runtime configuration changes.

---

## Production configuration

### Minimal setup

Before a Nostr client can publish its first event successfully, make sure these pieces are in place:

1. PostgreSQL is reachable from Parrhesia.
   Set `DATABASE_URL` and create/migrate the database with `Parrhesia.Release.migrate()` or `mix ecto.migrate`.

   PostgreSQL is the supported production datastore. The in-memory backend is intended for
   non-persistent runs such as tests and benchmarks.

2. Parrhesia listeners are configured for your deployment.
   The default config exposes a `public` listener on plain HTTP port `4413`, and a reverse proxy can terminate TLS and forward WebSocket traffic to `/relay`. Additional listeners can be defined in `config/*.exs`.

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
- `PARRHESIA_*` runtime overrides for relay config, metadata, identity, sync, ACL, limits, policies, listeners, retention, and features
- `PARRHESIA_EXTRA_CONFIG` (optional path to an extra runtime config file)

`config/runtime.exs` reads these values at runtime in production releases.

### Runtime env naming

For runtime overrides, use the `PARRHESIA_...` prefix:

- `PARRHESIA_RELAY_URL`
- `PARRHESIA_METADATA_HIDE_VERSION`
- `PARRHESIA_IDENTITY_*`
- `PARRHESIA_SYNC_*`
- `PARRHESIA_ACL_*`
- `PARRHESIA_TRUSTED_PROXIES`
- `PARRHESIA_PUBLIC_MAX_CONNECTIONS`
- `PARRHESIA_MODERATION_CACHE_ENABLED`
- `PARRHESIA_ENABLE_EXPIRATION_WORKER`
- `PARRHESIA_ENABLE_PARTITION_RETENTION_WORKER`
- `PARRHESIA_STORAGE_BACKEND`
- `PARRHESIA_LIMITS_*`
- `PARRHESIA_POLICIES_*`
- `PARRHESIA_METRICS_*`
- `PARRHESIA_METRICS_ENDPOINT_MAX_CONNECTIONS`
- `PARRHESIA_RETENTION_*`
- `PARRHESIA_FEATURES_*`
- `PARRHESIA_METRICS_ENDPOINT_*`

Examples:

```bash
export PARRHESIA_POLICIES_AUTH_REQUIRED_FOR_WRITES=true
export PARRHESIA_METRICS_ALLOWED_CIDRS="10.0.0.0/8,192.168.0.0/16"
export PARRHESIA_LIMITS_OUTBOUND_OVERFLOW_STRATEGY=drop_oldest
```

Listeners themselves are primarily configured under `config :parrhesia, :listeners, ...`. The current runtime env helpers tune the default public listener and the optional dedicated metrics listener, including their connection ceilings.

For settings that are awkward to express as env vars, mount an extra config file and set `PARRHESIA_EXTRA_CONFIG` to its path inside the container.

### Config reference

CSV env vars use comma-separated values. Boolean env vars accept `1/0`, `true/false`, `yes/no`, or `on/off`.

#### Top-level `:parrhesia`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:relay_url` | `PARRHESIA_RELAY_URL` | `ws://localhost:4413/relay` | Advertised relay URL and auth relay tag target |
| `:metadata.hide_version?` | `PARRHESIA_METADATA_HIDE_VERSION` | `true` | Hides the relay version from outbound `User-Agent` and NIP-11 when enabled |
| `:acl.protected_filters` | `PARRHESIA_ACL_PROTECTED_FILTERS` | `[]` | JSON-encoded protected filter list for sync ACL checks |
| `:identity.path` | `PARRHESIA_IDENTITY_PATH` | `nil` | Optional path for persisted relay identity material |
| `:identity.private_key` | `PARRHESIA_IDENTITY_PRIVATE_KEY` | `nil` | Optional inline relay private key |
| `:moderation_cache_enabled` | `PARRHESIA_MODERATION_CACHE_ENABLED` | `true` | Toggle moderation cache |
| `:enable_expiration_worker` | `PARRHESIA_ENABLE_EXPIRATION_WORKER` | `true` | Toggle background expiration worker |
| `:nip43` | config-file driven | see table below | Built-in NIP-43 relay access invite / membership flow |
| `:nip66` | config-file driven | see table below | Built-in NIP-66 discovery / monitor publisher |
| `:sync.path` | `PARRHESIA_SYNC_PATH` | `nil` | Optional path to sync peer config |
| `:sync.start_workers?` | `PARRHESIA_SYNC_START_WORKERS` | `true` | Start outbound sync workers on boot |
| `:limits` | `PARRHESIA_LIMITS_*` | see table below | Runtime override group |
| `:policies` | `PARRHESIA_POLICIES_*` | see table below | Runtime override group |
| `:listeners` | config-file driven | see notes below | Ingress listeners with bind, transport, feature, auth, network, and baseline ACL settings |
| `:retention` | `PARRHESIA_RETENTION_*` | see table below | Partition lifecycle and pruning policy |
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

#### `Parrhesia.ReadRepo`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:url` | `DATABASE_URL` | required | Shares the primary DB URL with the write repo |
| `:pool_size` | `DB_READ_POOL_SIZE` | `32` | Read-only query pool size |
| `:queue_target` | `DB_READ_QUEUE_TARGET_MS` | `1000` | Read pool Ecto queue target in ms |
| `:queue_interval` | `DB_READ_QUEUE_INTERVAL_MS` | `5000` | Read pool Ecto queue interval in ms |
| `:types` | `-` | `Parrhesia.PostgresTypes` | Internal config-file setting |

#### `:listeners`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:public.bind.port` | `PORT` | `4413` | Default public listener port |
| `:public.max_connections` | `PARRHESIA_PUBLIC_MAX_CONNECTIONS` | `20000` | Target total connection ceiling for the public listener |
| `:public.proxy.trusted_cidrs` | `PARRHESIA_TRUSTED_PROXIES` | `[]` | Trusted reverse proxies for forwarded IP handling |
| `:public.features.metrics.*` | `PARRHESIA_METRICS_*` | see below | Convenience runtime overrides for metrics on the public listener |
| `:metrics.bind.port` | `PARRHESIA_METRICS_ENDPOINT_PORT` | `9568` | Optional dedicated metrics listener port |
| `:metrics.max_connections` | `PARRHESIA_METRICS_ENDPOINT_MAX_CONNECTIONS` | `1024` | Target total connection ceiling for the dedicated metrics listener |
| `:metrics.enabled` | `PARRHESIA_METRICS_ENDPOINT_ENABLED` | `false` | Enables the optional dedicated metrics listener |

Listener `max_connections` is a first-class config field. Parrhesia translates it to ThousandIsland's per-acceptor `num_connections` limit based on the active acceptor count. Raw `bandit_options[:thousand_island_options]` can still override that for advanced tuning.

Listener `transport.tls` supports `:disabled`, `:server`, `:mutual`, and `:proxy_terminated`. For TLS-enabled listeners, the main config-file fields are `certfile`, `keyfile`, optional `cacertfile`, optional `cipher_suite`, optional `client_pins`, and `proxy_headers` for proxy-terminated identity.

Every listener supports this config-file schema:

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:id` | `-` | listener key or `:listener` | Listener identifier |
| `:enabled` | public/metrics helpers only | `true` | Whether the listener is started |
| `:bind.ip` | `-` | `0.0.0.0` (`public`) / `127.0.0.1` (`metrics`) | Bind address |
| `:bind.port` | `PORT` / `PARRHESIA_METRICS_ENDPOINT_PORT` | `4413` / `9568` | Bind port |
| `:max_connections` | `PARRHESIA_PUBLIC_MAX_CONNECTIONS` / `PARRHESIA_METRICS_ENDPOINT_MAX_CONNECTIONS` | `20000` / `1024` | Target total listener connection ceiling; accepts integer or `:infinity` in config files |
| `:transport.scheme` | `-` | `:http` | Listener scheme |
| `:transport.tls` | `-` | `%{mode: :disabled}` | TLS mode and TLS-specific options |
| `:proxy.trusted_cidrs` | `PARRHESIA_TRUSTED_PROXIES` on `public` | `[]` | Trusted proxy CIDRs for forwarded identity / IP handling |
| `:proxy.honor_x_forwarded_for` | `-` | `true` | Respect `X-Forwarded-For` from trusted proxies |
| `:network.public` | `-` | `false` | Allow only public networks |
| `:network.private_networks_only` | `-` | `false` | Allow only RFC1918 / local networks |
| `:network.allow_cidrs` | `-` | `[]` | Explicit CIDR allowlist |
| `:network.allow_all` | `-` | `true` | Allow all source IPs |
| `:features.nostr.enabled` | `-` | `true` on `public`, `false` on metrics listener | Enables `/relay` |
| `:features.admin.enabled` | `-` | `true` on `public`, `false` on metrics listener | Enables `/management` |
| `:features.metrics.enabled` | `PARRHESIA_METRICS_ENABLED_ON_MAIN_ENDPOINT` on `public` | `true` on `public`, `true` on metrics listener | Enables `/metrics` |
| `:features.metrics.auth_token` | `PARRHESIA_METRICS_AUTH_TOKEN` | `nil` | Optional bearer token for `/metrics` |
| `:features.metrics.access.public` | `PARRHESIA_METRICS_PUBLIC` | `false` | Allow public-network access to `/metrics` |
| `:features.metrics.access.private_networks_only` | `PARRHESIA_METRICS_PRIVATE_NETWORKS_ONLY` | `true` | Restrict `/metrics` to private networks |
| `:features.metrics.access.allow_cidrs` | `PARRHESIA_METRICS_ALLOWED_CIDRS` | `[]` | Additional CIDR allowlist for `/metrics` |
| `:features.metrics.access.allow_all` | `-` | `true` | Unconditional metrics access in config files |
| `:auth.nip42_required` | `-` | `false` | Require NIP-42 for relay reads / writes |
| `:auth.nip98_required_for_admin` | `PARRHESIA_POLICIES_MANAGEMENT_AUTH_REQUIRED` on `public` | `true` | Require NIP-98 for management API calls |
| `:baseline_acl.read` | `-` | `[]` | Static read deny/allow rules |
| `:baseline_acl.write` | `-` | `[]` | Static write deny/allow rules |
| `:bandit_options` | `-` | `[]` | Advanced Bandit / ThousandIsland passthrough |

#### `:nip66`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:enabled` | `-` | `true` | Enables the built-in NIP-66 publisher worker |
| `:publish_interval_seconds` | `-` | `900` | Republish cadence for `10166` and `30166` events |
| `:publish_monitor_announcement?` | `-` | `true` | Publish a `10166` monitor announcement alongside discovery events |
| `:timeout_ms` | `-` | `5000` | Probe timeout for websocket and NIP-11 checks |
| `:checks` | `-` | `[:open, :read, :nip11]` | Checks advertised in `10166` and run against each target relay during probing |
| `:targets` | `-` | `[]` | Optional explicit relay targets to probe; when empty, Parrhesia uses `:relay_url` for the `public` listener |

NIP-66 targets are probe sources, not publish destinations. Parrhesia connects to each target relay, collects the configured liveness / discovery data, and stores the resulting signed `10166` / `30166` events in its own local event store so clients can query them here.

#### `:nip43`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:enabled` | `-` | `true` | Enables the built-in NIP-43 relay access flow and advertises `43` in NIP-11 |
| `:invite_ttl_seconds` | `-` | `900` | Expiration window for generated invite claim strings returned by `REQ` filters targeting kind `28935` |
| `:request_max_age_seconds` | `-` | `300` | Maximum allowed age for inbound join (`28934`) and leave (`28936`) requests |

Parrhesia treats NIP-43 invite requests as synthetic relay output, not stored client input. A `REQ` for kind `28935` causes the relay to generate a fresh relay-signed invite event on the fly. Clients then submit that claim back in a protected kind `28934` join request. When a join or leave request is accepted, Parrhesia updates its local relay membership state and publishes the corresponding relay-signed `8000` / `8001` delta plus the latest `13534` membership snapshot locally.

#### `:limits`

| Atom key | ENV | Default |
| --- | --- | --- |
| `:max_frame_bytes` | `PARRHESIA_LIMITS_MAX_FRAME_BYTES` | `1048576` |
| `:max_event_bytes` | `PARRHESIA_LIMITS_MAX_EVENT_BYTES` | `262144` |
| `:max_filters_per_req` | `PARRHESIA_LIMITS_MAX_FILTERS_PER_REQ` | `16` |
| `:max_filter_limit` | `PARRHESIA_LIMITS_MAX_FILTER_LIMIT` | `500` |
| `:max_tags_per_event` | `PARRHESIA_LIMITS_MAX_TAGS_PER_EVENT` | `256` |
| `:max_tag_values_per_filter` | `PARRHESIA_LIMITS_MAX_TAG_VALUES_PER_FILTER` | `128` |
| `:ip_max_event_ingest_per_window` | `PARRHESIA_LIMITS_IP_MAX_EVENT_INGEST_PER_WINDOW` | `1000` |
| `:ip_event_ingest_window_seconds` | `PARRHESIA_LIMITS_IP_EVENT_INGEST_WINDOW_SECONDS` | `1` |
| `:relay_max_event_ingest_per_window` | `PARRHESIA_LIMITS_RELAY_MAX_EVENT_INGEST_PER_WINDOW` | `10000` |
| `:relay_event_ingest_window_seconds` | `PARRHESIA_LIMITS_RELAY_EVENT_INGEST_WINDOW_SECONDS` | `1` |
| `:max_subscriptions_per_connection` | `PARRHESIA_LIMITS_MAX_SUBSCRIPTIONS_PER_CONNECTION` | `32` |
| `:max_event_future_skew_seconds` | `PARRHESIA_LIMITS_MAX_EVENT_FUTURE_SKEW_SECONDS` | `900` |
| `:max_event_ingest_per_window` | `PARRHESIA_LIMITS_MAX_EVENT_INGEST_PER_WINDOW` | `120` |
| `:event_ingest_window_seconds` | `PARRHESIA_LIMITS_EVENT_INGEST_WINDOW_SECONDS` | `1` |
| `:auth_max_age_seconds` | `PARRHESIA_LIMITS_AUTH_MAX_AGE_SECONDS` | `600` |
| `:websocket_ping_interval_seconds` | `PARRHESIA_LIMITS_WEBSOCKET_PING_INTERVAL_SECONDS` | `30` |
| `:websocket_pong_timeout_seconds` | `PARRHESIA_LIMITS_WEBSOCKET_PONG_TIMEOUT_SECONDS` | `10` |
| `:max_outbound_queue` | `PARRHESIA_LIMITS_MAX_OUTBOUND_QUEUE` | `256` |
| `:outbound_drain_batch_size` | `PARRHESIA_LIMITS_OUTBOUND_DRAIN_BATCH_SIZE` | `64` |
| `:outbound_overflow_strategy` | `PARRHESIA_LIMITS_OUTBOUND_OVERFLOW_STRATEGY` | `:close` |
| `:max_negentropy_payload_bytes` | `PARRHESIA_LIMITS_MAX_NEGENTROPY_PAYLOAD_BYTES` | `4096` |
| `:max_negentropy_sessions_per_connection` | `PARRHESIA_LIMITS_MAX_NEGENTROPY_SESSIONS_PER_CONNECTION` | `8` |
| `:max_negentropy_total_sessions` | `PARRHESIA_LIMITS_MAX_NEGENTROPY_TOTAL_SESSIONS` | `10000` |
| `:max_negentropy_items_per_session` | `PARRHESIA_LIMITS_MAX_NEGENTROPY_ITEMS_PER_SESSION` | `50000` |
| `:negentropy_id_list_threshold` | `PARRHESIA_LIMITS_NEGENTROPY_ID_LIST_THRESHOLD` | `32` |
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

#### Listener-related Metrics Helpers

| Atom key | ENV | Default |
| --- | --- | --- |
| `:public.features.metrics.enabled` | `PARRHESIA_METRICS_ENABLED_ON_MAIN_ENDPOINT` | `true` |
| `:public` | `PARRHESIA_METRICS_PUBLIC` | `false` |
| `:private_networks_only` | `PARRHESIA_METRICS_PRIVATE_NETWORKS_ONLY` | `true` |
| `:allowed_cidrs` | `PARRHESIA_METRICS_ALLOWED_CIDRS` | `[]` |
| `:auth_token` | `PARRHESIA_METRICS_AUTH_TOKEN` | `nil` |

#### `:retention`

| Atom key | ENV | Default | Notes |
| --- | --- | --- | --- |
| `:check_interval_hours` | `PARRHESIA_RETENTION_CHECK_INTERVAL_HOURS` | `24` | Partition maintenance + pruning cadence |
| `:months_ahead` | `PARRHESIA_RETENTION_MONTHS_AHEAD` | `2` | Pre-create current month plus N future monthly partitions for `events` and `event_tags` |
| `:max_db_bytes` | `PARRHESIA_RETENTION_MAX_DB_BYTES` | `:infinity` | Interpreted as GiB threshold; accepts integer or `infinity` |
| `:max_months_to_keep` | `PARRHESIA_RETENTION_MAX_MONTHS_TO_KEEP` | `:infinity` | Keep at most N months (including current month); accepts integer or `infinity` |
| `:max_partitions_to_drop_per_run` | `PARRHESIA_RETENTION_MAX_PARTITIONS_TO_DROP_PER_RUN` | `1` | Safety cap for each maintenance run |

#### `:features`

| Atom key | ENV | Default |
| --- | --- | --- |
| `:verify_event_signatures` | `-` | `true` |
| `:nip_45_count` | `PARRHESIA_FEATURES_NIP_45_COUNT` | `true` |
| `:nip_50_search` | `PARRHESIA_FEATURES_NIP_50_SEARCH` | `true` |
| `:nip_77_negentropy` | `PARRHESIA_FEATURES_NIP_77_NEGENTROPY` | `true` |
| `:marmot_push_notifications` | `PARRHESIA_FEATURES_MARMOT_PUSH_NOTIFICATIONS` | `false` |

`:verify_event_signatures` is config-file only. Production releases always verify event signatures.

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
_build/prod/rel/parrhesia/bin/parrhesia start
```

For systemd/process managers, run the release command with `start`.

### Option B: Nix release package (`default.nix`)

Build:

```bash
nix build
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

The benchmark compares two Parrhesia profiles, one backed by PostgreSQL and one backed by the in-memory adapter, against [`strfry`](https://github.com/hoytech/strfry) and [`nostr-rs-relay`](https://sr.ht/~gheartsfield/nostr-rs-relay/) using [`nostr-bench`](https://github.com/rnostr/nostr-bench). The cloud benchmark target set also includes [`nostream`](https://github.com/Cameri/nostream) and [`Haven`](https://github.com/bitvora/haven). Benchmark runs also lift Parrhesia's relay-side limits by default so the benchmark client, not server guardrails, is the main bottleneck.

`just bench compare` is a sequential mixed-workload benchmark, not an isolated per-endpoint microbenchmark. Each relay instance runs `connect`, then `echo`, then `event`, then `req` against the same live process, so later phases measure against state and load created by earlier phases.

Run it with:

```bash
just bench compare
```

### Cloud benchmark (Hetzner Cloud)

For distributed runs (one server node + multiple client nodes), use:

```bash
just bench cloud
# or: ./scripts/run_bench_cloud.sh
```

or invoke the orchestrator directly:

```bash
node scripts/cloud_bench_orchestrate.mjs
```

Prerequisites:

- [`hcloud`](https://github.com/hetznercloud/cli) CLI installed
- Hetzner Cloud token exported as `HCLOUD_TOKEN`
- local `docker`, `git`, `ssh`, and `scp` available

Example:

```bash
export HCLOUD_TOKEN=...
just bench cloud-quick
# or: ./scripts/run_bench_cloud.sh --quick
```

Outputs:

- raw client logs per run: `bench/cloud_artifacts/<run_id>/...`
- JSONL history entries (local + cloud): `bench/history.jsonl`

Useful history/render commands:

```bash
# List available machines and runs in history
just bench list

# Regenerate chart + README table for a machine
just bench update <machine_id>

# Regenerate from all machines
just bench update all
```

Current comparison results:

| metric | parrhesia-pg | parrhesia-mem | strfry | nostr-rs-relay | mem/pg | strfry/pg | nostr-rs-relay/pg |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| connect avg latency (ms) ↓ | 34.67 | 43.33 | 2.67 | 2.67 | 1.25x | **0.08x** | **0.08x** |
| connect max latency (ms) ↓ | 61.67 | 74.67 | 4.67 | 4.00 | 1.21x | **0.08x** | **0.06x** |
| echo throughput (TPS) ↑ | 72441.00 | 62704.67 | 61189.33 | 152654.33 | 0.87x | 0.84x | **2.11x** |
| echo throughput (MiB/s) ↑ | 39.67 | 34.30 | 34.20 | 83.63 | 0.86x | 0.86x | **2.11x** |
| event throughput (TPS) ↑ | 1897.33 | 1370.00 | 3426.67 | 772.67 | 0.72x | **1.81x** | 0.41x |
| event throughput (MiB/s) ↑ | 1.23 | 0.87 | 2.20 | 0.50 | 0.70x | **1.78x** | 0.41x |
| req throughput (TPS) ↑ | 13.33 | 47.00 | 1811.33 | 878.33 | **3.52x** | **135.85x** | **65.88x** |
| req throughput (MiB/s) ↑ | 0.03 | 0.17 | 11.77 | 2.40 | **5.00x** | **353.00x** | **72.00x** |

Higher is better for `↑` metrics. Lower is better for `↓` metrics.

(Results from a Linux container on a 6-core Intel i5-8400T with NVMe drive, PostgreSQL 18)

![Benchmark chart](./bench/chart.svg)

---

## Development quality checks

Before opening a PR:

```bash
mix precommit
```

Additional external CLI end-to-end checks with `nak`:

```bash
just e2e nak
```

For Marmot client end-to-end checks (TypeScript/Node suite using `marmot-ts`, included in `precommit`):

```bash
just e2e marmot
```

```
