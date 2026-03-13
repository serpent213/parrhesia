# Parrhesia Nostr Relay Architecture

## 1) Goals

Build a **robust, high-performance Nostr relay** in Elixir/OTP with PostgreSQL as first adapter, while keeping a strict boundary so storage can be swapped later.

Primary targets:

- Broad relay feature support (core + modern relay-facing NIPs)
- Strong correctness around NIP-01 semantics
- Clear OTP supervision and failure isolation
- High fanout throughput and bounded resource usage
- Storage abstraction via behavior-driven ports/adapters
- Full test suite (unit, integration, conformance, perf, fault-injection)
- Support for experimental MLS flow (NIP-EE), behind feature flags

## 2) NIP support scope

### Mandatory baseline

- NIP-01 (includes behavior moved from NIP-12/NIP-16/NIP-20/NIP-33)
- NIP-11 (relay info document)

### Relay-facing features to include

- NIP-09 (deletion requests)
- NIP-13 (PoW gating)
- NIP-17 + NIP-44 + NIP-59 (private DMs / gift wraps)
- NIP-40 (expiration)
- NIP-42 (AUTH)
- NIP-43 (relay membership requests/metadata)
- NIP-45 (COUNT, optional HLL)
- NIP-50 (search)
- NIP-62 (request to vanish)
- NIP-66 (relay discovery events; store/serve as normal events)
- NIP-70 (protected events)
- NIP-77 (negentropy sync)
- NIP-86 + NIP-98 (relay management API auth)

### Experimental MLS

- NIP-EE (unrecommended/upstream-superseded, but requested):
  - kind `443` KeyPackage events
  - kind `445` group events (policy-controlled retention/ephemeral treatment)
  - kind `10051` keypackage relay lists
  - interop with wrapped delivery (`1059`) and auth/privacy policies

## 3) System architecture (high level)

```text
WS/HTTP Edge (Bandit/Plug)
  -> Protocol Decoder/Encoder
  -> Command Router (EVENT/REQ/CLOSE/AUTH/COUNT/NEG-*)
  -> Policy Pipeline (validation, auth, ACL, PoW, NIP-70)
  -> Event Service / Query Service
       -> Storage Port (behavior)
           -> Postgres Adapter (Ecto)
       -> Subscription Index (ETS)
       -> Fanout Dispatcher
  -> Telemetry + Metrics + Tracing
```

## 4) OTP supervision design

`Parrhesia.Application` children (top-level):

1. `Parrhesia.Telemetry` – metric definitions/reporters
2. `Parrhesia.Config` – runtime config cache (ETS-backed)
3. `Parrhesia.Storage.Supervisor` – adapter processes (`Repo`, pools)
4. `Parrhesia.Subscriptions.Supervisor` – subscription index + fanout workers
5. `Parrhesia.Auth.Supervisor` – AUTH challenge/session tracking
6. `Parrhesia.Policy.Supervisor` – rate limiters / ACL caches
7. `Parrhesia.Web.Endpoint` – WS + HTTP ingress
8. `Parrhesia.Tasks.Supervisor` – background jobs (expiry purge, maintenance)

Failure model:

- Connection failures are isolated per socket process.
- Storage outages degrade with explicit `OK/CLOSED` error prefixes (`error:`) per NIP-01.
- Non-critical workers are `:transient`; core infra is `:permanent`.

## 5) Core runtime components

### 5.1 Connection process

Per websocket connection:

- Parse frames, enforce max frame/message limits
- Maintain authenticated pubkeys (NIP-42)
- Track active subscriptions (`sub_id` scoped to connection)
- Handle backpressure (bounded outbound queue + drop/close strategy)

### 5.2 Command router

Dispatches:

- `EVENT` -> ingest pipeline
- `REQ` -> initial DB query + live subscription
- `CLOSE` -> unsubscribe
- `AUTH` -> challenge validation, session update
- `COUNT` -> aggregate path
- `NEG-OPEN`/`NEG-MSG`/`NEG-CLOSE` -> negentropy session engine

### 5.3 Event ingest pipeline

Ordered stages:

1. Decode + schema checks
2. `id` recomputation and signature verification
3. NIP semantic checks (timestamps, tag forms, size limits)
4. Policy checks (banlists, kind allowlists, auth-required, NIP-70, PoW)
5. Storage write (or no-store for ephemeral policy)
6. Live fanout to matching subscriptions
7. Return canonical `OK` response with machine prefix when needed

### 5.4 Subscription index + fanout

- ETS-backed inverted indices (`kind`, `author`, single-letter tags)
- Candidate narrowing before full filter evaluation
- OR semantics across filters, AND within filter
- `limit` only for initial query phase; ignored in live phase (NIP-01)

### 5.5 Query service

