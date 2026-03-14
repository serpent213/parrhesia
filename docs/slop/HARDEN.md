# Hardening Review: Parrhesia Nostr Relay

You are a security engineer specialising in real-time WebSocket servers, Erlang/OTP systems, and protocol-level abuse. You are reviewing **Parrhesia**, a Nostr relay (NIP-01 compliant) written in Elixir, for hardening opportunities — with a primary focus on **denial-of-service resilience** and a secondary focus on the full attack surface.

Produce a prioritised list of **specific, actionable recommendations** with rationale. For each recommendation, state:
1. The attack or failure mode it mitigates
2. Suggested implementation (config change, code change, or architectural change)
3. Severity estimate (critical / high / medium / low)

---

## 1. Architecture Overview

| Component | Technology | Notes |
|---|---|---|
| Runtime | Elixir/OTP 27, BEAM VM | Each WS connection is a separate process |
| HTTP server | Bandit (pure Elixir) | HTTP/1.1 only, no HTTP/2 |
| WebSocket | `websock_adapter` | Text frames only; binary rejected |
| Database | PostgreSQL via Ecto | Range-partitioned `events` table by `created_at` |
| Caching | ETS | Config snapshot + moderation ban/allow lists |
| Multi-node | Erlang `:pg` groups | Fanout across BEAM cluster nodes |
| Metrics | Prometheus (Telemetry) | `/metrics` endpoint |
| TLS termination | **Out of scope** — handled by reverse proxy (nginx/Caddy) |

### Supervision Tree

```
Parrhesia.Supervisor
  ├─ Telemetry (Prometheus exporter)
  ├─ Config (ETS snapshot of runtime config)
  ├─ Storage.Supervisor (Ecto repo + moderation cache)
  ├─ Subscriptions.Supervisor (ETS subscription index for fanout)
  ├─ Auth.Supervisor (NIP-42 challenge GenServer)
  ├─ Policy.Supervisor (policy enforcement)
  ├─ Web.Endpoint (Bandit listener)
  └─ Tasks.Supervisor (ExpirationWorker, 30s GC loop)
```

### Data Flow

1. Client connects via WebSocket at `/relay`
2. NIP-42 AUTH challenge issued immediately (16-byte random, base64url)
3. Inbound text frames are: size-checked → JSON-decoded → rate-limited → protocol-dispatched
4. EVENT messages: validated → policy-checked → stored in Postgres → ACK → async fanout to matching subscriptions
5. REQ messages: filters validated → Postgres query → results streamed → EOSE → live subscription registered
6. Fanout: post-ingest, subscription index (ETS) is traversed; matching connection processes receive events via `send/2`

---

## 2. Current Defences Inventory

### Connection Layer

| Defence | Value | Enforcement Point |
|---|---|---|
| Max WebSocket frame size | **1,048,576 bytes (1 MiB)** | Checked in `handle_in` *before* JSON decode, and at Bandit upgrade (`max_frame_size`) |
| WebSocket upgrade timeout | **60,000 ms** | Passed to `WebSockAdapter.upgrade` |
| Binary frame rejection | Returns NOTICE, connection stays open | `handle_in` opcode check |
| Outbound queue limit | **256 events** per connection | Overflow strategy: **`:close`** (WS 1008) |
| Outbound drain batch | **64 events** | Async drain via `send(self(), :drain_outbound_queue)` |
| Outbound pressure telemetry | Threshold at **75%** of queue | Emits telemetry event only, no enforcement |
| IP blocking | Via moderation cache (ETS) | Management API can add blocked IPs |

### Protocol Layer

| Defence | Value | Notes |
|---|---|---|
| Max event JSON size | **262,144 bytes (256 KiB)** | Re-serialises decoded event and checks byte size |
| Max filters per REQ | **16** | Rejected at filter validation |
| Max filter `limit` | **500** | `min(client_limit, 500)` applied at query time |
| Max subscriptions per connection | **32** | Existing sub IDs updated without counting toward limit |
| Subscription ID max length | **64 characters** | Must be non-empty |
| Event kind range | **0–65,535** | Integer range check |
| Max future event skew | **900 seconds (15 min)** | Events with `created_at > now + 900` rejected |
| Unknown filter keys | **Rejected** | Allowed: `ids`, `authors`, `kinds`, `since`, `until`, `limit`, `search`, `#<letter>` |

### Event Validation Pipeline

