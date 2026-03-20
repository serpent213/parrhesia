# Parrhesia Alpha Code Review

**Reviewer:** Claude Opus 4.6 (automated review)
**Date:** 2026-03-20
**Version:** 0.6.0
**Scope:** Full codebase review across 8 dimensions for alpha-to-beta promotion decision

---

## 1. Executive Summary

Parrhesia is a well-architected Nostr relay with mature OTP supervision design, comprehensive telemetry, and solid protocol implementation covering 15+ NIPs. The codebase demonstrates strong Elixir idioms — heavy ETS usage for hot paths, process monitoring for cleanup, and async-first patterns. The test suite (58 files, ~8K LOC) covers critical protocol paths including signature verification, malformed input rejection, and database integration.

**Most critical gaps:** No WebSocket-level ping/pong keepalives, no constant-time comparison for NIP-42 challenge validation, and the `effective_filter_limit` function can return `nil` when called outside the standard API path (though the default config sets `max_filter_limit: 500`). Property-based testing is severely underutilised despite `stream_data` being a dependency.

**Recommendation:** **Promote with conditions** — the codebase is production-quality for beta with two items to address first.

---

## 2. Dimension-by-Dimension Findings

### 2.1 Elixir Code Quality

**Rating: ✅ Good**

**Supervision tree:** Single-rooted `Parrhesia.Runtime` supervisor with `:one_for_one` strategy. 12 child supervisors/workers, each with appropriate isolation. Storage, subscriptions, auth, sync, policy, tasks, and web endpoint each have their own supervisor subtree. Restart strategies are correct — no `rest_for_one` or `one_for_all` where unnecessary.

**GenServer usage:** Idiomatic throughout. State-heavy GenServers (Subscriptions.Index, Auth.Challenges, Negentropy.Sessions) properly monitor owner processes and clean up via `:DOWN` handlers. Stateless dispatchers (Fanout.Dispatcher) use `cast` appropriately. No unnecessary `call` serialisation found.

**ETS usage:** 9+ ETS tables with appropriate access patterns:
- Config cache: `:public`, `read_concurrency: true` — correct for hot-path reads
- Rate limiters: `write_concurrency: true` — correct for high-throughput counters
- Subscription indices: `:protected`, `read_concurrency: true` — correct (only Index GenServer writes)

**Error handling:** Consistent `{:ok, _}` / `{:error, _}` tuples throughout the API layer. No bare `throw` found. Connection handler wraps external calls in try/catch to prevent cascade failures. Rate limiter fallback returns `:ok` on service unavailability (availability over correctness — documented trade-off).

**Pattern matching:** Exhaustive in message handling. Protocol decoder has explicit clauses for each message type with a catch-all error clause. Event validator chains `with` clauses with explicit error atoms.

**Potential bottlenecks:**
- `Subscriptions.Index` is a single GenServer handling all subscription mutations. Reads go through ETS (fast), but `upsert`/`remove` operations serialise through the GenServer. At very high subscription churn (thousands of REQ/CLOSE per second), this could become a bottleneck. Acceptable for beta.
- `Negentropy.Sessions` holds all session state in process memory. Capped at 10K sessions with idle sweep — adequate.

**Module structure:** Clean separation of concerns. `web/` for transport, `protocol/` for parsing/validation, `api/` for business logic, `storage/` for persistence with adapter pattern, `policy/` for authorisation. 99% of modules have `@moduledoc` and `@spec` annotations.

**Findings:**
- `connection.ex` is 1,925 lines — large but cohesive (per-connection state machine). Consider extracting queue management into a submodule in future.
- `storage/adapters/postgres/events.ex` is the heaviest module — handles normalisation, queries, and tag indexing. Well-factored internally.

---

### 2.2 Nostr Protocol Correctness (NIPs Compliance)

**Rating: ✅ Good**

**NIPs implemented (advertised via NIP-11):**
NIP-1, NIP-9, NIP-11, NIP-13, NIP-17, NIP-40, NIP-42, NIP-44, NIP-45, NIP-50, NIP-59, NIP-62, NIP-70, NIP-77, NIP-86, NIP-98. Conditional: NIP-43, NIP-66.

