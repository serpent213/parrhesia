# Building a Nostr Relay from Scratch: Lessons from Existing Implementations

## Overview

Implementing a Nostr relay that aims for comprehensive NIP support is a deceptively complex engineering challenge. The protocol's surface simplicity — WebSocket connections, JSON events signed with Schnorr signatures, and a flexible filter system — masks a series of hard distributed-systems problems around storage, query performance, connection management, and spam prevention. This report synthesizes architectural decisions and operational lessons from the major open-source relay implementations (strfry, nostr-rs-relay, khatru, nostream, and others) to identify patterns worth adopting and pitfalls worth avoiding.

***

## Architecture: Threading and I/O Models

### strfry's Shared-Nothing Design

strfry (C++, LMDB) offers the most thoroughly documented internal architecture of any relay. It uses a "shared nothing" threading model where OS threads communicate exclusively via non-copying message queues and the LMDB database — no in-memory data structures are accessed concurrently. The threads are specialized:[1]

- **WebSocket thread**: A single event-loop thread (epoll-based) that handles all I/O multiplexing. Critically, *no JSON parsing or crypto* happens here — it only does compression and TLS if configured.[1]
- **Ingester threads**: Handle JSON decoding, event hashing, signature verification, and filter compilation. Connections are consistently routed to the same ingester.[1]
- **Writer thread**: A single thread handles all DB writes. This is intentional — LMDB has an exclusive write lock, so a single writer avoids contention and allows batching of `fsync` across multiple events.[1]
- **ReqWorker threads**: Service the "historical query" phase of subscriptions by scanning the database.
- **ReqMonitor threads**: Handle real-time event matching for active subscriptions using an inverted index structure.[1]

This separation is worth studying because it solves a core relay problem: the WebSocket thread must never block on CPU-bound work, or latency spikes across all connections. Most naive implementations put JSON parsing and sig verification on the same thread as the socket I/O, which is a guaranteed bottleneck under load.

### Khatru's Hook-Based Framework

The Go-based khatru framework takes a different approach — it provides a relay as a library with pluggable hooks for `StoreEvent`, `QueryEvents`, `DeleteEvent`, and `RejectEvent`. This "code over configuration" model makes it trivial to prototype a custom relay in under 10 lines of code, but shifts performance responsibility entirely to the implementer. The `eventstore` companion library provides adapters for LMDB, BoltDB, and other backends.[2][3][4]

A newer Go framework called `rely` follows a similar pattern with functional options and behavioral hooks for rejection policies, connection lifecycle, and rate limiting.[5]

### Nostream's PostgreSQL Approach

Nostream (TypeScript, PostgreSQL) was one of the earlier production relays but suffered from an "inefficient query engine" that saturated even large servers under load. Operators of Nostr.land reported needing to switch away from nostream to strfry due to resource consumption at scale. This is a cautionary tale: a general-purpose SQL database adds flexibility but makes it harder to optimize for the very specific query patterns that Nostr filters demand.[6]

***

## Database Design: The Central Bottleneck

### Storage Backend Choices

The choice of storage backend is the single most consequential architectural decision. Database performance has been identified as the "core bottleneck" causing slow feed loading across the ecosystem.[7]

| Implementation | Backend | Strengths | Weaknesses |
|---|---|---|---|
| strfry | LMDB (embedded) | Zero-copy reads, read-path needs no locks/syscalls, scales with cores[1] | Single-writer, requires careful schema design, no SQL |
| nostr-rs-relay | SQLite (default), experimental PostgreSQL | Easy to deploy, single-file DB[8] | aiosqlite driver not optimized for async; fragmentation over time[9][10] |
| nostream | PostgreSQL | Rich querying, familiar tooling | High resource overhead, inefficient for Nostr's filter patterns[6] |
| khatru/rely | Pluggable (LMDB, BoltDB, etc.) | Flexibility | Performance depends entirely on chosen adapter[2] |

### Index Design

strfry's approach to indexing is worth deep study. Almost all indices are "clustered" with `created_at`, enabling efficient `since`/`until` scans. Many queries are serviced by index-only scans without loading the full packed event representation. The query engine determines optimal index selection at *compile time*, eliminating SQL parsing overhead and SQL injection risk.[1]

All single-letter tags (a-z, A-Z) are expected to be indexed by relays per NIP-01, making them queryable with `#<tag>` filters. This means the indexing strategy must be extensible — new NIPs regularly introduce new tag types that need indexing.[11]

### Event Storage and Canonicalization

