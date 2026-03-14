# Parrhesia clustering and distributed fanout

This document describes:

1. the **current** distributed fanout behavior implemented today, and
2. a practical evolution path to a more production-grade clustered relay.

---

## 1) Current state (implemented today)

### 1.1 What exists right now

Parrhesia currently includes a lightweight multi-node live fanout path (untested!):

- `Parrhesia.Fanout.MultiNode` (`lib/parrhesia/fanout/multi_node.ex`)
  - GenServer that joins a `:pg` process group.
  - Receives locally-published events and forwards them to other group members.
  - Receives remote events and performs local fanout lookup.
- `Parrhesia.Web.Connection` (`lib/parrhesia/web/connection.ex`)
  - On successful ingest, after ACK scheduling, it does:
    1. local fanout (`fanout_event/1`), then
    2. cross-node publish (`maybe_publish_multi_node/1`).
- `Parrhesia.Subscriptions.Supervisor` (`lib/parrhesia/subscriptions/supervisor.ex`)
  - Starts `Parrhesia.Fanout.MultiNode` unconditionally.

In other words: **if BEAM nodes are connected, live events are fanned out cross-node**.

### 1.2 What is not included yet

- No automatic cluster formation/discovery (no `libcluster`, DNS polling, gossip, etc.).
- No durable inter-node event transport.
- No replay/recovery of missed cross-node live events.
- No explicit per-node delivery ACK between relay nodes.

---

## 2) Current runtime behavior in detail

### 2.1 Local ingest flow and publish ordering

For an accepted event in `Parrhesia.Web.Connection`:

1. validate/policy/persist path runs.
2. Client receives `OK` reply.
3. A post-ACK message triggers:
   - local fanout (`Index.candidate_subscription_keys/1` + send `{:fanout_event, ...}`),
   - multi-node publish (`MultiNode.publish/1`).

Important semantics:

- Regular persisted events: ACK implies DB persistence succeeded.
- Ephemeral events: ACK implies accepted by policy, but no DB durability.
- Cross-node fanout happens **after** ACK path is scheduled.

### 2.2 Multi-node transport mechanics

`Parrhesia.Fanout.MultiNode` uses `:pg` membership:

- On init:
  - ensures `:pg` is started,
  - joins group `Parrhesia.Fanout.MultiNode`.
- On publish:
  - gets all group members,
  - excludes itself,
  - sends `{:remote_fanout_event, event}` to each member pid.
- On remote receive:
  - runs local subscription candidate narrowing via `Parrhesia.Subscriptions.Index`,
  - forwards matching candidates to local connection owners as `{:fanout_event, sub_id, event}`.

No republish on remote receive, so this path does not create fanout loops.

### 2.3 Subscription index locality

The subscription index is local ETS state per node (`Parrhesia.Subscriptions.Index`).

- Each node only tracks subscriptions of its local websocket processes.
- Each node independently decides which local subscribers match a remote event.
- There is no global cross-node subscription registry.

### 2.4 Delivery model and guarantees (current)

Current model is **best-effort live propagation** among connected nodes.

- If nodes are connected and healthy, remote live subscribers should receive events quickly.
- If there is a netsplit or temporary disconnection:
  - remote live subscribers may miss events,
  - persisted events can still be recovered by normal `REQ`/history query,
  - ephemeral events are not recoverable.

### 2.5 Cluster preconditions

For cross-node fanout to work, operators must provide distributed BEAM connectivity:

- consistent Erlang cookie,
- named nodes (`--name`/`--sname`),
- network reachability for Erlang distribution ports,
- explicit node connections (or external discovery tooling).

Parrhesia currently does not automate these steps.

---

## 3) Operational characteristics of current design

### 3.1 Performance shape

For each accepted event on one node:

- one local fanout lookup + local sends,
- one cluster publish that sends to `N - 1` remote bus members,
- on each remote node: one local fanout lookup + local sends.

So inter-node traffic scales roughly linearly with node count per event (full-cluster broadcast).

This is simple and low-latency for small-to-medium clusters, but can become expensive as node count grows.

