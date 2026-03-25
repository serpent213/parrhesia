# Parrhesia Beta: Production-Readiness Gap Assessment

**Date:** 2026-03-20
**Version:** 0.7.0
**Scope:** Delta analysis from beta promotion — what stands between this codebase and confident public-facing production deployment.

---

## Production Readiness Scorecard

| # | Dimension                        | Rating | Summary                                      |
|---|----------------------------------|--------|----------------------------------------------|
| 1 | Operational Resilience           | 🟡     | Graceful shutdown partial; no DB circuit-breaking |
| 2 | Multi-Node / Clustering          | 🟡     | Best-effort only; acceptable for single-node prod |
| 3 | Load & Capacity Characterisation | 🟡     | Benchmarks exist but no defined capacity model |
| 4 | Deployment & Infrastructure      | 🟡     | Strong Nix/Docker base; missing runbooks and migration strategy |
| 5 | Security Hardening               | 🟢     | Solid for production with reverse proxy      |
| 6 | Data Integrity & Consistency     | 🟢     | Transaction-wrapped writes with dedup; minor multi-node edge cases |
| 7 | Observability Completeness       | 🟡     | Excellent metrics; no dashboards, alerts, or tracing |
| 8 | Technical Debt (Prod Impact)     | 🟡     | Manageable; connection.ex size is the main concern |

---

## 1. Operational Resilience — 🟡

### What's good

- **No `Process.sleep` on any hot path.** Zero occurrences in `lib/`. Clean async message passing throughout.
- **WebSocket keepalive** implemented: 30s ping, 10s pong timeout, auto-close on timeout.
- **Outbound queue backpressure** well-designed: bounded queue (256 default), configurable overflow strategy (`:close`/`:drop_oldest`/`:drop_newest`), pressure telemetry at 75% threshold.
- **Connection isolation:** Each WebSocket is a separate process; one crash does not propagate.
- **Graceful connection close on shutdown:** `handle_info({:EXIT, _, :shutdown}, ...)` drains outbound frames before closing with code 1012 ("service restart"). This is good.

### Gaps

**G1.1 — No DB circuit-breaking or backoff on PostgreSQL unavailability.**
Ecto's connection pool (`db_connection`/`DBConnection`) will queue checkout requests up to `queue_target` (1000ms) / `queue_interval` (5000ms), then raise `DBConnection.ConnectionError`. These errors propagate as storage failures in the ingest path and return NOTICE errors to clients. However:
- There is no circuit breaker to fast-reject requests when the DB is known-down, meaning every ingest/query attempt during an outage burns a pool checkout timeout slot.
- On DB recovery, all queued checkouts may succeed simultaneously (thundering herd).
- **Impact:** During a PostgreSQL failover (typically 10–30s), connection processes pile up waiting on the pool. Latency spikes for all connected clients. Memory pressure from queued processes.
- **Mitigation:** Ecto's built-in queue management provides partial protection. For a relay with ≤1000 concurrent connections this is likely survivable without circuit-breaking. For higher connection counts, consider a fast-fail wrapper around storage calls when the pool reports consecutive failures.

**G1.2 — Metrics scrape on the hot path.**
`/metrics` calls `TelemetryMetricsPrometheus.Core.scrape/1` synchronously within the HTTP request handler. This serialises metric aggregation and formatting. If the Prometheus reporter's internal state is large (many unique tag combinations), scraping can take 10–100ms. This runs on a Bandit acceptor process — it does not block WebSocket connections directly, but a slow scrape under high cardinality could make the health endpoint unresponsive if metrics and health share the same listener.
- **Current mitigation:** Metrics can be isolated to a dedicated listener via `PARRHESIA_METRICS_ENDPOINT_*` config. If deployed this way, impact is isolated.
- **Recommendation:** Document the dedicated metrics listener as required for production. Consider adding a scrape timeout guard.

**G1.3 — Supervisor shutdown timeout is OTP default (5s).**
The `Parrhesia.Runtime` supervisor uses `:one_for_one` strategy with default child shutdown specs. Bandit listeners have their own shutdown behavior, but there is no explicit `shutdown: N` on the endpoint child spec. Under load with many connections, 5s may not be enough to drain all outbound queues.
- **Recommendation:** Set explicit `shutdown: 15_000` on `Parrhesia.Web.Endpoint` child spec. Bandit supports graceful drain on listener stop.

---

## 2. Multi-Node / Clustering — 🟡

### Current state

Per `docs/CLUSTER.md`, clustering is **implemented but explicitly best-effort and untested**:

- `:pg`-based process groups for cross-node fanout.
- No automatic cluster discovery (no libcluster).
- ETS subscription index is node-local.
- No durable inter-node transport; no replay on reconnect.
- No explicit acknowledgement between nodes.

### Assessment for production

**For single-node production deployment: not a blocker.** The clustering code is unconditionally started (`MultiNode` joins `:pg` on init) but with a single node, `get_members/0` returns only self, and the `Enum.reject(&(&1 == self()))` filter means no remote sends occur. No performance overhead.

**For multi-node production: not ready.** Key issues:
- **Subscription inconsistency on netsplit:** Events ingested on node A during a split are never delivered to subscribers on node B. No catch-up mechanism exists. Clients must reconnect and re-query to recover.
- **Node departure drops subscriptions silently:** When a node leaves the cluster, subscribers on that node lose their connections (normal). Subscribers on other nodes are unaffected. But events that were in-flight from the departed node are lost.
- **No cluster health observability:** No metrics for inter-node fanout lag, message drops, or membership changes.

**Recommendation for initial production:** Deploy single-node. Clustering is a Phase B concern per the documented roadmap.

---

## 3. Load & Capacity Characterisation — 🟡

### What exists

- `LoadSoakTest` asserts p95 fanout enqueue/drain < 25ms.
- `bench/` directory with `nostr-bench` submodule for external load testing.
- Cloud bench orchestration scripts (`scripts/cloud_bench_orchestrate.mjs`, `scripts/cloud_bench_server.sh`).

### Gaps

**G3.1 — No documented capacity model.**
There is no documented answer to: "How many connections / events per second can one node handle before degradation?" The `LoadSoakTest` runs locally with synthetic data — useful for regression detection but not representative of production traffic patterns.

**G3.2 — Multi-filter query scaling is in-memory dedup.**
`Postgres.Events.query/3` runs each filter as a separate SQL query, collects all results into memory, and deduplicates with `deduplicate_events/1` (Map.update accumulation). With many overlapping filters or high-cardinality results, this could produce significant memory pressure per-request.
- At realistic scales (< 10 filters, < 1000 results per filter), this is fine.
- At adversarial scales (32 subscriptions × large result sets), a single REQ could allocate substantial memory.
- **Current mitigation:** `max_tag_values_per_filter` (128) and query `LIMIT` bounds exist. The risk is bounded but not eliminated.

**G3.3 — No query performance benchmarks against large datasets.**
No evidence of testing against 100M+ events with monthly partitions. Partition pruning is implemented, but query plans may degrade if the partition list grows large (PostgreSQL planner overhead scales with partition count).

**Recommendation:** Before production, run `nostr-bench` at target load (e.g., 500 concurrent connections, 100 events/sec ingest, 1000 active subscriptions) and document the resulting latency profile. This becomes the baseline capacity model.

---

## 4. Deployment & Infrastructure Readiness — 🟡

### What's good

- **Docker image via Nix:** Non-root user (65534:65534), minimal base, cacerts bundled, SSL_CERT_FILE set. This is production-quality container hygiene.
- **OTP release:** `mix release` with `Parrhesia.Release.migrate/0` for safe migration execution.
- **CI pipeline:** Multi-matrix testing (OTP 27/28, Elixir 1.18/1.19), format/credo/unused deps checks, E2E tests.
- **Environment-based configuration:** All critical settings overridable via `PARRHESIA_*` env vars in `runtime.exs`.
- **Secrets:** No secrets committed. DB credentials via `DATABASE_URL`, identity key via env or file path.

### Gaps

**G4.1 — No zero-downtime migration strategy.**
`Parrhesia.Release.migrate/0` runs `Ecto.Migrator.run/4` with `:up`. Under replicated deployments (rolling update with 2+ instances), there is no advisory lock or migration guard — two instances starting simultaneously could race on migrations. Ecto's default migrator uses `pg_advisory_lock` via `Ecto.Migration.Runner`, so this is actually safe for PostgreSQL. However:
- **DDL migrations (CREATE INDEX CONCURRENTLY, ALTER TABLE) need careful handling.** The existing migrations use standard `CREATE TABLE` and `CREATE INDEX` which acquire ACCESS EXCLUSIVE locks. Running these against a live database will block reads and writes for the duration.
- **Recommendation:** For production, migrations should be run as a separate step before deploying new code (the compose.yaml already has a `migrate` service — extend this pattern).

