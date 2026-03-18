# Parrhesia Technical Audit

**Date:** 2026-03-17
**Reviewer:** BEAM Architecture & Security Specialist
**Version audited:** 0.5.0 (Alpha)
**Scope:** Full-spectrum audit — protocol compliance, architecture, OTP supervision, backpressure, data integrity, security

---

## Table of Contents

1. [Feature Parity & Protocol Completeness](#1-feature-parity--protocol-completeness)
2. [Architecture & Design Coherence](#2-architecture--design-coherence)
3. [OTP & Supervision Tree](#3-otp--supervision-tree)
4. [Backpressure & Load Handling](#4-backpressure--load-handling)
5. [Data Integrity & PostgreSQL](#5-data-integrity--postgresql)
6. [Security](#6-security)
7. [Overall Assessment](#7-overall-assessment)
8. [Prioritised Remediation List](#8-prioritised-remediation-list)

---

## 1. Feature Parity & Protocol Completeness

**Verdict: ⚠️ Concern — two ghost features, two partial implementations**

### Claimed NIPs: 1, 9, 11, 13, 17, 40, 42, 43, 44, 45, 50, 59, 62, 66, 70, 77, 86, 98

| NIP | Title | Status | Notes |
|-----|-------|--------|-------|
| 01 | Basic Protocol | ✅ Full | EVENT, REQ, CLOSE, EOSE, OK, NOTICE, CLOSED all correct |
| 09 | Event Deletion | ✅ Full | Kind 5 with `e`/`a`/`k` tags; author-only enforcement; soft delete |
| 11 | Relay Information | ✅ Full | `application/nostr+json` on same URI; limitations section present |
| 13 | Proof of Work | ✅ Full | Leading-zero-bit calculation; configurable `min_pow_difficulty` |
| 17 | Private DMs | ⚠️ Partial | Kind 14/15 accepted; encryption/decryption client-side only; relay stores giftwraps transparently |
| 40 | Expiration | ✅ Full | Tag parsed at ingest; background worker for cleanup |
| 42 | Authentication | ✅ Full | Challenge/response with Kind 22242; freshness check; challenge rotation |
| 43 | Relay Access Metadata | ⚠️ Partial | Kind 13534 membership tracking present; join/leave request mechanics (28934/28935/28936) unimplemented |
| 44 | Encrypted Payloads | ✅ Full | Relay-transparent; version 2 format recognised |
| 45 | Count | ✅ Full | COUNT messages with optional HyperLogLog; `approximate` field |
| 50 | Search | ⚠️ Partial | Basic `ILIKE` substring match only; no tsvector/pg_trgm; no extensions (domain, language, sentiment) |
| 59 | Gift Wrap | ⚠️ Partial | Kind 1059/13 accepted; encryption at client level; recipient auth gating present |
| 62 | Request to Vanish | ✅ Full | Kind 62; relay tag requirement; `ALL_RELAYS` support; hard delete |
| **66** | **Relay Discovery** | **🔴 Ghost** | **Listed in `supported_nips` but no relay-specific liveness/discovery logic exists. Kinds 30166/10166 stored as regular events only.** |
| 70 | Protected Events | ✅ Full | `["-"]` tag detection; AUTH required; pubkey matching |
| 77 | Negentropy Sync | ✅ Full | NEG-OPEN/MSG/CLOSE/ERR; session management; configurable limits |
| 86 | Management API | ✅ Full | JSON-RPC over HTTP; NIP-98 auth; full moderation method set |
| 98 | HTTP Auth | ✅ Full | Kind 27235; URL/method binding; SHA256 payload hash; freshness |

### Ghost Features

1. **NIP-66 (Relay Discovery and Liveness Monitoring)** — Listed in supported NIPs but the relay performs no special handling for kinds 30166 or 10166. They are accepted and stored as generic events. No liveness data generation exists. **Remove from `supported_nips` or implement.**

2. **NIP-43 (Relay Access Metadata)** — Group membership tracking (kind 13534, 8000, 8001) is present, but the join/leave request mechanics (kinds 28934, 28935, 28936) and invite-code validation are absent. This is a partial implementation marketed as complete. **Document as partial or implement join/leave flow.**

### Undocumented Features

- **Marmot MLS groups** (kinds 443-449) with specialised media validation, push notification policies, and `h`-tag scoping are implemented but are not standard NIPs. These are correctly treated as extensions rather than NIP claims.

### Remediation

| Item | Action | File(s) |
|------|--------|---------|
| NIP-66 ghost | Remove from `supported_nips` in `relay_info.ex` | `lib/parrhesia/web/relay_info.ex` |
| NIP-43 partial | Document as partial or implement join/leave | `lib/parrhesia/groups/flow.ex` |
| NIP-50 extensions | Consider tsvector for FTS; document missing extensions | `lib/parrhesia/storage/adapters/postgres/events.ex` |

---

## 2. Architecture & Design Coherence

**Verdict: ✅ Sound — clean layered architecture with proper separation of concerns**

### Layer Map

```
┌─────────────────────────────────────────────────────┐
│  Transport Layer (Bandit + WebSock)                  │
│  lib/parrhesia/web/                                  │
│  connection.ex · router.ex · endpoint.ex · listener  │
├─────────────────────────────────────────────────────┤
│  Protocol Layer (codec + validation)                 │
│  lib/parrhesia/protocol/                             │
│  protocol.ex · event_validator.ex · filter.ex        │
├─────────────────────────────────────────────────────┤
│  API Layer (domain operations)                       │
│  lib/parrhesia/api/                                  │
│  events.ex · auth.ex · stream.ex · sync.ex · admin   │
├─────────────────────────────────────────────────────┤
│  Policy Layer (authorisation & rules)                │
│  lib/parrhesia/policy/                               │
│  event_policy.ex · connection_policy.ex              │
├─────────────────────────────────────────────────────┤
│  Storage Layer (adapter pattern)                     │
│  lib/parrhesia/storage/                              │
│  behaviours → postgres adapters · memory adapters    │
└─────────────────────────────────────────────────────┘
```

### Strengths

- **Clean adapter pattern**: Storage behaviours (`Storage.Events`, `Storage.Moderation`, etc.) are resolved at runtime via `Parrhesia.Storage`. PostgreSQL and in-memory implementations are interchangeable.
- **Protocol layer is pure**: `Protocol.decode_client/1` and `Protocol.encode_relay/1` contain no side effects — they are pure codecs. Validation is separated into `EventValidator`.
- **API layer mediates all domain logic**: `API.Events.publish/2` orchestrates validation → policy → persistence → fanout. The web layer never touches the DB directly.
- **Connection handler is a state machine**: `Web.Connection` implements `WebSock` behaviour cleanly — no business logic bleeds in; it delegates to API functions.
- **Configuration is centralised**: `Parrhesia.Config` provides an ETS-backed config cache with runtime environment override support via 50+ env vars.

### Concerns

- **Connection handler size**: `web/connection.ex` is a large module handling all WebSocket message dispatch. While each handler delegates to API, the dispatch surface is wide. Consider extracting message handlers into sub-modules.
- **Fanout is embedded in API.Events**: The `fanout_event/1` call inside `publish/2` couples persistence with subscription delivery. Under extreme load, this means the publisher blocks on fanout. Decoupling into an async step would improve isolation.

### Scalability Assessment

The architecture would scale gracefully to moderate load (thousands of concurrent connections) without a rewrite. For truly high-volume deployments (10k+ connections, 100k+ events/sec), the synchronous fanout path and lack of global rate limiting would need attention. The BEAM's per-process isolation provides natural horizontal scaling if combined with a load balancer.

---

## 3. OTP & Supervision Tree

**Verdict: ✅ Sound — exemplary OTP compliance with zero unsafe practices**

### Supervision Hierarchy

```
Parrhesia.Supervisor (:one_for_one)
├── Telemetry (Supervisor, :one_for_one)
│   ├── TelemetryMetricsPrometheus.Core
│   └── :telemetry_poller
├── Config (GenServer, ETS-backed)
├── Storage.Supervisor (:one_for_one)
│   ├── ModerationCache (GenServer)
│   └── Repo (Ecto.Repo)
├── Subscriptions.Supervisor (:one_for_one)
│   ├── Index (GenServer, 7 ETS tables)
│   ├── Stream.Registry (Registry)
│   ├── Stream.Supervisor (DynamicSupervisor)
│   │   └── [dynamic] Stream.Subscription (GenServer, :temporary)
│   ├── Negentropy.Sessions (GenServer)
│   └── Fanout.MultiNode (GenServer, :pg group)
├── Auth.Supervisor (:one_for_one)
│   ├── Challenges (GenServer)
│   └── Identity.Manager (GenServer)
├── Sync.Supervisor (:one_for_one)
│   ├── WorkerRegistry (Registry)
│   ├── WorkerSupervisor (DynamicSupervisor)
│   │   └── [dynamic] Sync.Worker (GenServer, :transient)
│   └── Sync.Manager (GenServer)
├── Policy.Supervisor (:one_for_one) [empty — stateless modules]
├── Web.Endpoint (Supervisor, :one_for_one)
│   └── [per-listener] Bandit
│       └── [per-connection] Web.Connection (WebSock)
└── Tasks.Supervisor (:one_for_one)
    ├── ExpirationWorker (GenServer, optional)
    └── PartitionRetentionWorker (GenServer)
```

### Findings

| Check | Result |
|-------|--------|
| Bare `spawn()` calls | ✅ None found |
| `Task.start` without supervision | ✅ None found |
| `Task.async` without supervision | ✅ None found |
| Unsupervised `Process.` calls | ✅ None found |
| All `Process.monitor` paired with `Process.demonitor(ref, [:flush])` | ✅ Confirmed in Index, Challenges, Subscription, Sessions |
| Restart strategies appropriate | ✅ All `:one_for_one` — children are independent |
| `:transient` for Sync.Worker | ✅ Correct — no restart on normal shutdown |
| `:temporary` for Stream.Subscription | ✅ Correct — never restart dead subscriptions |
| Crash cascade possibility | ✅ None — all supervisors isolate failures |
| Deadlock potential | ✅ None — no circular GenServer calls detected |
| ETS table ownership | ✅ Owned by supervising GenServer; recreated on restart |

### Minor Observations

- **Policy.Supervisor is empty**: Contains no children (stateless policy modules). Exists as a future extension point — no performance cost.
- **Identity.Manager** silently catches init failures: Returns `{:ok, %{}}` even if identity setup fails. Correct for startup resilience but consider a telemetry event for visibility.
- **4-level max depth** in the tree: Optimal — deep enough for isolation, shallow enough for comprehension.

---

## 4. Backpressure & Load Handling

**Verdict: ⚠️ Concern — per-connection defences are solid; global protection is absent**

### What Exists

| Mechanism | Implementation | Default | Location |
|-----------|---------------|---------|----------|
| Per-connection event rate limit | Window-based counter | 120 events/sec | `connection.ex:1598-1624` |
| Per-connection subscription cap | Hard limit at REQ time | 32 subs | `connection.ex:1098-1109` |
| Per-connection outbound queue | Bounded `:queue` | 256 entries | `connection.ex` state |
| Outbound overflow strategy | `:close` / `:drop_newest` / `:drop_oldest` | `:close` | `connection.ex:987-1013` |
| Negentropy session limits | Per-connection + global cap | 8/conn, 10k global | `negentropy/sessions.ex` |
| Filter count per REQ | Hard limit | 16 filters | `connection.ex` |
| Queue pressure telemetry | Pressure gauge (0-1 scale) | Alert at ≥ 0.75 | `telemetry.ex:57-81` |

### What's Missing

| Gap | Risk | Recommendation |
|-----|------|----------------|
| **No GenStage/Broadway backpressure** | Event ingestion is synchronous — publisher blocks on DB write + fanout | Consider async fanout via GenStage or Task.Supervisor |
| **No global rate limit** | 1000 connections × 120 evt/s = 120k evt/s with no relay-wide cap | Add global event counter with configurable ceiling |
| **No connection cap** | Bandit accepts unlimited connections up to OS limits | Set `max_connections` in Bandit options or add a plug-based cap |
| **No per-IP rate limit** | Single IP can open many connections, each with independent limits | Add IP-level rate limiting or document reverse-proxy requirement |
| **No subscription index size cap** | Global ETS subscription index can grow unbounded | Add global subscription count metric + circuit breaker |
| **Synchronous fanout** | `fanout_event/1` iterates all matching subs in publisher's process | Decouple fanout into async dispatch |
| **No read/write pool separation** | Writes can starve read queries under heavy ingest | Consider separate Ecto repos or query prioritisation |
| **No graceful drain on shutdown** | Listener shutdown doesn't flush queued events | Add drain timer before connection termination |
| **No mailbox depth monitoring** | `Process.info(pid, :message_queue_len)` never checked | Add periodic mailbox depth telemetry for subscription processes |

### Blast Radius: Flood Attack Scenario

A high-volume client flooding the relay with valid events at maximum rate:

1. **120 events/sec per connection** — rate-limited per-connection ✅
2. **But**: attacker opens 100 connections from different IPs → 12k events/sec ⚠️
3. Each event hits the Ecto pool (32 connections) → pool saturation at ~100 concurrent writes
4. Fanout blocks publisher process → connection mailbox grows
5. No global circuit breaker → relay degrades gradually via Ecto queue timeouts
6. Memory grows in subscription process mailboxes → eventual OOM

**Mitigation**: Deploy behind a reverse proxy (nginx/HAProxy) with connection and rate limits. This is a common pattern for BEAM applications but should be documented as a deployment requirement.

---

## 5. Data Integrity & PostgreSQL

**Verdict: ✅ Sound — well-designed schema with strong indexing; minor gaps in constraints and FTS**

### Schema Overview

Events are stored in monthly RANGE-partitioned tables keyed on `created_at`:

```sql
events (PARTITION BY RANGE (created_at))
  id         bytea (32 bytes, SHA256)
  pubkey     bytea (32 bytes)
  created_at bigint (unix timestamp, partition key)
  kind       integer
  content    text
  sig        bytea (64 bytes)
  d_tag      text (nullable, for addressable events)
  tags       jsonb (denormalised tag array)
  deleted_at bigint (soft delete)
  expires_at bigint (NIP-40)

event_tags (PARTITION BY RANGE (event_created_at))
  event_created_at  bigint
  event_id          bytea
  name              text
  value             text
  idx               integer

-- State tables for NIP-16 replaceable/addressable events
replaceable_event_state (pubkey, kind → event_id, created_at)
addressable_event_state (pubkey, kind, d_tag → event_id, created_at)
```

### Indexing Strategy: ✅ Excellent

| Index | Columns | Purpose | Assessment |
|-------|---------|---------|------------|
| `events_kind_created_at_idx` | (kind, created_at DESC) | Kind filter | ✅ Primary access pattern |
| `events_pubkey_created_at_idx` | (pubkey, created_at DESC) | Author filter | ✅ Primary access pattern |
| `events_created_at_idx` | (created_at DESC) | Time range | ✅ Partition pruning |
| `events_id_idx` | (id) | Direct lookup / dedup | ✅ Essential |
| `events_expires_at_idx` | Partial, WHERE expires_at IS NOT NULL | Expiration worker | ✅ Space-efficient |
| `events_deleted_at_idx` | Partial, WHERE deleted_at IS NOT NULL | Soft-delete filter | ✅ Space-efficient |
| `event_tags_name_value_idx` | (name, value, event_created_at DESC) | Generic tag lookup | ✅ Covers all tag queries |
| `event_tags_i_idx` | Partial (value, event_created_at) WHERE name='i' | Hashtag lookups | ✅ Optimised for common pattern |
| `event_tags_h_idx` | Partial (value, event_created_at) WHERE name='h' | Group/relay hint | ✅ Marmot-specific optimisation |

### Query Construction: ✅ Sound

Nostr filters are translated to Ecto queries via `postgres/events.ex`:
- Single-filter: composed dynamically with `where/3` clauses
- Multi-filter: `UNION ALL` of individual filter queries, then Elixir-level dedup
- Tag filters: primary tag uses index join; secondary tags use `EXISTS` subqueries (properly parameterised)
- All values bound via Ecto's `^` operator — no SQL injection vectors

### N+1 Analysis: ✅ No Critical Issues

- Tag filtering uses `EXISTS` subqueries rather than joins — one query per filter, not per tag
- Multiple filters produce N queries (one per filter), not N per subscription
- `max_filters_per_req: 16` bounds this naturally
- Deduplication is done in Elixir (`MapSet`) after DB fetch — acceptable for bounded result sets

### Issues Found

| Issue | Severity | Detail | Remediation |
|-------|----------|--------|-------------|
| **No CHECK constraints on binary lengths** | Low | `id`, `pubkey`, `sig` have no `octet_length` checks at DB level | Add `CHECK (octet_length(id) = 32)` etc. via migration |
| **No length constraint on `d_tag`** | Low | Unbounded text field; could store arbitrarily large values | Add `CHECK (octet_length(d_tag) <= 256)` |
| **FTS is ILIKE-based** | Medium | NIP-50 search uses `ILIKE '%term%'` — linear scan, no ranking | Implement `tsvector` with GIN index for production-grade search |
| **Replaceable state race condition** | Low | SELECT → INSERT pattern in `insert_state_or_resolve_race/2` has a TOCTOU window | Mitigated by `ON CONFLICT :nothing` + retry, but native `ON CONFLICT DO UPDATE` would be cleaner |
| **Redundant tag storage** | Info | Tags stored in both `event_tags` table and `events.tags` JSONB column | Intentional denormalisation for different access patterns; documented tradeoff |
| **No indexes on state tables** | Low | `replaceable_event_state` and `addressable_event_state` lack explicit indexes | These are likely small tables; monitor query plans under load |

### Partitioning: ✅ Excellent

- Monthly partitions (`events_YYYY_MM`, `event_tags_YYYY_MM`) with lifecycle automation
- Default partition catches edge-case timestamps
- Retention worker pre-creates 2 months ahead; caps drops at 1 partition per run
- `protected_partition?/1` prevents accidental drop of parent/default
- Detach-before-drop pattern for safe concurrent operation

### Connection Pooling: ✅ Well-Configured

- Pool: 32 connections (configurable via `POOL_SIZE`)
- Queue target: 1000ms / Queue interval: 5000ms
- Standard Ecto queue management with graceful degradation

---

## 6. Security

### 6.1 Signature Validation

**Verdict: ✅ Sound**

- **Library**: `lib_secp256k1` (NIF-based Schnorr implementation)
- **Flow**: `API.Events.publish/2` → `Protocol.validate_event/1` → `EventValidator.validate_signature/1` → `Secp256k1.schnorr_valid?/3`
- **Timing**: Validation occurs BEFORE any database write — `persist_event/2` is only called after validation passes (`api/events.ex:41-44`)
- **Hex decoding**: Properly decodes hex sig/id/pubkey to binary before crypto verification
- **Error handling**: Wrapped in rescue clause; returns `{:error, :invalid_signature}`

**Concern**: Feature flag `verify_event_signatures` can disable verification. Currently only `false` in `test.exs`. **Ensure this is never disabled in production config.** Consider adding a startup assertion.

### 6.2 SQL Injection

**Verdict: ✅ Sound — all queries parameterised**

- Only 2 `fragment()` uses in `postgres/events.ex`, both with bound parameters:
  ```elixir
  fragment("EXISTS (SELECT 1 FROM event_tags AS tag WHERE
    tag.event_created_at = ? AND tag.event_id = ? AND tag.name = ? AND tag.value = ANY(?))",
    event.created_at, event.id, ^tag_name, type(^values, {:array, :string}))
  ```
- All dynamic query conditions built via Ecto's `dynamic()` macro with `^` bindings
- No string interpolation of user input in any query path
- No calls to `Ecto.Adapters.SQL.query/3` with raw SQL

### 6.3 Resource Exhaustion

**Verdict: ⚠️ Concern — payload size enforced but tag arrays unbounded**

| Control | Status | Default | Location |
|---------|--------|---------|----------|
| Max frame size | ✅ Enforced | 1 MB | `connection.ex:135-140` (before JSON parse) |
| Max event size | ✅ Enforced | 256 KB | `api/events.ex:40` (after JSON parse, before DB) |
| Max filters per REQ | ✅ Enforced | 16 | `connection.ex` |
| Max filter limit | ✅ Enforced | 500 | `filter.ex` |
| Max subscriptions | ✅ Enforced | 32/conn | `connection.ex:1098` |
| **Max tags per event** | **🔴 Missing** | **None** | **Event with 10k tags accepted if within 256KB** |
| **Max tag values per filter** | **🔴 Missing** | **None** | **Filter with 1000 `#p` values generates expensive query** |
| **Max content field size** | **⚠️ Indirect** | **256KB overall** | **No separate limit; large content consumes storage** |
| Max negentropy sessions | ✅ Enforced | 8/conn, 10k global | `negentropy/sessions.ex` |
| Event rate limit | ✅ Enforced | 120/sec/conn | `connection.ex:1598` |

**Remediation**: Add configurable `max_tags_per_event` and `max_tag_values_per_filter` limits.

### 6.4 NIP-42 AUTH Flow

**Verdict: ✅ Sound**

- Challenge generated with 16 bytes of cryptographic randomness (`Auth.Challenges`)
- Challenge is connection-scoped (one per connection, tracked by PID)
- On successful AUTH: challenge is rotated via `rotate_auth_challenge/1`
- Freshness validated: `created_at` must be within `max_age_seconds` (default 600s)
- Relay URL tag must match connection's relay URL
- Process monitoring cleans up challenges when connections die

### 6.5 NIP-98 HTTP Auth

**Verdict: ⚠️ Concern — token replay window**

- **Signature**: Properly verified via same `EventValidator.validate/1` path ✅
- **URL binding**: Exact method + URL match required ✅
- **Freshness**: 60-second window ✅
- **🔴 Token reuse**: Signed NIP-98 events are NOT invalidated after use. Within the 60-second window, the same signed event can be replayed on the same endpoint.
- **Remediation**: Track used event IDs in a TTL-expiring ETS table or similar. Reject events with previously-seen IDs.

### 6.6 Injection Surfaces

**Verdict: ✅ Sound**

- All filter tag values parameterised through Ecto
- LIKE patterns properly escaped via `escape_like_pattern/1` (`%`, `_`, `\` escaped)
- Event field validation is comprehensive:
  - IDs/pubkeys: 64-char lowercase hex (32 bytes)
  - Signatures: 128-char lowercase hex (64 bytes)
  - Kinds: integer 0-65535
  - Tags: validated as non-empty string arrays

### 6.7 Other Security Notes

- **No `IO.inspect` of sensitive data**: Only 2 uses, both for config logging
- **No hardcoded secrets**: All credentials from environment variables
- **Binary frames rejected**: WebSocket handler only accepts text frames
- **Subscription ID validated**: Non-empty, max 64 chars

---

## 7. Overall Assessment

Parrhesia is a **well-engineered Nostr relay** that demonstrates expert-level Elixir/OTP knowledge and careful attention to the Nostr protocol. The codebase is clean, layered, and maintainable.

### Strengths

- **Exemplary OTP architecture**: Zero unsafe practices; proper supervision, monitoring, and crash isolation throughout
- **Clean separation of concerns**: Transport → Protocol → API → Policy → Storage layers with no bleed-through
- **Adapter pattern for storage**: PostgreSQL and in-memory backends are interchangeable — excellent for testing
- **Comprehensive protocol support**: 14 of 18 claimed NIPs fully implemented
- **Strong input validation**: All event fields rigorously validated; SQL injection surface is nil
- **Signature-first validation**: Schnorr verification occurs before any persistence — correct ordering
- **Rich telemetry**: Queue depth, pressure, overflow, ingest/query/fanout latency all instrumented
- **Production-ready partitioning**: Monthly partitions with automated lifecycle management
- **Extensive test coverage**: Unit, integration, and E2E test suites with property-based testing

### Weaknesses

- **No global load protection**: Per-connection limits exist but no relay-wide circuit breakers
- **Synchronous fanout**: Publisher blocks on subscription delivery — could bottleneck under high cardinality
- **NIP-50 search is ILIKE-based**: Will not scale; needs tsvector/GIN for production workloads
- **Two ghost NIPs**: NIP-66 and NIP-43 (partial) claimed but not meaningfully implemented
- **NIP-98 token replay**: 60-second replay window without event ID deduplication
- **Unbounded tag arrays**: No limit on tags per event or tag values per filter

---

## 8. Prioritised Remediation List

### 🔴 Critical (address before production)

| # | Issue | Impact | Fix |
|---|-------|--------|-----|
| 1 | **Unbounded tag arrays** | Event with 10k tags causes expensive DB inserts and index bloat; filter with 1000 tag values generates pathologically expensive queries | Add `max_tags_per_event` (e.g., 2000) and `max_tag_values_per_filter` (e.g., 256) to config and enforce in `event_validator.ex` and `filter.ex` |
| 2 | **No global rate limiting** | No relay-wide cap on event throughput; many connections can overwhelm DB pool | Add global event counter (ETS atomic) with configurable ceiling; return `rate-limited:` when exceeded |
| 3 | **NIP-98 token replay** | Signed management API tokens replayable within 60s window | Track used NIP-98 event IDs in TTL-expiring store; reject duplicates in `auth/nip98.ex` |

### ⚠️ Important (address before scale)

| # | Issue | Impact | Fix |
|---|-------|--------|-----|
| 4 | **Synchronous fanout** | Publisher blocks while iterating all matching subscriptions; latency spikes under high subscription cardinality | Decouple `fanout_event/1` into async dispatch via `Task.Supervisor` or dedicated GenServer pool |
| 5 | **No connection cap** | Unlimited WebSocket connections accepted up to OS limits | Set `max_connections` in Bandit listener options; document reverse-proxy requirement |
| 6 | **NIP-50 FTS is ILIKE** | Linear scan of content column; unacceptable at scale | Add `tsvector` column + GIN index; update query to use `@@` operator |
| 7 | **Ghost NIP-66** | Claimed but unimplemented; misleads clients querying relay info | Remove 66 from `supported_nips` in `relay_info.ex` |
| 8 | **No DB pool separation** | Writes can starve reads under heavy ingest | Consider separate Ecto repo for reads, or use Ecto's `:queue_target` tuning |
| 9 | **Missing CHECK constraints** | Binary fields (`id`, `pubkey`, `sig`) lack length constraints at DB level | Add migration with `CHECK (octet_length(id) = 32)` etc. |

### 💡 Nice to Have

| # | Issue | Impact | Fix |
|---|-------|--------|-----|
| 10 | **NIP-43 partial** | Join/leave mechanics unimplemented | Document as partial or implement kinds 28934-28936 |
| 11 | **Signature verification feature flag** | Could be disabled in production config | Add startup assertion or compile-time check |
| 12 | **Mailbox depth monitoring** | No visibility into subscription process queue sizes | Add periodic `Process.info/2` telemetry for dynamic children |
| 13 | **Graceful shutdown drain** | No flush of queued events before connection termination | Add drain timer in listener reload/shutdown path |
| 14 | **Replaceable state race** | SELECT→INSERT TOCTOU in state tables | Refactor to native `ON CONFLICT DO UPDATE` |
| 15 | **Connection handler size** | `web/connection.ex` is large | Extract message handlers into sub-modules for maintainability |

---

*End of audit. Generated 2026-03-17.*