- Compiles NIP filters into adapter-neutral query AST
- Pushes AST to storage adapter
- Deterministic ordering (`created_at` desc, `id` lexical tie-break)
- Emits `EOSE` exactly once per subscription initial catch-up

## 6) Storage boundary (swap-friendly by design)

### 6.1 Port/adapter contract

Define behaviors under `Parrhesia.Storage`:

- `Parrhesia.Storage.Events`
  - `put_event/2`, `get_event/2`, `query/3`, `count/3`
  - `delete_by_request/2`, `vanish/2`, `purge_expired/1`
- `Parrhesia.Storage.Moderation`
  - pubkey/event bans, allowlists, blocked IPs
- `Parrhesia.Storage.Groups`
  - NIP-29/NIP-43 membership + role operations
- `Parrhesia.Storage.Admin`
  - backing for NIP-86 methods

All domain logic depends only on these behaviors.

### 6.2 Postgres adapter notes

Initial adapter: `Parrhesia.Storage.Adapters.Postgres` with Ecto.

Schema outline:

- `events` (id PK, pubkey, created_at, kind, content, sig, d_tag, deleted_at, expires_at)
- `event_tags` (event_id, name, value, idx)
- moderation tables (banned/allowed pubkeys, banned events, blocked IPs)
- relay/group membership tables
- optional count/HLL helper tables

Indexing strategy:

- `(kind, created_at DESC)`
- `(pubkey, created_at DESC)`
- `(created_at DESC)`
- `(name, value, created_at DESC)` on `event_tags`
- partial/unique indexes for replaceable and addressable semantics

Retention strategy:

- Optional table partitioning by time for hot pruning
- Periodic purge job for expired/deleted tombstoned rows

## 7) Feature-specific implementation notes

### 7.1 NIP-11

- Serve on WS URL with `Accept: application/nostr+json`
- Include accurate `supported_nips` and `limitation`

### 7.2 NIP-42 + NIP-70

- Connection-scoped challenge store
- Protected (`["-"]`) events rejected by default unless auth+pubkey match

### 7.3 NIP-17/59 privacy guardrails

- Relay can enforce recipient-only reads for kind `1059` (AUTH required)
- Query path validates requester access for wrapped DM fetches

### 7.4 NIP-45 COUNT

- Exact count baseline
- Optional approximate mode and HLL payloads for common queries

### 7.5 NIP-50 search

- Use Postgres FTS (`tsvector`) with ranking
- Apply `limit` after ranking

### 7.6 NIP-77 negentropy

- Track per-negentropy-session state in dedicated GenServer
- Use bounded resources + inactivity timeout

### 7.7 NIP-62 vanish

- Hard-delete all events by pubkey up to `created_at`
- Also delete matching gift wraps where feasible (`#p` target)
- Persist minimal audit record if needed for operations/legal trace

### 7.8 NIP-EE MLS (feature-flagged)

- Accept/store kind `443` KeyPackage events
- Process kind `445` under configurable retention policy (default short TTL)
- Ensure kind `10051` replaceable semantics
- Keep relay MLS-agnostic cryptographically (no MLS decryption in relay path)

## 8) Performance model

- Bounded mailbox and queue limits on connections
- ETS-heavy hot path (subscription match, auth/session cache)
- DB writes batched where safe; reads via prepared plans
- Avoid global locks; prefer partitioned workers and sharded ETS tables
- Telemetry-first tuning: p50/p95/p99 for ingest, query, fanout
- Expose Prometheus-compatible `/metrics` endpoint for scraping

Targets (initial):

- p95 EVENT ack < 50ms under nominal load
- p95 REQ initial response start < 120ms on indexed queries
- predictable degradation under overload via rate-limit + backpressure

## 9) Testing strategy (full suite)

1. **Unit tests**: parser, filter evaluator, policy predicates, NIP validators
2. **Property tests**: filter semantics, replaceable/addressable conflict resolution
3. **Adapter contract tests**: shared behavior tests run against Postgres adapter
4. **Integration tests**: websocket protocol flows (`EVENT/REQ/CLOSE/AUTH/COUNT/NEG-*`)
5. **NIP conformance tests**: machine-prefix responses, ordering, EOSE behavior
6. **MLS scenario tests**: keypackage/group-event acceptance and policy handling
7. **Performance tests**: soak + burst + large fanout profiles
8. **Fault-injection tests**: DB outage, slow query, connection churn, node restart

## 10) Implementation principles

- Keep relay event-kind agnostic by default; special-case only where NIPs require
- Prefer explicit feature flags for expensive/experimental modules
- No direct Ecto usage outside Postgres adapter and migration layer
- Every feature lands with tests + telemetry hooks

---

Implementation task breakdown is tracked in `./PROGRESS.md`.