Strict order:
1. Required fields present (`id`, `pubkey`, `created_at`, `kind`, `tags`, `content`, `sig`)
2. `id` — 64-char lowercase hex
3. `pubkey` — 64-char lowercase hex
4. `created_at` — non-negative integer, max 900s future skew
5. `kind` — integer in [0, 65535]
6. `tags` — list of non-empty string arrays (**no length limit on tags array or individual tag values**)
7. `content` — any binary string
8. `sig` — 128-char lowercase hex
9. ID hash recomputation and comparison
10. Schnorr signature verification via `lib_secp256k1` (gated by `verify_event_signatures` flag, default `true`)

### Rate Limiting

| Defence | Value | Notes |
|---|---|---|
| Event ingest rate | **120 events per window** | Per-connection sliding window |
| Ingest window | **1 second** | Resets on first event after expiry |
| No per-IP connection rate limiting | — | Must be handled at reverse proxy |
| No global connection count ceiling | — | BEAM handles thousands but no configured limit |

### Authentication (NIP-42)

- Challenge issued to **all** connections on connect (optional escalation model)
- AUTH event must: pass full NIP-01 validation, be kind `22242`, contain matching `challenge` tag, contain matching `relay` tag
- `created_at` freshness: must be `>= now - 600s` (10 min)
- On success: pubkey added to `authenticated_pubkeys` MapSet; challenge rotated
- Supports multiple authenticated pubkeys per connection

### Authentication (NIP-98 HTTP)

- Management endpoint (`POST /management`) requires NIP-98 header
- Auth event must be kind `27235`, `created_at` within **60 seconds** of now
- Must include `method` and `u` tags matching request exactly

### Access Control

- `auth_required_for_writes`: default **false** (configurable)
- `auth_required_for_reads`: default **false** (configurable)
- Protected events (NIP-70, tagged `["-"]`): require auth + pubkey match
- Giftwrap (kind 1059): unauthenticated REQ → CLOSED; authenticated REQ must include `#p` containing own pubkey

### Database

