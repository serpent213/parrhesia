# Parrhesia Relay — Technical Review

**Reviewer:** Case, Senior Systems & Protocol Engineer
**Date:** 2026-03-14
**Commit:** `63d3e7d` (master)
**Scope:** Full codebase review against Nostr NIPs, MARMOT specs, and production readiness criteria

---

# Executive Summary

Parrhesia is a well-structured Nostr relay built on Elixir/OTP with PostgreSQL storage. The architecture is clean — clear separation between web, protocol, policy, and storage layers with a pluggable adapter pattern. Code quality is above average: consistent error handling, good use of `with` chains, comprehensive policy enforcement for MARMOT-specific concerns, and thoughtful outbound backpressure management. The developer clearly understands both the BEAM and the Nostr protocol.

However, the relay has **two critical defects** that make it unsuitable for any deployment beyond trusted local development: (1) **no Schnorr signature verification** — any client can forge events with arbitrary pubkeys, and (2) **lossy tag storage** — events returned from queries have truncated tags, violating NIP-01's data integrity guarantees. Several additional high-severity issues (no ephemeral event handling, missing NIP-42 relay tag validation, SQL LIKE injection vector, no ingest rate limiting) compound the risk.

**Overall risk rating: Critical**

This relay is **not production-ready** for any public deployment. It is suitable for local development and internal testing with trusted clients. With the critical and high findings addressed, it could serve as a solid private relay. Public internet deployment requires significant additional hardening.

---

# Top Findings

## [Critical] No Schnorr Signature Verification

**Area:** protocol correctness, security

**Why it matters:**
NIP-01 mandates that relays MUST verify event signatures using Schnorr signatures over secp256k1. Without signature verification, any client can publish events with any pubkey. This completely breaks the identity and trust model of the Nostr protocol. Authentication (NIP-42), protected events (NIP-70), deletion (NIP-09), replaceable events — all rely on pubkey authenticity.

**Evidence:**
`lib/parrhesia/protocol/event_validator.ex` validates the event ID hash (`validate_id_hash/1` at line 188) but never verifies the `sig` field against the `pubkey` using Schnorr/secp256k1. A `grep` for `schnorr`, `secp256k1`, `verify`, and `:crypto.verify` across the entire `lib/` directory returns zero results. The `validate_sig/1` function (line 182) only checks that `sig` is 64-byte lowercase hex — a format check, not a cryptographic verification.

**Spec reference:**
NIP-01: "Each user has a keypair. Signatures, public key, and encodings are done according to the Schnorr signatures standard for the curve secp256k1." The relay is expected to verify signatures to ensure event integrity.

**Attack scenario:**
An unauthenticated client connects and publishes `["EVENT", {"id": "<valid-hash>", "pubkey": "<victim-pubkey>", "sig": "<any-64-byte-hex>", ...}]`. The relay stores and fans out the forged event as if the victim authored it. This enables impersonation, reputation attacks, and poisoning of replaceable events (kind 0 profile, kind 3 contacts, kind 10002 relay lists).

**Recommended fix:**
Add a secp256k1 library dependency (e.g., `ex_secp256k1` or `:crypto` with OTP 26+ Schnorr support) and add signature verification to `EventValidator.validate/1` after `validate_id_hash/1`. This is the single most important fix.

**Confidence:** High

---

## [Critical] Lossy Tag Storage — Events Returned With Truncated Tags

**Area:** protocol correctness, database

**Why it matters:**
NIP-01 events have tags with arbitrary numbers of elements (e.g., `["e", "<event-id>", "<relay-url>", "<marker>"]`, `["p", "<pubkey>", "<relay-url>"]`, `["a", "<kind>:<pubkey>:<d-tag>", "<relay-url>"]`). The relay only stores the first two elements (`name` and `value`) of each tag in the `event_tags` table, and single-element tags (like `["-"]` for NIP-70 protected events) are dropped entirely. When events are queried back, the reconstructed tags are truncated.

**Evidence:**
`lib/parrhesia/storage/adapters/postgres/events.ex`:
- `insert_tags!/2` (line 266): pattern matches `[name, value | _rest]` — discards `_rest`, ignores tags with fewer than 2 elements.
- `load_tags/1` (line 739): reconstructs tags as `[tag.name, tag.value]` — only 2 elements.
- `to_nostr_event/2` (line 763): uses the truncated tags directly.

The `events` table itself does not store the full tag array. The full tags exist only in the original JSON during ingest, then are lost.