**NIP-01 (Core Protocol):**
- Event structure: 7 required fields validated (`id`, `pubkey`, `created_at`, `kind`, `tags`, `content`, `sig`)
- Event ID: SHA-256 over canonical JSON serialisation `[0, pubkey, created_at, kind, tags, content]` — verified in `validate_id_hash/1`
- Signature: BIP-340 Schnorr via `lib_secp256k1` — `Secp256k1.schnorr_valid?(id_bin, sig_bin, pubkey_bin)`
- Filters: `ids`, `authors`, `kinds`, `since`, `until`, `limit`, `search`, `#<letter>` tag filters — all implemented
- Messages: EVENT, REQ, CLOSE, NOTICE, OK, EOSE, COUNT, AUTH — all implemented with correct response format
- Subscription IDs: validated as non-empty strings, max 64 chars

**Event ID verification:** Correct. Computes SHA-256 over `JSON.encode!([0, pubkey_hex, created_at, kind, tags, content])` and compares against claimed `id`. Binary decoding verified.

**Signature verification:** Uses `lib_secp256k1` (wrapper around Bitcoin Core's libsecp256k1). Schnorr verification correct per BIP-340. Can be disabled via feature flag (appropriate for testing/development).

**Malformed event rejection:** Comprehensive. Invalid hex, wrong byte lengths, future timestamps (>15 min), non-integer kinds, non-string content, non-array tags — all produce specific error atoms returned via OK message with `false` status.

**Filter application:** Correct implementation. Each dimension (ids, authors, kinds, since, until, tags, search) is an independent predicate; all must match for a filter to match. Multiple filters are OR'd together (`matches_any?`).

**Spec deviations:**
- Tag filter values capped at 128 per filter (configurable) — stricter than spec but reasonable
- Max 16 filters per REQ (configurable) — reasonable relay policy
- Max 256 tags per event — reasonable relay policy
- Search is substring/FTS, not regex — spec doesn't mandate regex

---

### 2.3 WebSocket Handling

**Rating: ⚠️ Needs Work**

**Backpressure: ✅ Excellent.**
Three-tier strategy with configurable overflow behaviour:
1. `:close` (default) — closes connection on queue overflow with NOTICE
2. `:drop_newest` — silently drops incoming events
3. `:drop_oldest` — drops oldest queued event, enqueues new

Queue depth defaults: max 256, drain batch size 64. Pressure monitoring at 75% threshold emits telemetry. Batch draining prevents thundering herd.

**Connection cleanup: ✅ Solid.**
`terminate/1` removes subscriptions from global index, unsubscribes from streams, clears auth challenges, decrements connection stats. Process monitors in Index/Challenges/Sessions provide backup cleanup on unexpected exits.

**Message size limits: ✅ Enforced.**
- Frame size: 1MB default (`max_frame_bytes`), checked before JSON parsing
- Event size: 256KB default (`max_event_bytes`), checked before DB write
- Both configurable via environment variables

**Per-connection subscription limit: ✅ Enforced.**
Default 32 subscriptions per connection. Checked before opening new REQ. Returns CLOSED with `rate-limited:` prefix.

**Ping/pong keepalives: ⚠️ Not implemented (optional).**
No server-initiated WebSocket PING frames. RFC 6455 §5.5.2 makes PING optional ("MAY be sent"), and NIP-01 does not require keepalives. Bandit correctly responds to client-initiated PINGs per spec. However, server-side pings are a production best practice for detecting dead connections behind NAT/proxies — without them, the server relies on TCP-level detection which can take minutes.

**Per-connection event ingest rate limiting: ✅ Implemented.**
Default 120 events/second per connection with sliding window. Per-IP limiting at 1,000 events/second. Relay-wide cap at 10,000 events/second.

---

### 2.4 PostgreSQL / Database Layer

**Rating: ✅ Good**

**Schema design:**
- Events table range-partitioned by `created_at` (monthly partitions)
- Normalised `event_tags` table with composite FK to events
- JSONB `tags` column for efficient serialisation (denormalised copy of normalised tags)
- Binary storage for pubkeys/IDs/sigs with CHECK constraints on byte lengths

**Indexes:** Comprehensive and appropriate:
- `events(kind, created_at DESC)` — kind queries
- `events(pubkey, created_at DESC)` — author queries
- `events(created_at DESC)` — time-range queries
- `events(id)` — direct lookup
- `events(expires_at) WHERE expires_at IS NOT NULL` — expiration pruning
- `event_tags(name, value, event_created_at DESC)` — tag filtering
- GIN index on `to_tsvector('simple', content)` — full-text search
- GIN trigram index on `content` — fuzzy search

**Tag queries:** Efficient. Uses `EXISTS (SELECT 1 FROM event_tags ...)` subqueries with parameterised values. Primary tag filter applied first, remaining filters chained. No N+1 — bulk tag insert via `Repo.insert_all`.

**Connection pools:** Write pool (32 default) and optional separate read pool (32 default). Queue target/interval configured at 1000ms/5000ms. Pool sizing configurable via environment variables.

**Bounded results:** `max_filter_limit` defaults to 500 in config. Applied at query level via `LIMIT` clause. Post-query `Enum.take` as safety net. The `effective_filter_limit/2` function can return `nil` if both filter and opts lack a limit — but the standard API path always passes `max_filter_limit` from config.

**Event expiration:** NIP-40 `expiration` tags extracted during normalisation. `ExpirationWorker` runs every 30 seconds, executing `DELETE FROM events WHERE expires_at IS NOT NULL AND expires_at <= now()`. Index on `expires_at` makes this efficient.

**Partition management:** `PartitionRetentionWorker` ensures partitions exist 2 months ahead, drops oldest partitions based on configurable retention window and max DB size. Limited to 1 drop per run to avoid I/O spikes. DDL operations use `CREATE TABLE IF NOT EXISTS` and validate identifiers against `^[a-zA-Z_][a-zA-Z0-9_]*$` to prevent SQL injection.

**Migrations:** Non-destructive. No `DROP COLUMN` or lock-heavy operations on existing tables. Additive indexes use `CREATE INDEX IF NOT EXISTS`. JSONB column added with data backfill in separate migration.

**Findings:**
- Multi-filter queries use union + in-memory deduplication rather than SQL `UNION`. For queries with many filters returning large result sets, this could spike memory. Acceptable for beta given the 500-result default limit.
- Replaceable/addressable state upserts use raw SQL CTEs — parameterised, no injection risk, but harder to maintain than Ecto queries.

---

### 2.5 Security

**Rating: ⚠️ Needs Work (one item)**

**Input validation: ✅ Thorough.**
12-step validation pipeline for events. Hex decoding with explicit byte lengths. Tag structure validation. Content type checking. All before any DB write.

**Rate limiting: ✅ Well-designed.**
Three tiers: per-connection (120/s), per-IP (1,000/s), relay-wide (10,000/s). ETS-backed with atomic counters. Configurable via environment variables. Telemetry on rate limit hits.

**SQL injection: ✅ No risks found.**
All queries use Ecto parameterisation or `fragment` with positional placeholders. Raw SQL uses `$1, $2, ...` params. Partition identifier creation validates against regex before string interpolation.

**Amplification protection: ✅ Adequate.**
- Giftwrap (kind 1059) queries blocked for unauthenticated users, restricted to recipients for authenticated users
- `max_filter_limit: 500` bounds result sets
- Frame/event size limits prevent memory exhaustion
- Rate limiting prevents query flooding

**NIP-42 authentication: ⚠️ Minor issue.**
Challenge generation uses `:crypto.strong_rand_bytes(16)` — correct. Challenge stored per-connection with process monitor cleanup — correct. However, challenge comparison uses standard Erlang binary equality (`==`), not constant-time comparison. While the 16-byte random challenge makes timing attacks impractical, using `Plug.Crypto.secure_compare/2` would be best practice.

**NIP-98 HTTP auth: ✅ Solid.**
Base64-decoded event validated for kind (27235), freshness (±60s), method binding, URL binding, and signature. Replay cache prevents token reuse within TTL window.

**Moderation: ✅ Complete.**
Banned pubkeys, allowed pubkeys, banned events, blocked IPs. ETS cache with lazy loading from PostgreSQL. ACL rules with principal/capability/match structure. Protected event enforcement (NIP-70).

---

### 2.6 Observability & Operability

**Rating: ✅ Good**

**Telemetry: ✅ Excellent.**
25+ metrics covering ingest (count, duration, outcomes), queries (count, duration, result size), fanout (duration, batch size), connections (queue depth, pressure, overflow), rate limiting (hits by scope), process health (mailbox depth), database (queue time, query time, decode time), maintenance (expiration, partition retention), and VM memory.

**Prometheus endpoint: ✅ Implemented.**
`/metrics` endpoint with access control. Histogram buckets configured for each metric type. Tagged metrics for cardinality management.

**Health check: ✅ Implemented.**
`/ready` endpoint checks Subscriptions.Index, Auth.Challenges, Negentropy.Sessions (if enabled), and all PostgreSQL repos.

**Configuration: ✅ Fully externalised.**
100+ config keys with environment variable overrides in `config/runtime.exs`. Helpers for `int_env`, `bool_env`, `csv_env`, `json_env`, `infinity_or_int_env`, `ipv4_env`. No hardcoded ports, DB URLs, or limits in application code.

**Documentation: ✅ Strong.**
99% of modules have `@moduledoc`. Public APIs have `@spec` annotations. Error types defined as type unions. Architecture docs in `docs/` covering clustering, sync, and local API.

**Logging: ⚠️ Functional but basic.**
Uses standard `Logger.error/warning` with `inspect()` formatting. No structured/JSON logging. Adequate for beta, but not ideal for log aggregation platforms.

---

### 2.7 Testing

**Rating: ✅ Good**

**Test suite:** 58 test files, ~8,000 lines of code.

**Unit tests:** Protocol validation, event validator (including signature verification), filter matching, auth challenges, NIP-98 replay cache, connection policy, event policy, config, negentropy engine/message/sessions.

**Integration tests:** 36 files using PostgreSQL sandbox. Event lifecycle (insert, query, update, delete), adapter contract tests, query plan regression tests, partition management, binary identifier constraints.

**Protocol edge cases tested:**
- Invalid Schnorr signatures (when verification enabled)
- Malformed JSON → `:invalid_json`
- Invalid event structure → specific error atoms
- Unknown filter keys → `:invalid_filter_key`
- Tag filter value limits (128 max)
- NIP-43 malformed relay access events, stale join requests
- Marmot-specific validation (encoding tags, base64 content)
- NIP-66 discovery event validation

**E2E tests:** WebSocket connection tests, TLS E2E, NAK CLI conformance, proxy IP extraction.

**Load test:** `LoadSoakTest` verifying p95 fanout latency under 25ms.

**Property-based tests: ⚠️ Minimal.**
Single file (`FilterPropertyTest`) using `stream_data` for author filter membership. `stream_data` is a dependency but barely used. Significant opportunity to add property tests for event ID computation, filter boundary conditions, and tag parsing.

**Missing coverage:**
- Cluster failover / multi-node crash recovery
- Connection pool exhaustion under load
- WebSocket frame fragmentation
- Concurrent subscription mutation stress
- Byzantine negentropy scenarios

---

### 2.8 Dependencies

**Rating: ✅ Good**

| Dependency | Version | Status |
|---|---|---|
| `bandit` | 1.10.3 | Current, actively maintained |
| `plug` | 1.19.1 | Current, security-patched |
| `ecto_sql` | 3.13.5 | Current |
| `postgrex` | 0.22.0 | Current |
| `lib_secp256k1` | 0.7.1 | Stable, wraps Bitcoin Core's libsecp256k1 |
| `req` | 0.5.17 | Current |
| `telemetry_metrics_prometheus` | 1.1.0 | Current |
| `websockex` | 0.4.x | Test-only, stable |
| `stream_data` | 1.3.0 | Current |
| `credo` | 1.7.x | Dev-only, current |

**Cryptographic library assessment:** `lib_secp256k1` wraps libsecp256k1, the battle-tested C library from Bitcoin Core. Used only for Schnorr signature verification (BIP-340). Appropriate and trustworthy.

**No outdated or unmaintained dependencies.** No known CVEs in current dependency versions.

---

## 3. Top 5 Issues to Fix Before Beta

### 1. Add WebSocket Ping/Pong Keepalives
**Severity:** High
**Impact:** Long-lived subscriptions through proxies/NAT silently disconnect; server accumulates dead connections and leaked subscriptions until process monitor triggers (which requires the TCP connection to fully close).
**Fix:** Implement periodic WebSocket PING frames (e.g., every 30s) in the connection handler. Close connections that don't respond within a timeout.
**Files:** `lib/parrhesia/web/connection.ex`

### 2. Use Constant-Time Comparison for NIP-42 Challenges
**Severity:** Medium (low practical risk due to 16-byte random challenge, but best practice)
**Impact:** Theoretical timing side-channel on challenge validation.
**Fix:** Replace `challenge == stored_challenge` with `Plug.Crypto.secure_compare(challenge, stored_challenge)` in `Auth.Challenges`.
**Files:** `lib/parrhesia/auth/challenges.ex`

### 3. Expand Property-Based Testing
**Severity:** Medium
**Impact:** Undiscovered edge cases in event validation, filter matching, and tag parsing. `stream_data` is already a dependency but only used in one test file.
**Fix:** Add property tests for: event ID computation with random payloads, filter boundary conditions (since/until edge cases), tag parsing with adversarial input, subscription index correctness under random insert/delete sequences.
**Files:** `test/parrhesia/protocol/`

### 4. Add Structured Logging
**Severity:** Low-Medium
**Impact:** Log aggregation (ELK, Datadog, Grafana Loki) requires structured output. Current plaintext logs are adequate for development but make production debugging harder at scale.
**Fix:** Add JSON log formatter (e.g., `LoggerJSON` or custom formatter). Include connection ID, subscription ID, and event kind as structured fields.
**Files:** `config/config.exs`, new formatter module

### 5. Add Server-Initiated WebSocket PING Frames
**Severity:** Low (not spec-required)
**Impact:** RFC 6455 §5.5.2 makes PING optional, and NIP-01 does not require keepalives. However, without server-initiated pings, dead connections behind NAT/proxies are only detected via TCP-level timeouts (which can take minutes), during which subscriptions and state remain allocated.
**Fix:** Consider periodic PING frames (e.g., every 30s) in the connection handler to proactively detect dead connections.
**Files:** `lib/parrhesia/web/connection.ex`

---

## 4. Nice-to-Haves for Beta

1. **Extract queue management** from `connection.ex` (1,925 lines) into a dedicated `Parrhesia.Web.OutboundQueue` module for maintainability.

2. **Add request correlation IDs** to WebSocket connections for log tracing across the event lifecycle (ingest → validation → storage → fanout).

3. **SQL UNION for multi-filter queries** instead of in-memory deduplication. Would reduce memory spikes for queries with many filters, though the 500-result limit mitigates this.

4. **Slow query telemetry** — flag database queries exceeding a configurable threshold (e.g., 100ms) via dedicated telemetry event.

5. **Connection idle timeout** — close WebSocket connections with no activity for a configurable period (e.g., 30 minutes), independent of ping/pong.

6. **Per-pubkey rate limiting** — current rate limiting is per-connection and per-IP. A determined attacker could use multiple IPs. Per-pubkey limiting would add a layer but requires NIP-42 auth.

7. **OpenTelemetry integration** — for distributed tracing across multi-relay deployments.

8. **Negentropy session memory bounds** — while capped at 10K sessions, large filter sets within sessions could still consume significant memory. Consider per-session size limits.

---

## 5. Promotion Recommendation

### ⚠️ Promote with Conditions

**The codebase meets beta promotion criteria with one condition:**

**Condition: Use constant-time comparison for NIP-42 challenge validation.**
While the practical risk is low (16-byte random challenge), this is a security best practice that takes one line to fix (`Plug.Crypto.secure_compare/2`).

**Criteria assessment:**

| Criterion | Status |
|---|---|
| NIP-01 correctly and fully implemented | ✅ Yes |
| Event signature and ID verification cryptographically correct | ✅ Yes (lib_secp256k1 / BIP-340) |
| No ❌ blocking in Security | ✅ No blockers (one minor item) |
| No ❌ blocking in WebSocket handling | ✅ No blockers (ping/pong optional per RFC 6455) |
| System does not crash or leak resources under normal load | ✅ Process monitors, queue management, rate limiting |
| Working test suite covering critical protocol path | ✅ 58 files, 8K LOC, protocol edge cases covered |
| Basic operability (config externalised, logs meaningful) | ✅ 100+ config keys, telemetry, Prometheus, health check |

**What's strong:**
- OTP design is production-grade
- Protocol implementation is comprehensive and spec-compliant
- Security posture is solid (rate limiting, input validation, ACLs, moderation)
- Telemetry coverage is excellent
- Test suite covers critical paths
- Dependencies are current and trustworthy

**What needs attention post-beta:**
- Expand property-based testing
- Add structured logging for production observability
- Consider per-pubkey rate limiting
- Connection handler module size (1,925 lines)