A subtle but important detail from strfry: when storing events, it strips non-indexed data (signatures, non-indexed tags, relay hints) from the packed index representation to minimize record size and improve cache utilization. The full raw JSON is stored separately and re-serialized to canonicalize field ordering and character escaping. NIP-01 specifies strict serialization rules for event ID computation (UTF-8, no whitespace, specific escape sequences for `\n`, `\"`, `\\`, etc.), and getting this wrong means your relay computes different event IDs than other implementations.[11][1]

***

## Query Engine: Subscriptions and Filters

### Filter Matching Performance

Filter matching is one of the hottest code paths in a relay. NIP-01 defines filters as JSON objects with `ids`, `authors`, `kinds`, `#<tag>`, `since`, `until`, and `limit` fields. Within a single filter, all specified conditions are AND'd; multiple filters in a REQ are OR'd.[11]

strfry compiles filter fields into sorted lookup tables where each entry is a 4-byte structure (first byte of the field + offset/size into a single allocation). Filters with ≤16 items can often be rejected by loading a single cache line. Because filters use binary search rather than linear scan, the number of items (e.g., number of pubkeys) has minimal impact on processing time.[1]

### Pausable/Resumable Queries

One of strfry's most practical innovations is pausable queries. When a long-running historical query exceeds a time budget (e.g., 10ms), it gets paused and placed at the back of a queue. New queries always take priority. This prevents a single expensive subscription from blocking all other clients — a common problem in simpler implementations where a `SELECT` with no `LIMIT` against millions of events ties up the query thread.[1]

strfry also supports configurable `queryTimesliceBudgetMicroseconds` and `maxFilterLimit` parameters to control this behavior.[12]

### Real-Time Monitoring (Active Subscriptions)

The second phase of a REQ is the real-time monitoring for newly arriving events. strfry's ReqMonitor uses filesystem change notifications (`inotify`) rather than direct inter-thread messaging — this means it works correctly even when multiple strfry instances share the same LMDB database via `REUSE_PORT`.[1]

For scaling with thousands of concurrent subscriptions, strfry maintains `ActiveMonitors` — an inverted index where each filter's items (e.g., individual pubkeys from an `authors` field) are inserted into sorted "monitor sets." When a new event arrives, its fields are looked up in these sets via binary search, yielding only the filters that *might* match. Each match is then fully validated. This avoids the naive O(events × subscriptions) matching cost.[1]

***

## Event Lifecycle: Kinds and Garbage Collection

### Kind-Based Lifecycles

NIP-01 defines four event lifecycle categories based on kind ranges:[13][11]

| Kind Range | Type | Behavior |
|---|---|---|
| 1, 2, 4-44, 1000-9999 | Regular | Stored indefinitely by relays |
| 0, 3, 10000-19999 | Replaceable | Only latest event per (pubkey, kind) is kept |
| 20000-29999 | Ephemeral | Not expected to be stored |
| 30000-39999 | Addressable (Parameterized Replaceable) | Only latest per (pubkey, kind, d-tag value) is kept |

**Pitfall**: Correctly implementing replaceable and addressable event semantics is a common source of bugs. When a newer replaceable event arrives, older versions must be discarded. If two events have the same timestamp, the one with the lexicographically lower `id` wins. The `d` tag matching for addressable events has edge cases: a missing `d` tag, an empty `d` tag value, and a `d` tag with no value are all treated as equivalent (empty string).[14][11]

### Ephemeral Event Handling

strfry takes a pragmatic approach to ephemeral events: it *does* store them to the database but with a very short retention-policy lifetime (5 minutes by default), deleted by a Cron thread. This simplifies the architecture because the same code path handles both ephemeral and regular events, and the ReqMonitor's `inotify`-based detection works uniformly.[1]

### Garbage Collection and Retention

Storage growth is a real operational concern. Relays can expect 1-10 GB per month depending on policies. Critical maintenance tasks include:[12]

- **Periodic vacuuming** for SQLite-based relays to reclaim space from deleted/hidden events[10]
- **LMDB compaction** for strfry (`strfry compact`) to reclaim fragmented space[1]
- **Retention policies**: Configuring maximum event age, per-kind limits, and deletion of expired events (NIP-40)[15]
- **Replaceable event cleanup**: Ensuring old versions are actually purged, not just hidden

***

## NIP Compatibility: Behavioral Inconsistencies

### The `since`/`until` Boundary Problem

A well-documented interoperability issue is the exact meaning of `since` and `until` boundaries. Different implementations historically diverged:[16]