**Spec reference:**
NIP-01: Tags are arrays of arbitrary strings. Relay implementations MUST return events with their complete, unmodified tags. Relay hints in `e`/`p` tags, markers, and other metadata are essential for client operation.

**Attack/failure scenario:**
1. Client publishes event with `["e", "<id>", "wss://relay.example.com", "reply"]`.
2. Another client queries and receives `["e", "<id>"]` — relay hint and marker lost.
3. Client cannot follow the event reference to the correct relay.
4. Protected events with `["-"]` tag lose their protection marker on retrieval, breaking NIP-70 semantics.

**Recommended fix:**
Either (a) store the full tag JSON array in the events table (e.g., a `tags` JSONB column), using `event_tags` only as a query index, or (b) add additional columns to `event_tags` to preserve all elements (e.g., a `rest` text array column or store the full tag as a JSONB column). Option (a) is simpler and more correct.

**Confidence:** High

---

## [High] No Ephemeral Event Handling (Kind 20000–29999)

**Area:** protocol correctness, performance

**Why it matters:**
NIP-01 defines kinds 20000–29999 as ephemeral events that relays are NOT expected to store. They should be fanned out to matching subscribers but never persisted. The relay currently persists all events regardless of kind, which wastes storage and violates client expectations.

**Evidence:**
`lib/parrhesia/storage/adapters/postgres/events.ex`:
- `replaceable_kind?/1` (line 515): handles kinds 0, 3, 10000–19999.
- `addressable_kind?/1` (line 517): handles kinds 30000–39999.
- No function checks for ephemeral kinds (20000–29999).
- `put_event/2` persists all non-deletion, non-vanish events unconditionally.

`lib/parrhesia/web/connection.ex`:
- `persist_event/1` (line 420): routes kind 5 to deletion, kind 62 to vanish, everything else to `put_event`. No ephemeral bypass.

The config has `accept_ephemeral_events: true` but it's never checked anywhere.

**Spec reference:**
NIP-01: "Upon receiving an ephemeral event, a relay is NOT expected to store it and SHOULD send it directly to the clients that have matching filters open."

**Recommended fix:**
In `persist_event/1`, check if the event kind is in the ephemeral range. If so, skip DB persistence and only fan out. The `accept_ephemeral_events` config should gate whether ephemeral events are accepted at all.

**Confidence:** High

---

## [High] NIP-42 AUTH Missing Relay Tag Validation

**Area:** protocol correctness, security

**Why it matters:**
NIP-42 requires AUTH events to include a `["relay", "<relay-url>"]` tag that matches the relay's URL. Without this check, an AUTH event created for relay A can be replayed against relay B, enabling cross-relay authentication bypass.

**Evidence:**
`lib/parrhesia/web/connection.ex`:
- `validate_auth_event/1` (line 573): checks kind 22242 and presence of `challenge` tag.
- `validate_auth_challenge/2` (line 590): checks challenge value matches.
- **No validation of `relay` tag** anywhere in the auth flow.

**Spec reference:**
NIP-42: AUTH event "MUST include `['relay', '<relay-url>']` tag". The relay MUST verify this tag matches its own URL.