**G4.2 — No operational runbooks.**
There are no documented procedures for:
- Rolling restart / blue-green deploy
- Partition pruning and retention tuning
- Runtime pubkey banning (the NIP-86 management API exists but isn't documented for ops use)
- DB failover response
- Scaling (horizontal or vertical)

**G4.3 — No health check in Docker image.**
The Nix-built Docker image has no `HEALTHCHECK` instruction. The `/health` and `/ready` endpoints exist but aren't wired into container orchestration.
- **Recommendation:** Add `HEALTHCHECK CMD curl -f http://localhost:4413/ready || exit 1` to the Docker image definition, or document the readiness endpoint for Kubernetes probes.

**G4.4 — No disaster recovery plan.**
No documented RTO/RPO. If the primary DB is lost, recovery depends entirely on external backup infrastructure. The relay has no built-in data export or snapshot capability.

---

## 5. Security Hardening — 🟢

### Assessment

The security posture is solid for production behind a reverse proxy:

- **TLS:** Full support for server, mutual, and proxy-terminated TLS modes. Cipher suite selection (strong/compatible). Certificate pin verification.
- **Rate limiting:** Three layers — relay-wide (10k/s), per-IP (1k/s), per-connection (120/s). All configurable.
- **Metrics endpoint:** Access-controlled via `metrics_allowed?/2` — supports private-network-only restriction and bearer token auth. Tested.
- **NIP-42 auth:** Constant-time comparison via `Plug.Crypto.secure_compare/2` (addressed in beta).
- **NIP-98:** Replay protection, event freshness check (< 60s), signature verification.
- **Input validation:** Binary field length constraints at DB level (migration 7). Event size limits at WebSocket frame level.
- **IP controls:** Trusted proxy CIDR configuration, X-Forwarded-For parsing, IP blocklist table.
- **Audit logging:** `management_audit_logs` table tracks admin actions.
- **No secrets in git.** Environment variable or file-path based secret injection.

### Minor considerations (not blocking)

- No integration with external threat intel feeds or IP reputation services. This is an infrastructure concern, not an application concern.
- DDoS mitigation assumed to be at load balancer / CDN layer. Application-level rate limiting is defense-in-depth, not primary.
- **Recommendation:** Document the expected deployment topology (Caddy/Nginx → Parrhesia) and which security controls are expected at each layer.

---

## 6. Data Integrity & Consistency — 🟢

### What's good

- **Duplicate event prevention:** Two-layer defence:
  1. `event_ids` table with unique PK on `id` — `INSERT ... ON CONFLICT DO NOTHING`.
  2. If `inserted == 0`, transaction rolls back with `:duplicate_event`.
  3. Separate unique index on `events.id` as belt-and-suspenders.
- **Atomic writes:** `put_event/2` wraps `insert_event_id!`, `insert_event!`, `insert_tags!`, and `upsert_state_tables!` in a single `Repo.transaction/1`. Partial writes (event without tags) cannot occur.
- **Replaceable/addressable event state:** Upsert logic in state tables with correct conflict resolution (higher `created_at` wins, then lower `id` as tiebreaker via `candidate_wins_state?/2`).

### Minor considerations

**G6.1 — Expiration worker concurrency on multi-node.**
`ExpirationWorker` runs `Repo.delete_all/1` against all expired events. If two nodes run this worker against the same database, both execute the same DELETE query. PostgreSQL handles this safely (the second DELETE finds 0 rows), and the worker is idempotent. **Not a problem.**

**G6.2 — Partition pruning and sync.**
`PartitionRetentionWorker.drop_partition/1` drops entire monthly partitions. If negentropy sync is in progress against events in that partition, the sync session's cached refs become stale. The session would fail or return incomplete results.
- **Impact:** Low. Partition drops are infrequent (daily check, at most 1 per run). Negentropy sessions are short-lived (60s idle timeout).
- **Recommendation:** No action needed for initial production. If operating as a sync source relay, consider pausing sync during partition drops.

---

## 7. Observability Completeness — 🟡

### What's good

Metrics coverage is comprehensive — 34+ distinct metrics covering:
- Ingest: event count by outcome/reason, duration distribution
- Query: request count, duration, result cardinality
- Fanout: duration, candidates considered, events enqueued, batch size
- Connection: outbound queue depth/pressure/overflow/drop, mailbox depth
- Rate limiting: hit count by scope
- DB: query count/total_time/queue_time/query_time/decode_time/idle_time by repo role
- Maintenance: expiration purge count/duration, partition retention drops/duration
- VM: memory (total/processes/system/atom/binary/ets)
- Listener: active connections, active subscriptions

Readiness endpoint checks critical process liveness. Health endpoint for basic reachability.

### Gaps

**G7.1 — No dashboards or alerting rules.**
The metrics exist but there are no Grafana dashboard JSON files, no Prometheus alerting rules, and no documented alert thresholds. An operator deploying this relay would need to build observability from scratch.
- **Recommendation:** Ship a `deploy/grafana/` directory with a dashboard JSON and a `deploy/prometheus/alerts.yml` with rules for:
  - `parrhesia_db_query_queue_time_ms` p95 > 100ms (pool saturation)
  - `parrhesia_connection_outbound_queue_overflow_count` rate > 0 (clients being dropped)
  - `parrhesia_rate_limit_hits_count` rate sustained > threshold (potential abuse)
  - `parrhesia_vm_memory_total_bytes` > 80% of available
  - Listener connection count approaching `max_connections`

**G7.2 — No distributed tracing or request correlation IDs.**
Events flow through validate → policy → persist → fanout without a correlation ID tying the stages together. Log-based debugging of "why didn't this event reach subscriber X" requires manual PID correlation across log lines.
- **Impact:** Tolerable for initial production at moderate scale. Becomes painful at high event rates.

**G7.3 — No synthetic monitoring.**
No built-in probe that ingests a canary event and verifies it arrives at a subscriber. End-to-end relay health depends on external monitoring.
- **Recommendation:** This is best implemented as an external tool. Not blocking.

---

## 8. Technical Debt with Production Impact — 🟡

### G8.1 — `connection.ex` at 2,116 lines

This module is the per-connection state machine handling EVENT, REQ, CLOSE, AUTH, COUNT, NEG-*, keepalive, outbound queue management, rate limiting, and all associated telemetry. It is the single most critical file for production incident response.

**Production risk:** During a production incident involving connection behavior, an on-call engineer needs to quickly navigate this module. At 2,116 lines with interleaved concerns (protocol parsing, policy enforcement, queue management, telemetry emission), this slows incident response.

**Recommendation (M-sized effort):** Extract into focused modules:
- `Connection.Ingest` — EVENT handling and policy application
- `Connection.Subscription` — REQ/CLOSE management and initial query streaming
- `Connection.OutboundQueue` — queue/drain/overflow logic
- `Connection.Keepalive` — ping/pong state machine

The main `Connection` module would become an orchestrator delegating to these. This is a refactor-only change with no behavioral impact.

### G8.2 — Multi-filter in-memory dedup

`deduplicate_events/1` accumulates all query results into a Map before deduplication. With 32 subscriptions (the max) and generous limits, worst case is:
- 32 filters × 5000 result limit = 160,000 events loaded into memory per REQ.

Each event struct is ~500 bytes minimum, so ~80MB per pathological request. This is bounded but could be weaponised by an attacker sending many concurrent REQs with overlapping filters.

**Current mitigation:** Per-connection subscription limit (32) and query result limits bound the damage. Per-IP rate limiting adds friction.

**Recommendation:** Not blocking for production. Monitor `parrhesia.query.results.count` distribution. If p99 > 10,000, investigate query patterns.

### G8.3 — Per-pubkey rate limiting absent

Rate limiting is currently per-IP and relay-wide. An attacker using a botnet (many IPs, one pubkey) bypasses IP-based limits. Per-pubkey rate limiting would catch this.

**Impact:** Medium for a public relay; low for an invite-only (NIP-43) relay.

**Recommendation (S-sized effort):** Add a per-pubkey event ingest limiter similar to `IPEventIngestLimiter`, keyed by `event.pubkey`. Apply after signature verification but before storage.

### G8.4 — Negentropy session memory ceiling

Negentropy session bounds:
- Max 10,000 total sessions (`@default_max_total_sessions`)
- Max 8 per connection (`@default_max_sessions_per_owner`)
- Max 50,000 items per session (`@default_max_items_per_session`)
- 60s idle timeout with 10s sweep interval

Worst case: 10,000 sessions × 50,000 items × ~40 bytes/ref = ~20GB. This is the theoretical maximum under adversarial session creation.

**Realistic ceiling:** The `open/6` path runs a DB query bounded by `max_items_per_session + 1`. At 50k items, this query itself provides backpressure (it takes time). An attacker would need 10,000 concurrent connections each opening 8 sessions, each returning 50k results. The relay-wide connection limit and rate limiting make this implausible in practice.

**Recommendation:** Reduce `@default_max_items_per_session` to 10,000 for production (reduces theoretical ceiling to ~4GB). This is a config change, not a code change.

---

## Critical Path to Production

Ordered by priority. Items above the line are required before production traffic; items below are strongly recommended.

| # | Work Item | Dimension | Effort |
|---|-----------|-----------|--------|
| 1 | Set explicit shutdown timeout on Endpoint child spec | Operational | S |
| 2 | Document dedicated metrics listener as production requirement | Operational | S |
| 3 | Add HEALTHCHECK to Docker image or document K8s probes | Deployment | S |
| 4 | Run capacity benchmark at target load and document results | Load | M |
| 5 | Ship Grafana dashboard + Prometheus alert rules | Observability | M |
| 6 | Write operational runbook (deploy, rollback, ban, failover) | Deployment | M |
| 7 | Document migration strategy (run before deploy, not during) | Deployment | S |
| --- | --- | --- | --- |
| 8 | Add per-pubkey rate limiting | Security | S |
| 9 | Reduce default negentropy items-per-session to 10k | Security | S |
| 10 | Extract connection.ex into sub-modules | Debt | M |
| 11 | Add request correlation IDs to event lifecycle | Observability | M |
| 12 | Add DB pool health fast-fail wrapper | Operational | M |

---

## Production Risk Register

| ID | Risk | Likelihood | Impact | Mitigation |
|----|------|-----------|--------|------------|
| R1 | PostgreSQL failover causes latency spike for all connections | Medium | High | G1.1: Ecto queue management provides partial protection. Add pool health telemetry alerting. Consider circuit breaker at high connection counts. |
| R2 | Slow /metrics scrape blocks health checks | Low | Medium | G1.2: Deploy dedicated metrics listener (already supported). |
| R3 | Ungraceful shutdown drops in-flight events | Low | Medium | G1.3: Set explicit shutdown timeout. Connection drain logic already exists. |
| R4 | Multi-IP spam campaign bypasses rate limiting | Medium | Medium | G8.3: Add per-pubkey rate limiter. NIP-43 invite-only mode mitigates for private relays. |
| R5 | Large REQ with many overlapping filters causes memory spike | Low | Medium | G8.2: Bounded by existing limits. Monitor query result cardinality. |
| R6 | No alerting means silent degradation | Medium | High | G7.1: Ship dashboard and alert rules before production. |
| R7 | DDL migration blocks reads during rolling deploy | Low | High | G4.1: Run migrations as separate pre-deploy step. |
| R8 | Adversarial negentropy session creation exhausts memory | Low | High | G8.4: Reduce max items per session. Existing session limits provide protection. |
| R9 | No runbooks slows incident response | Medium | Medium | G4.2: Write runbooks for common ops tasks. |
| R10 | connection.ex complexity slows debugging | Medium | Low | G8.1: Extract sub-modules. Not urgent but improves maintainability. |

---

## Final Verdict

### 🟡 Ready for Limited Production

**Constraints for initial deployment:**

1. **Single-node only.** Multi-node clustering is best-effort and should not be relied upon for production traffic. Deploy one node with a properly sized PostgreSQL instance.

2. **Behind a reverse proxy.** Deploy behind Caddy, Nginx, or a cloud load balancer for TLS termination, DDoS mitigation, and connection limits. Document the expected topology.

3. **Moderate traffic cap.** Without a validated capacity model, start with conservative limits:
   - ≤ 2,000 concurrent WebSocket connections
   - ≤ 500 events/second ingest rate
   - Monitor `db.query.queue_time.ms` p95 and `connection.outbound_queue.overflow.count` as scaling signals.

4. **Observability must be deployed alongside.** The metrics exist but dashboards and alerts do not. Do not go live without at minimum:
   - Prometheus scraping the dedicated metrics listener
   - Alerts on DB queue time, outbound queue overflow, and VM memory
   - Log aggregation with ERROR-level alerts

5. **Migrations run pre-deploy.** Use the existing compose.yaml `migrate` service pattern. Never run migrations as part of application startup in a multi-replica deployment.

**What's strong:**
- OTP supervision architecture is clean and fault-isolated
- Data integrity layer is well-designed (transactional writes, dedup, constraint enforcement)
- Security posture is production-appropriate
- Telemetry coverage is comprehensive
- Container image follows best practices
- No blocking issues in the hot path (no sleeps, no synchronous calls, bounded queues)

**The codebase is architecturally sound for production.** The gaps are operational (runbooks, dashboards, capacity planning) rather than structural. A focused sprint addressing items 1–7 from the critical path would clear the way for a controlled production launch.