| Implementation | Matching Behavior |
|---|---|
| nostr-rs-relay | `since < created_at < until` (exclusive) |
| nostream | `since <= created_at <= until` (inclusive) |
| strfry | `since <= created_at <= until` (inclusive) |
| nostr-tools `matchFilter` | `since <= created_at < until` (mixed) |

NIP-01 has since clarified that the correct behavior is `since <= created_at <= until`, but older relay versions in the wild may still use different semantics. An implementation aiming for correctness should follow the spec strictly and be aware that clients may encounter inconsistent results from other relays.[11]

### `limit` Handling

The behavior when `limit` is not specified also varies. nostr-rs-relay returns *all* matching events (oldest first), nostream returns a fixed 500 (oldest first), and strfry returns `min(limit, 500)` (newest first). strfry enforces a configurable `maxFilterLimit`. The spec says `limit` only applies to the initial query and events should be returned newest-first, but implementations differ on defaults for unspecified limits.[17][12][11]

### NIP Support Tiers

For a relay aiming at broad compatibility, prioritize NIPs in tiers:[18]

- **Tier 1 (Basic relay)**: NIP-01 (protocol), NIP-11 (relay information document), and OK/EOSE/CLOSED response messages
- **Tier 2 (Enhanced)**: NIP-09 (event deletion), NIP-42 (authentication), NIP-50 (search), NIP-65 (relay metadata), NIP-40 (expiration)
- **Tier 3 (Advanced)**: NIP-77 (negentropy syncing), NIP-86 (relay management API), NIP-45 (counting)

The NIP acceptance criteria require implementations to be "optional and backwards-compatible" — clients and relays that don't implement a NIP must not break when interacting with those that do.[19]

***

## Signature Verification: A CPU Hotspot

Schnorr signature verification over secp256k1 is the most computationally expensive per-event operation. Every incoming event must be verified before storage, and this adds up quickly under write-heavy loads.[20][21]

**Lessons from client-side optimizations that apply equally to relays:**

- **Offload to a dedicated thread pool**: strfry's Ingester threads handle verification, keeping it off the WebSocket I/O thread.[1]
- **Consider sampling or caching**: NDK (a client library) supports verification sampling — only verifying a percentage of signatures per relay, adjusting based on track record. For a relay, you could cache recently verified event IDs and skip re-verification for duplicates.[20]
- **Use native crypto libraries**: The Rust `secp256k1` crate or C `libsecp256k1` are significantly faster than pure-language implementations. Dart NDK recommends `RustEventVerifier()` for this reason.[21]

**Pitfall**: Some clients reportedly omit signature verification entirely, which has led to event forgery attacks. A relay must *always* verify signatures — this is a non-negotiable security requirement.[22]

***

## Spam Prevention and Rate Limiting

Spam is one of the most challenging operational problems for open relays. Nostr saw approximately 500,000 daily spam messages at one point, with spammers adapting by shifting to different relays when paywalls were erected.[23]

### Approaches That Work

- **Rate limiting per pubkey**: Configurable write limits (events per time period) per public key. Most relays implement some form of this.[24]
- **Proof-of-work (NIP-13)**: Events can include a PoW nonce, and relays can require a minimum difficulty. This raises the cost of spam without requiring payments.[25]
- **Payment requirements**: Pay-to-write relays using Lightning micropayments. Effective but limits adoption.[26]
- **Web-of-Trust (WoT) filtering**: Accept events only from pubkeys within a trust graph. More complex to implement but very effective for community relays.[27]
- **Reputation-based rate limiting**: A newer approach where pubkey budgets are adjusted dynamically based on behavior — good actors get more bandwidth, new/suspicious keys face tighter limits.[24]

### What Doesn't Work Well

- **IP-based throttling**: Easily bypassed with proxies and VPNs. Nostr's WebSocket-based communication also makes conventional HTTP rate limiting tools harder to apply.[27]
- **Simple blacklisting of pubkeys**: Anyone can generate new keypairs instantly, making blacklists a losing game.[24]

strfry externalizes write-policy decisions through a plugin system — any programming language can implement a filter using a line-based JSON interface. This is an excellent architectural pattern for extensibility.[1]

***

## WebSocket and Connection Management

### Connection Scaling

NIP-01 states that "clients SHOULD open a single websocket connection to each relay" but relays "MAY limit number of connections from specific IP/client/etc." Key configuration parameters for production relays include:[12][11]

- `nofiles` (file descriptor limit): 65,536-131,072 for production
- `maxSubsPerConnection`: Typically 50-100 to prevent subscription bomb attacks
- `maxWebsocketPayloadSize`: 128KB is a common default
- `autoPingSeconds`: 25-30 seconds for keepalive