**Attack scenario:**
Attacker obtains an AUTH event from user for relay A (which may be the attacker's relay). Attacker replays this AUTH event against Parrhesia, which accepts it because the challenge is the only thing checked. If the challenge can be predicted or leaked, authentication is fully bypassed.

**Recommended fix:**
Add relay URL validation to `validate_auth_event/1`. The relay should know its own canonical URL (from config or NIP-11 document) and verify the `relay` tag matches.

**Confidence:** High

---

## [High] SQL LIKE Pattern Injection in NIP-50 Search

**Area:** security, performance

**Why it matters:**
The NIP-50 search implementation uses PostgreSQL `ILIKE` with unsanitized user input interpolated into the pattern. While not traditional SQL injection (the value is parameterized), LIKE metacharacters (`%`, `_`) in the search string alter the matching semantics and can cause catastrophic performance.

**Evidence:**
`lib/parrhesia/storage/adapters/postgres/events.ex` line 627:
```elixir
where(query, [event], ilike(event.content, ^"%#{search}%"))
```

The `search` variable is directly interpolated into the LIKE pattern. User-supplied values like `%a%b%c%d%e%f%g%h%i%j%` create pathological patterns that force PostgreSQL into exponential backtracking against the full `content` column of every matching row.

**Attack scenario:**
Client sends `["REQ", "sub1", {"search": "%a%b%c%d%e%f%g%h%i%j%k%l%m%n%o%p%q%r%", "kinds": [1]}]`. PostgreSQL executes an expensive sequential scan with exponential LIKE pattern matching. A handful of concurrent requests with adversarial patterns can saturate the DB connection pool and CPU.

**Recommended fix:**
1. Escape `%` and `_` characters in user search input before interpolation: `search |> String.replace("%", "\\%") |> String.replace("_", "\\_")`.
2. Consider PostgreSQL full-text search (`tsvector`/`tsquery`) instead of ILIKE for better performance and correct semantics.
3. Add a minimum search term length (e.g., 3 characters).

**Confidence:** High

---

## [High] No Per-Connection or Per-IP Rate Limiting on Event Ingestion

**Area:** security, robustness

**Why it matters:**
There is no rate limiting on EVENT submissions. A single client can flood the relay with events at wire speed, consuming DB connections, CPU (for validation), and disk I/O. The outbound queue has backpressure, but the ingest path is completely unbounded.

**Evidence:**
`lib/parrhesia/web/connection.ex`:
- `handle_event_ingest/2` (line 186): processes every EVENT message immediately with no throttle.
- No token bucket, sliding window, or any rate-limiting mechanism anywhere in the codebase.
- `grep` for `rate.limit`, `throttle`, `rate_limit` across `lib/` returns only error message strings, not actual rate-limiting logic.

**Attack scenario:**
A single WebSocket connection sends 10,000 EVENT messages per second. Each triggers validation, policy checks, and a DB transaction. The DB connection pool (default 32) saturates within milliseconds. All other clients experience timeouts.

**Recommended fix:**
Implement per-connection rate limiting in the WebSocket handler (token bucket per connection state). Consider also per-pubkey and per-IP rate limiting as a separate layer. Start with a simple `{count, window_start}` in connection state.

**Confidence:** High

---

## [High] max_frame_bytes and max_event_bytes Not Enforced

**Area:** security, robustness

**Why it matters:**
The configuration defines `max_frame_bytes: 1_048_576` and `max_event_bytes: 262_144` but neither value is actually used to limit incoming data. The max_frame_bytes is only reported in the NIP-11 document. An attacker can send arbitrarily large WebSocket frames and events.

**Evidence:**
- `grep` for `max_frame_bytes` in `lib/`: only found in `relay_info.ex` for NIP-11 output.
- `grep` for `max_event_bytes` in `lib/`: no results at all.
- The Bandit WebSocket upgrade in `router.ex` line 53 passes `timeout: 60_000` but no `max_frame_size` option.
- No payload size check in `handle_in/2` before JSON decoding.

**Attack scenario:**
Client sends a 100MB WebSocket frame containing a single event with a massive `content` field or millions of tags. The relay attempts to JSON-decode the entire payload in memory, potentially causing OOM or extreme GC pressure.

**Recommended fix:**
1. Pass `max_frame_size` to Bandit's WebSocket upgrade options.
2. Check `byte_size(payload)` in `handle_in/2` before calling `Protocol.decode_client/1`.
3. Optionally check individual event size after JSON decoding.

**Confidence:** High

---

## [Medium] NIP-09 Deletion Missing "a" Tag Support for Addressable Events

**Area:** protocol correctness

**Why it matters:**
NIP-09 specifies that deletion events (kind 5) can reference addressable/replaceable events via `"a"` tags (format: `"<kind>:<pubkey>:<d-tag>"`). The current implementation only handles `"e"` tags.

**Evidence:**
`lib/parrhesia/storage/adapters/postgres/events.ex`:
- `extract_delete_event_ids/1` (line 821): only extracts `["e", event_id | _rest]` tags.
- No handling of `["a", ...]` tags.
- No query against addressable_event_state or events by kind+pubkey+d_tag.

**Spec reference:**
NIP-09: "The deletion event MAY contain `a` tags pointing to the replaceable/addressable events to be deleted."

**Recommended fix:**
Extract `"a"` tags from the deletion event, parse the `kind:pubkey:d_tag` format, and soft-delete matching events from the addressable/replaceable state tables, ensuring the deleter's pubkey matches.

**Confidence:** High

---

## [Medium] Subscription Index GenServer Is a Single-Point Bottleneck

**Area:** performance, OTP/design

**Why it matters:**
Every event fanout goes through `Index.candidate_subscription_keys/1`, which is a synchronous `GenServer.call` to a single process. Under load with many connections and high event throughput, this process becomes the serialization point for all fanout operations.

**Evidence:**
`lib/parrhesia/subscriptions/index.ex`:
- `candidate_subscription_keys/2` (line 68): `GenServer.call(server, {:candidate_subscription_keys, event})`
- This is called from every connection process for every ingested event (via `fanout_event/1` in `connection.ex` line 688).
- The ETS tables are `:protected`, meaning only the owning GenServer can write but any process can read.

**Recommended fix:**
Since the ETS tables are already `:protected` (readable by all processes), make `candidate_subscription_keys/1` read directly from ETS without going through the GenServer. Only mutations (upsert/remove) need to go through the GenServer. This eliminates the serialization bottleneck entirely.

Actually, the tables are `:protected` which means other processes CAN read. Refactor `candidate_subscription_keys` to read ETS directly from the caller's process, bypassing the GenServer.

**Confidence:** High

---

## [Medium] Moderation Cache ETS Table Creation Race Condition

**Area:** robustness, OTP/design

**Why it matters:**
The moderation cache ETS table is lazily created on first access via `cache_table_ref/0`. If two processes simultaneously call a moderation function before the table exists, both will attempt `ets.new(:parrhesia_moderation_cache, [:named_table, ...])` — one will succeed and one will hit the rescue clause. While the rescue catches the `ArgumentError`, this is a race-prone pattern.

**Evidence:**
`lib/parrhesia/storage/adapters/postgres/moderation.ex` lines 211–231:
```elixir
defp cache_table_ref do
  case :ets.whereis(@cache_table) do
    :undefined ->
      try do
        :ets.new(@cache_table, [...])
      rescue
        ArgumentError -> @cache_table
      end
      @cache_table
    _table_ref ->
      @cache_table
  end
end
```

Additionally, `ensure_cache_scope_loaded/1` has a TOCTOU race: it checks `ets.member(table, loaded_key)`, then loads from DB and inserts — two processes could both load and insert simultaneously, though this is less harmful (just redundant work).

**Recommended fix:**
Create the ETS table in a supervised process (e.g., in `Parrhesia.Policy.Supervisor` or `Parrhesia.Storage.Supervisor`) at startup, not lazily. This eliminates the race entirely.

**Confidence:** High

---

## [Medium] Archiver SQL Injection

**Area:** security

**Why it matters:**
The `Parrhesia.Storage.Archiver.archive_sql/2` function directly interpolates arguments into a SQL string without any sanitization or quoting.

**Evidence:**
`lib/parrhesia/storage/archiver.ex` line 32:
```elixir
def archive_sql(partition_name, archive_table_name) do
  "INSERT INTO #{archive_table_name} SELECT * FROM #{partition_name};"
end
```

If either argument is derived from user input or external configuration, this is a SQL injection vector.

**Attack scenario:**
If the management API or any admin tool passes user-controlled input to this function (e.g., a partition name from a web request), an attacker could inject: `archive_sql("events_default; DROP TABLE events; --", "archive")`.

**Recommended fix:**
Quote identifiers using `~s("#{identifier}")` or better, use Ecto's `Ecto.Adapters.SQL.query/3` with proper identifier quoting. Validate that inputs match expected partition name patterns (e.g., `events_YYYYMM`).

**Confidence:** Medium (depends on whether this function is exposed to external input)

---

## [Medium] Count Query Materialises All Matching Event IDs in Memory

**Area:** performance

**Why it matters:**
The COUNT implementation fetches all matching event IDs into Elixir memory, deduplicates them with `MapSet.new()`, then counts. For large result sets, this is orders of magnitude slower and more memory-intensive than a SQL `COUNT(DISTINCT id)`.

**Evidence:**
`lib/parrhesia/storage/adapters/postgres/events.ex` lines 111–127:
```elixir
def count(_context, filters, opts) when is_list(opts) do
  ...
  total_count =
    filters
    |> Enum.flat_map(fn filter ->
      filter
      |> event_id_query_for_filter(now, opts)
      |> Repo.all()  # fetches ALL matching IDs
    end)
    |> MapSet.new()   # deduplicates in memory
    |> MapSet.size()
  ...
end
```

**Attack scenario:**
Client sends `["COUNT", "c1", {"kinds": [1]}]` on a relay with 10 million kind-1 events. The relay fetches 10 million binary IDs into memory, builds a MapSet, then counts. This could use hundreds of megabytes of RAM per request.

**Recommended fix:**
For single-filter counts, use `SELECT COUNT(*)` or `SELECT COUNT(DISTINCT id)` directly in SQL. For multi-filter counts where deduplication is needed, use `UNION` in SQL rather than materialising in Elixir.

**Confidence:** High

---

## [Medium] NIP-42 AUTH Does Not Validate created_at Freshness

**Area:** protocol correctness, security

**Why it matters:**
NIP-42 suggests AUTH events should have a `created_at` close to current time (within ~10 minutes). The relay's AUTH handler validates the event (which includes a future-skew check of 15 minutes) but does not check if the event is too old. An AUTH event from days ago with a matching challenge could be replayed.

**Evidence:**
`lib/parrhesia/web/connection.ex`:
- `handle_auth/2` calls `Protocol.validate_event(auth_event)` which checks future skew but not past staleness.
- `validate_auth_event/1` (line 573) only checks kind and challenge tag.
- No `created_at` freshness check for AUTH events.

The NIP-98 implementation (`auth/nip98.ex`) DOES have a 60-second freshness check, but the WebSocket AUTH path does not.

**Recommended fix:**
Add a staleness check: reject AUTH events where `created_at` is more than N seconds in the past (e.g., 600 seconds matching NIP-42 suggestion).

**Confidence:** High

---

## [Low] NIP-11 Missing CORS Headers

**Area:** protocol correctness

**Why it matters:**
NIP-11 states relays MUST accept CORS requests by sending appropriate headers. The relay info endpoint does not set CORS headers.

**Evidence:**
`lib/parrhesia/web/router.ex` line 44–55: the `/relay` GET handler returns NIP-11 JSON but does not set `Access-Control-Allow-Origin`, `Access-Control-Allow-Headers`, or `Access-Control-Allow-Methods` headers. No CORS plug is configured in the router.

**Recommended fix:**
Add CORS headers to the NIP-11 response, at minimum `Access-Control-Allow-Origin: *`.

**Confidence:** High

---

## [Low] Event Query Deduplication Done in Elixir Instead of SQL

**Area:** performance

**Why it matters:**
When a REQ has multiple filters, each filter runs a separate DB query, results are merged and deduplicated in Elixir using `Map.put_new/3`. This means the relay may fetch duplicate events from the DB and transfer them over the wire from PostgreSQL, only to discard them.

**Evidence:**
`lib/parrhesia/storage/adapters/postgres/events.ex` lines 85–95:
```elixir
persisted_events =
  filters
  |> Enum.flat_map(fn filter ->
    filter |> event_query_for_filter(now, opts) |> Repo.all()
  end)
  |> deduplicate_events()
  |> sort_persisted_events()
```

**Recommended fix:**
For multiple filters, consider using SQL `UNION` or `UNION ALL` with a final `DISTINCT ON` to push deduplication to the database. Alternatively, for the common case of a single filter (which is the majority of REQ messages), this is fine as-is.

**Confidence:** Medium

---

## [Low] No Validation of Subscription ID Content

**Area:** robustness

**Why it matters:**
Subscription IDs are validated for non-emptiness and max length (64 chars) but not for content. NIP-01 says subscription IDs are "arbitrary" strings, but allowing control characters, null bytes, or extremely long Unicode sequences could cause issues with logging, telemetry, or downstream systems.

**Evidence:**
`lib/parrhesia/protocol.ex` line 218:
```elixir
defp valid_subscription_id?(subscription_id) do
  subscription_id != "" and String.length(subscription_id) <= 64
end
```

`String.length/1` counts Unicode graphemes, not bytes. A subscription ID of 64 emoji characters could be hundreds of bytes.

**Recommended fix:**
Consider validating that subscription IDs contain only printable ASCII, or at least limit by byte size rather than grapheme count.

**Confidence:** Medium

---

# Protocol Compliance Review

## NIPs Implemented
- **NIP-01**: Core protocol — substantially implemented. Critical gaps: no signature verification, lossy tags, no ephemeral handling.
- **NIP-09**: Event deletion — partially implemented (kind 5 with `e` tags only, missing `a` tag deletion).
- **NIP-11**: Relay information — implemented, missing CORS headers.
- **NIP-22**: Event `created_at` limits — implemented (future skew check, configurable).
- **NIP-40**: Expiration — implemented (storage, query filtering, periodic cleanup). Does not reject already-expired events on publish (SHOULD per spec).
- **NIP-42**: Authentication — implemented with challenge-response. Missing relay tag validation, AUTH event staleness check.
- **NIP-45**: COUNT — implemented with basic and HLL support. Performance concern with in-memory deduplication.
- **NIP-50**: Search — implemented via ILIKE. SQL injection concern. No full-text search.
- **NIP-70**: Protected events — implemented (tag check, pubkey match). Note: protected tag `["-"]` is lost on retrieval due to single-element tag storage bug.
- **NIP-77**: Negentropy — stub implementation (session tracking only, no actual reconciliation logic).
- **NIP-86**: Relay management — implemented with NIP-98 auth and audit logging.
- **NIP-98**: HTTP auth — implemented with freshness check.
- **MARMOT**: Kinds 443–449, 1059, 10050–10051 — validation and policy enforcement implemented.

## Non-Compliant Behaviours
1. **No signature verification** — violates NIP-01 MUST.
2. **Lossy tag storage** — violates NIP-01 data integrity.
3. **Ephemeral events persisted** — violates NIP-01 SHOULD NOT store.
4. **AUTH missing relay tag check** — violates NIP-42 MUST.
5. **NIP-09 missing `a` tag deletion** — partial implementation.
6. **NIP-40: expired events accepted on publish** — violates SHOULD reject.
7. **NIP-11 missing CORS** — violates MUST.

## Ambiguous Areas
- **NIP-01 replaceable event tie-breaking**: implemented correctly (lowest ID wins).
- **Deletion event storage**: kind 5 events are stored (correct — relay SHOULD continue publishing deletion requests).
- **NIP-45 HLL**: the HLL payload generation is a placeholder (hash of filter+count), not actual HyperLogLog registers. Clients expecting real HLL data will get nonsense.

---

# Robustness Review

The relay handles several failure modes well:
- WebSocket binary frames are rejected with a clear notice.
- Invalid JSON returns a structured NOTICE.
- GenServer exits are caught with `catch :exit` patterns throughout the connection handler.
- Outbound queue has configurable backpressure (close, drop_oldest, drop_newest).
- Subscription limits are enforced per connection.
- Process monitors clean up subscription index entries when connections die.

**Key resilience gaps:**
1. **No ingest rate limiting** — one client can monopolise the relay.
2. **No payload size enforcement** — oversized frames/events are processed.
3. **Unbounded tag count** — an event with 100,000 tags will generate 100,000 DB inserts in a single transaction.
4. **No filter complexity limits** — a filter with hundreds of tag values generates large `ANY(...)` queries.
5. **COUNT query memory explosion** — large counts materialise all IDs in memory.
6. **No timeout on DB queries** — a slow query (e.g., adversarial search pattern) blocks the connection process indefinitely.
7. **Single-GenServer bottleneck** — Subscription Index serialises all fanout lookups.

**Can one bad client destabilise the relay?** Yes. Through event spam (no rate limit), adversarial search patterns (LIKE injection), or large COUNT queries (memory exhaustion).

---

# Security Review

**Primary Attack Surfaces:**
1. **WebSocket ingress** — unauthenticated by default, no rate limiting, no payload size enforcement.
2. **NIP-50 search** — LIKE pattern injection enables CPU/IO exhaustion.
3. **NIP-86 management API** — properly gated by NIP-98, but `management_auth_required` is a config flag that defaults to `true`. If misconfigured, management API is open.
4. **Event forgery** — no signature verification means complete trust of client-provided pubkeys.

**DoS Vectors (ranked by impact):**
1. Event spam flood (unbounded ingest rate).
2. Adversarial ILIKE search patterns (DB CPU exhaustion).
3. Large COUNT queries (memory exhaustion).
4. Many concurrent subscriptions with broad filters (fanout amplification).
5. Oversized events with thousands of tags (transaction bloat).
6. Rapid REQ/CLOSE cycling (subscription index churn through single GenServer).

**Authentication/Authorization:**
- NIP-42 AUTH flow works but is weakened by missing relay tag validation.
- Protected event enforcement is correct (pubkey match required).
- Giftwrap (kind 1059) access control is properly implemented.
- Management API NIP-98 auth is solid with freshness check.

**No dynamic atom creation risks found.** Method names in admin are handled as strings. No `String.to_atom` or unsafe deserialization patterns detected.

**Information leakage:** Error messages in some paths use `inspect(reason)` which could leak internal Elixir terms to clients (e.g., `connection.ex` line 297, line 353, line 389). Consider sanitising.

---

# Performance Review

**Likely Hotspots:**
1. **Event ingest path**: validation → policy check → DB transaction (3 inserts + possible state table upsert). The transaction is the bottleneck — each event requires at minimum 2 DB round-trips (event_ids + events insert), plus tag inserts.
2. **Subscription fanout**: `Index.candidate_subscription_keys/1` through GenServer.call — serialisation point.
3. **Query path**: per-filter DB queries without UNION, Elixir-side deduplication and sorting.
4. **COUNT path**: materialises all matching IDs in memory.
5. **Search (ILIKE)**: sequential scan without text search index.

**Missing Indexes:**
- No index on `events.content` for search (NIP-50). ILIKE requires sequential scan.
- No composite index on `events (pubkey, kind, created_at)` for replaceable event queries.
- The `event_tags` index on `(name, value, event_created_at)` is good for tag queries.

**Scaling Ceiling:**
- **DB-bound** at moderate load (event ingest transactions).
- **CPU-bound** at high event rates if signature verification is added.
- **Memory-bound** if adversarial COUNT queries are submitted.
- **GenServer-bound** on fanout at high subscription counts.

**Top 3 Performance Improvements by Impact:**
1. **Make subscription index reads lock-free** — read ETS directly instead of through GenServer (effort: S, impact: High).
2. **Push COUNT to SQL** — `SELECT COUNT(DISTINCT id)` instead of materialising (effort: S, impact: High).
3. **Add full-text search index** — `GIN` index on `tsvector` column for NIP-50, replacing ILIKE (effort: M, impact: High).

---

# Database and Schema Review

**Strengths:**
- Range partitioning on `events.created_at` — good for time-based queries and partition pruning.
- Composite primary key `(created_at, id)` enables partition pruning on most queries.
- `event_ids` table for deduplication with `ON CONFLICT :nothing` — clean idempotency.
- State tables for replaceable/addressable events — correct approach with proper upsert/retire logic.
- Partial indexes on `expires_at` and `deleted_at` — avoids indexing NULLs.
- FK cascade from `event_tags` to `events` — ensures tag cleanup on delete.

**Weaknesses:**
1. **No unique index on `events.id`** — only a non-unique index. Two events with the same ID but different `created_at` could theoretically exist (the `event_ids` table prevents this at the application level, but there's no DB-level constraint on the events table).
2. **`event_tags` stores only name+value** — data loss for multi-element tags (Critical finding above).
3. **No `content` index for search** — ILIKE without index = sequential scan.
4. **`events.kind` is `integer` (4 bytes)** — NIP-01 allows kinds 0–65535, so `smallint` (2 bytes) would suffice and save space.
5. **No retention/partitioning strategy documented** — the default partition catches everything. No automated partition creation or cleanup.
6. **`d_tag` column in events table** — redundant with tag storage (but useful for addressable event queries). Not indexed, so no direct benefit. The addressable_event_state table handles this.
7. **No index on `events (id, created_at)` for deletion queries** — `delete_by_request` queries by `id` and `pubkey` but the `id` index doesn't include `pubkey`.

**Missing DB-Level Invariants:**
- Events table should have a unique constraint on `id` (across partitions, which is tricky with range partitioning — the `event_ids` table compensates).
- No CHECK constraint on `kind >= 0`.
- No CHECK constraint on `created_at >= 0`.

---

# Test Review

**Well-Covered Areas:**
- Protocol encode/decode (`protocol_test.exs`)
- Filter validation and matching, including property-based tests (`filter_test.exs`, `filter_property_test.exs`)
- Event validation including MARMOT-specific kinds (`event_validator_marmot_test.exs`)
- Policy enforcement (`event_policy_test.exs`)
- Storage adapter contract compliance (`adapter_contract_test.exs`, `behaviour_contracts_test.exs`)
- PostgreSQL event lifecycle (put, query, delete, replace) (`events_lifecycle_test.exs`)
- WebSocket connection lifecycle (`connection_test.exs`)
- Auth challenges (`challenges_test.exs`)
- NIP-98 HTTP auth (`nip98_test.exs`)
- Fault injection (`fault_injection_test.exs`)
- Query plan regression (`query_plan_regression_test.exs`) — excellent practice

**Missing Critical Tests:**
1. **No signature verification tests** (because the feature doesn't exist).
2. **No test for tag data integrity** — round-trip test that verifies events with multi-element tags are returned unchanged.
3. **No ephemeral event test** — verifying kind 20000+ events are not persisted.
4. **No NIP-09 `a` tag deletion test**.
5. **No adversarial input tests** — LIKE injection patterns, oversized payloads, events with extreme tag counts.
6. **No concurrent write tests** — multiple processes writing the same replaceable event simultaneously.
7. **No AUTH relay tag validation test**.
8. **No test for expired event rejection on publish** (NIP-40).

**5 Most Valuable Tests to Add:**
1. Round-trip tag integrity: publish event with multi-element tags, query back, verify tags are identical.
2. Signature verification: publish event with wrong signature, verify rejection.
3. Concurrent replaceable event upsert: 10 processes writing same pubkey+kind, verify only one winner.
4. Adversarial search pattern: verify ILIKE with `%` metacharacters doesn't cause excessive query time.
5. Ingest rate limiting under load: verify relay remains responsive under event flood.

---

# Quick Wins

| Change | Impact | Effort |
|--------|--------|--------|
| Add Schnorr signature verification | Critical | M |
| Store full tags (add `tags` JSONB column to events) | Critical | M |
| Escape LIKE metacharacters in search | High | S |
| Read subscription index ETS directly (bypass GenServer for reads) | High | S |
| Push COUNT to SQL `COUNT(DISTINCT)` | High | S |
| Add `max_frame_size` to Bandit WebSocket options | High | S |
| Add AUTH relay tag validation | High | S |
| Skip persistence for ephemeral events | High | S |
| Add payload size check before JSON decode | High | S |
| Add CORS headers to NIP-11 endpoint | Low | S |
| Create ETS moderation cache table in supervisor | Medium | S |
| Add `created_at` staleness check to AUTH handler | Medium | S |

---

# Deep Refactor Opportunities

1. **Full-text search for NIP-50**: Replace ILIKE with PostgreSQL `tsvector`/`tsquery` and a GIN index. This eliminates the LIKE injection vector and dramatically improves search performance. Effort: M. Worth it if search is a used feature.

2. **SQL UNION for multi-filter queries**: Instead of running N queries and deduplicating in Elixir, build a single SQL query with UNION ALL and DISTINCT. Reduces DB round-trips and pushes deduplication to the engine. Effort: M.

3. **Per-connection rate limiter**: Add a token-bucket rate limiter to the connection state that throttles EVENT submissions. Consider a pluggable rate-limiting behaviour for flexibility. Effort: M.

4. **Event partitioning strategy**: Automate partition creation (monthly or weekly) and implement partition detach/archive for old data. The current default partition will accumulate all data forever. Effort: L.

5. **Batched tag insertion**: Instead of `Repo.insert_all` for tags within the transaction, accumulate tags and use a single multi-row insert with explicit conflict handling. Reduces round-trips for events with many tags. Effort: S.

---

# Final Verdict

**Would I trust this relay:**
- **For local development:** Yes, with awareness of the signature bypass.
- **For a small private relay (trusted clients):** Conditionally, after fixing lossy tags. The signature gap is tolerable only if all clients are trusted.
- **For a medium public relay:** No. Missing rate limiting, signature verification, and the LIKE injection vector make it unsafe.
- **For a hostile public internet deployment:** Absolutely not.

---

**Ship now?** No.

**Top blockers before deployment:**

1. **Add Schnorr signature verification** — without this, the relay has no identity security.
2. **Fix lossy tag storage** — store full tag arrays so events survive round-trips intact.
3. **Handle ephemeral events** — don't persist kinds 20000–29999.
4. **Escape LIKE metacharacters in search** — prevent DoS via adversarial patterns.
5. **Enforce payload size limits** — pass `max_frame_size` to Bandit, check payload size before decode.
6. **Add basic ingest rate limiting** — per-connection token bucket at minimum.
7. **Add AUTH relay tag validation** — prevent cross-relay AUTH replay.

After these seven fixes, the relay would be suitable for a private deployment with moderate trust. Public deployment would additionally require:
- Per-IP rate limiting
- Full-text search index (replacing ILIKE)
- SQL-based COUNT
- Lock-free subscription index reads
- Ephemeral event NIP-09 `a` tag deletion
- Comprehensive adversarial input testing