### 3.2 Failure behavior

- Remote node down: send attempts to that member stop once membership updates; no replay.
- Netsplit: live propagation gap during split.
- Recovery: local clients can catch up via DB-backed queries (except ephemeral kinds).

### 3.3 Consistency expectations

- No global total-ordering guarantee for live delivery across nodes.
- Per-connection ordering is preserved by each connection process queue/drain behavior.
- Duplicate suppression for ingestion uses storage semantics (`duplicate_event`), but transport itself is not exactly-once.

### 3.4 Observability today

Relevant metrics exist for fanout/queue pressure (see `Parrhesia.Telemetry`), e.g.:

- `parrhesia.fanout.duration.ms`
- `parrhesia.connection.outbound_queue.depth`
- `parrhesia.connection.outbound_queue.pressure`
- `parrhesia.connection.outbound_queue.overflow.count`

These are useful but do not yet fully separate local-vs-remote fanout pipeline stages.

---

## 4) Practical extension path to a fully-fledged clustered system

A realistic path is incremental. Suggested phases:

### Phase A — hardened BEAM cluster control plane

1. Add cluster discovery/formation (e.g. `libcluster`) with environment-specific topology:
   - Kubernetes DNS,
   - static nodes,
   - cloud VM discovery.
2. Add clear node liveness/partition telemetry and alerts.
3. Provide operator docs for cookie, node naming, and network requirements.

Outcome: simpler and safer cluster operations, same data plane semantics.

### Phase B — resilient distributed fanout data plane

Introduce a durable fanout stream for persisted events.

Recommended pattern:

1. On successful DB commit of event, append to a monotonic fanout log (or use DB sequence-based stream view).
2. Each relay node runs a consumer with a stored cursor.
3. On restart/partition recovery, node resumes from cursor and replays missed events.
4. Local fanout remains same (subscription index + per-connection queues).

Semantics target:

- **at-least-once** node-to-node propagation,
- replay after downtime,
- idempotent handling keyed by event id.

Notes:

- Ephemeral events can remain best-effort (or have a separate short-lived transport), since no storage source exists for replay.

### Phase C — scale and efficiency improvements

As cluster size grows, avoid naive full broadcast where possible:

1. Optional node-level subscription summaries (coarse bloom/bitset or keyed summaries) to reduce unnecessary remote sends.
2. Shard fanout workers for CPU locality and mailbox control.
3. Batch remote delivery payloads.
4. Separate traffic classes (e.g. Marmot-heavy streams vs generic) with independent queues.

Outcome: higher throughput per node and lower inter-node amplification.

### Phase D — stronger observability and SLOs

Add explicit distributed pipeline metrics:

- publish enqueue/dequeue latency,
- cross-node delivery lag (commit -> remote fanout enqueue),
- replay backlog depth,
- per-node dropped/expired transport messages,
- partition detection counters.

Define cluster SLO examples:

- p95 commit->remote-live enqueue under nominal load,
- max replay catch-up time after node restart,
- bounded message loss for best-effort channels.

---

## 5) How a fully-fledged system would behave in practice

With Phases A-D implemented, expected behavior:

- **Normal operation:**
  - low-latency local fanout,
  - remote nodes receive events via stream consumers quickly,
  - consistent operational visibility of end-to-end lag.
- **Node restart:**
  - node reconnects and replays from stored cursor,
  - local subscribers begin receiving new + missed persisted events.
- **Transient partition:**
  - live best-effort path may degrade,
  - persisted events converge after partition heals via replay.
- **High fanout bursts:**
  - batching + sharding keeps queue pressure bounded,
  - overflow policies remain connection-local and measurable.

This approach gives a good trade-off between Nostr relay latency and distributed robustness without requiring strict exactly-once semantics.

---

## 6) Current status summary

Today, Parrhesia already supports **lightweight distributed live fanout** when BEAM nodes are connected.

It is intentionally simple and fast for smaller clusters, and provides a solid base for a more durable, observable cluster architecture as relay scale and availability requirements grow.