### Compression

WebSocket compression (`permessage-deflate`) can significantly reduce bandwidth but has CPU cost. strfry supports two modes: per-message (low memory) and sliding-window (better compression due to cross-message redundancy from repeated pubkeys, subIds, etc.). On-disk compression using zstd dictionaries is also available for reducing storage.[1]

**Pitfall**: The Python nostr-relay documentation notes that while "compression is great for saving bandwidth, it kills performance" — disabling it can be a valid choice for maximum throughput.[9]

### Zero-Downtime Restarts

strfry achieves zero-downtime upgrades using Linux's `REUSE_PORT` socket option. Multiple strfry instances can listen on the same port simultaneously. A `SIGUSR1` initiates graceful shutdown of the old instance (no new connections, exits after last connection closes). This is a production-essential feature that should be designed in from the start, not bolted on later.[1]

***

## Relay-to-Relay Syncing: Negentropy

NIP-77 defines a bandwidth-efficient set reconciliation protocol based on Negentropy for syncing events between relays (or between clients and relays). If both sides share common events, this uses far less bandwidth than transferring full event sets or even just IDs.[28][29]

The protocol flow uses `NEG-OPEN`, `NEG-MSG`, and `NEG-CLOSE` messages over the WebSocket connection. The client sends a filter and an initial Negentropy message; the relay responds with reconciliation data; and multiple rounds can occur until sync is complete. strfry can maintain pre-computed BTrees for commonly synced filters (like the full database) to make syncing stateless and efficient.[29][30][1]

Implementations exist in C++, JavaScript, Rust, and Go. Supporting NIP-77 early is strategically important for relay operators who want to participate in the relay mesh topology.[31][1]

***

## Common Pitfalls Summary

1. **JSON serialization edge cases**: NIP-01's strict serialization rules for event ID computation (character escaping, field ordering, no whitespace) are a frequent source of ID mismatches between implementations.[11]

2. **Blocking the I/O thread**: Any CPU-intensive work (JSON parsing, sig verification, DB queries) on the WebSocket thread will cause latency spikes for all connected clients.[1]

3. **Unbounded queries**: A REQ with no `limit` and broad filters can return millions of events. Always enforce server-side limits and support query pausing.[17][1]

4. **Replaceable event race conditions**: Two replaceable events with the same timestamp need deterministic tiebreaking (lowest lexicographic ID wins).[11]

5. **Tag indexing completeness**: All single-letter tags must be indexed per NIP-01. Missing an index means certain filters silently return incomplete results.[11]

6. **Ephemeral event storage**: Relays that simply drop ephemeral events on the floor (never writing to any storage) can miss delivery to subscribers who connected milliseconds after the event arrived. strfry's "store briefly, then delete" approach is more robust.[1]

7. **`OK` response timing**: strfry never returns `OK` until an event is confirmed committed to the database — "durable writes". Returning `OK` before persistence risks data loss.[1]

8. **NIP-11 incompleteness**: Clients rely on the relay information document to discover capabilities. A missing or incorrect `supported_nips` field means clients can't adapt their behavior.[32][33]

9. **Subscription management**: Not properly cleaning up subscriptions on disconnect or `CLOSE` leads to memory leaks and phantom notifications.[1]

10. **Assuming schema stability**: strfry has needed incompatible DB format changes in the past, requiring export/reimport cycles. Design migration paths early.[1]

***

## Recommendations for a New Implementation

For a relay targeting broad NIP compatibility and future extensibility:

- **Separate I/O from computation**: Use a dedicated event loop for WebSocket I/O and worker threads/tasks for parsing, verification, and queries. This is non-negotiable for any relay beyond toy scale.
- **Use an embedded database with custom indices**: LMDB has proven itself across strfry and other implementations. Avoid general-purpose SQL databases for the hot path unless you're prepared to heavily optimize queries.
- **Implement query budget controls from day one**: Pausable queries, time-slice budgets, and configurable `maxFilterLimit` prevent abuse and keep latency predictable.
- **Build the plugin/hook system early**: strfry's write-policy plugin and khatru's hook model both demonstrate that relay policy is inherently custom. Hardcoding policies leads to forks.
- **Invest in a comprehensive test harness**: strfry's differential fuzzing approach — comparing a naive filter implementation against the optimized query engine across random filters and real-world data — is the gold standard for correctness testing.[1]
- **Design for NIP evolution**: New NIPs frequently add new event kinds, tag types, and protocol messages. An architecture that treats kind ranges and tag indexing as data-driven configuration rather than hardcoded logic will age much better.