- All queries use Ecto parameterised bindings — no raw string interpolation
- LIKE search patterns escaped (`%`, `_`, `\` characters)
- Deletion enforces `pubkey == deleter_pubkey` in WHERE clause
- Soft-delete via `deleted_at`; hard-delete only via vanish (NIP-62) or expiration purge
- DB pool: **32 connections** (prod), queue target 1s, interval 5s

### Moderation

- Banned pubkeys, allowed pubkeys, banned events, blocked IPs stored in ETS cache
- Management API (NIP-98 authed) for CRUD on moderation lists
- Cache invalidated atomically on writes

---

## 3. Known Gaps and Areas of Concern

The following are areas where the current implementation may be vulnerable or where defences could be strengthened. **Please evaluate each and provide recommendations.**

### 3.1 Connection Exhaustion

- There is **no global limit on concurrent WebSocket connections**. Each connection is an Elixir process (~2–3 KiB base), but subscriptions, auth state, and outbound queues add per-connection memory.
- There is **no per-IP connection rate limiting at the application layer**. IP blocking exists but is reactive (management API), not automatic.
- There is **no idle timeout** after the WebSocket upgrade completes. A connection can remain open indefinitely without sending or receiving messages.

**Questions:**
- What connection limits should be configured at the Bandit/BEAM level?
- Should an idle timeout be implemented? If so, what value balances real-time subscription use against resource waste?
- Should per-IP connection counting be implemented at the application layer, or is this strictly a reverse proxy concern?

### 3.2 Subscription Abuse

- A single connection can hold **32 subscriptions**, each with up to **16 filters**. That's 512 filter predicates per connection being evaluated on every fanout.
- Filter arrays (`ids`, `authors`, `kinds`, tag values) have **no element count limits**. A filter could contain thousands of author pubkeys.
- There is no cost accounting for "expensive" subscriptions (e.g., wide open filters matching all events).

**Questions:**
- Should filter array element counts be bounded? If so, what limits per field?
- Should there be a per-connection "filter complexity" budget?
- How expensive is the current ETS subscription index traversal at scale (e.g., 10K concurrent connections × 32 subs each)?

### 3.3 Tag Array Size

- Event validation does **not limit the number of tags** or the length of individual tag values beyond the 256 KiB total event size cap.
- A maximally-tagged event could contain thousands of short tags, causing amplification in `event_tags` table inserts (one row per tag).

**Questions:**
- Should a max tag count be enforced? What is a reasonable limit?
- What is the insert cost of storing e.g. 1,000 tags per event? Could this be used for write amplification?
- Should individual tag value lengths be bounded?

### 3.4 AUTH Timing

- AUTH event `created_at` freshness only checks the **lower bound** (`>= now - 600`). An AUTH event with `created_at` far in the future passes validation.
- Regular events have a future skew cap of 900s, but AUTH events do not.

**Questions:**
- Should AUTH events also enforce a future `created_at` bound?
- Is a 600-second AUTH window too wide? Could it be reduced?

### 3.5 Outbound Amplification

- A single inbound EVENT can fan out to an unbounded number of matching subscriptions across all connections.
- The outbound queue (256 events, `:close` strategy) protects individual connections but does not limit total fanout work per event.
- The fanout traverses the ETS subscription index synchronously in the ingesting connection's process.

**Questions:**
- Should fanout be bounded per event (e.g., max N recipients before yielding)?
- Should fanout happen in a separate process pool rather than inline?
- Is the `:close` overflow strategy optimal, or would `:drop_oldest` be better for well-behaved clients with temporary backpressure?

### 3.6 Query Amplification

- A single REQ with 16 filters, each with `limit: 500`, could trigger 16 separate Postgres queries returning up to 8,000 events total.
- COUNT requests also execute per-filter queries (now deduplicated via UNION ALL).
- `search` filters use `ILIKE %pattern%` which cannot use B-tree indexes.

**Questions:**
- Should there be a per-REQ total result cap (across all filters)?
- Should `search` queries be rate-limited or require a minimum pattern length?
- Should COUNT be disabled or rate-limited separately?
- Are there missing indexes that would help common query patterns?

### 3.7 Multi-Node Trust

- Events received via `:remote_fanout_event` from peer BEAM nodes **skip all validation and policy checks** and go directly to the subscription index.
- This assumes all cluster peers are trusted.

**Questions:**
- If cluster membership is dynamic or spans trust boundaries, should remote events be re-validated?
- Should there be a shared secret or HMAC on inter-node messages?

### 3.8 Metrics Endpoint

- `/metrics` (Prometheus) is **unauthenticated**.
- Exposes internal telemetry: connection counts, event throughput, queue depths, database timing.

**Questions:**
- Should `/metrics` require authentication or be restricted to internal networks?
- Could metrics data be used to profile the relay's capacity and craft targeted attacks?

### 3.9 Negentropy Stub

- NEG-OPEN, NEG-MSG, NEG-CLOSE messages are accepted and acknowledged but the reconciliation logic is a stub (cursor counter only).
- Are there resource implications of accepting negentropy sessions without real implementation?

### 3.10 Event Re-Serialisation Cost

- To enforce the 256 KiB event size limit, the relay calls `JSON.encode!(event)` on the already-decoded event map. This re-serialisation happens on every inbound EVENT.
- Could this be replaced with a byte-length check on the raw frame payload (already available)?

---

## 4. Specific Review Requests

Beyond the gaps above, please also evaluate:

1. **Bandit configuration**: Are there Bandit-level options (max connections, header limits, request timeouts, keepalive settings) that should be tuned for a public-facing relay?

2. **BEAM VM flags**: Are there any Erlang VM flags (`+P`, `+Q`, `+S`, memory limits) that should be set for production hardening?

3. **Ecto pool exhaustion**: With 32 DB connections and potentially thousands of concurrent REQ queries, what happens under pool exhaustion? Is the 1s queue target + 5s interval appropriate?

4. **ETS table sizing**: The subscription index and moderation cache use ETS. Are there memory limits or table options (`read_concurrency`, `write_concurrency`, `compressed`) that should be tuned?

5. **Process mailbox overflow**: Connection processes receive events via `send/2` during fanout. If a process is slow to consume, its mailbox grows. The outbound queue mechanism is application-level — but is the BEAM-level mailbox also protected?

6. **Reverse proxy recommendations**: What nginx/Caddy configuration should complement the relay's defences? (Rate limiting, connection limits, WebSocket-specific settings, request body size.)

7. **Monitoring and alerting**: What telemetry signals should trigger alerts? (Connection count spikes, queue overflow rates, DB pool saturation, error rates.)

---

## 5. Out of Scope

The following are **not** in scope for this review:
- TLS configuration (handled by reverse proxy)
- DNS and network-level DDoS mitigation
- Operating system hardening
- Key management for the relay identity
- Client-side security
- Nostr protocol design flaws (we implement the spec as-is)

---

## 6. Response Format

For each recommendation, use this format:

### [Severity] Title

**Attack/failure mode:** What goes wrong without this mitigation.

**Current state:** What exists today (or doesn't).

**Recommendation:** Specific change — config value, code change, or architectural decision.

**Trade-offs:** Any impact on legitimate users or operational complexity.
