# Parrhesia Relay Sync

## 1. Purpose

This document defines the Parrhesia proposal for **relay-to-relay event synchronization**.

It is intentionally transport-focused:

- manage remote relay peers,
- catch up on matching events,
- keep a live stream open,
- expose health and basic stats.

It does **not** define application data semantics.

Parrhesia syncs Nostr events. Callers decide which events matter and how to apply them.

---

## 2. Boundary

### Parrhesia is responsible for

- storing and validating events,
- querying and streaming events,
- running outbound sync workers against remote relays,
- tracking peer configuration, worker health, and sync counters,
- exposing peer management through `Parrhesia.API.Sync`.

### Parrhesia is not responsible for

- resource mapping,
- trusted node allowlists for an app profile,
- mutation payload validation beyond normal event validation,
- conflict resolution,
- replay winner selection,
- database upsert/delete semantics.

For Tribes, those remain in `TRIBES-NOSTRSYNC` and `AshNostrSync`.

---

## 3. Security Foundation

### Default posture

The baseline posture for sync traffic is:

- no access to sync events by default,
- no implicit trust from ordinary relay usage,
- no reliance on plaintext confidentiality from public relays.

For the first implementation, Parrhesia should protect sync data primarily with:

- authenticated server identities,
- ACL-gated read and write access,
- TLS with certificate pinning for outbound peers.

### Server identity

Parrhesia owns a low-level server identity used for relay-to-relay authentication.

This identity is separate from:

- TLS endpoint identity,
- application event author pubkeys.

Recommended model:

- Parrhesia has one local server-auth pubkey,
- sync peers authenticate as server-auth pubkeys,
- ACL grants are bound to those authenticated server-auth pubkeys,
- application-level writer trust remains outside Parrhesia.

Identity lifecycle:

1. use configured/imported key if provided,
2. otherwise use persisted local identity,
3. otherwise generate once during initial startup and persist it.

Private key export should not be supported.

### ACLs

Sync traffic should use a real ACL layer, not moderation allowlists.

Initial ACL model:

- principal: authenticated pubkey,
- capabilities: `sync_read`, `sync_write`,
- match: event/filter shape such as `kinds: [5000]` and namespace tags.

This is enough for now. We do **not** need a separate user ACL model and server ACL model yet.

A sync peer is simply an authenticated principal with sync capabilities.

### TLS pinning

Each outbound sync peer must include pinned TLS material.

Recommended pin type:

- SPKI SHA-256 pins

Multiple pins should be allowed to support certificate rotation.

---

## 4. Sync Model

Each configured sync server represents one outbound worker managed by Parrhesia.

Minimum behavior:

1. connect to the remote relay,
2. run an initial catch-up query for the configured filters,
3. ingest received events into the local relay through the normal API path,
4. switch to a live subscription for the same filters,
5. reconnect with backoff when disconnected.

The worker treats filters as opaque Nostr filters. It does not interpret app payloads.

### Initial implementation mode

Initial implementation should use ordinary NIP-01 behavior:

- catch-up via `REQ`-style query,
- live updates via `REQ` subscription.

This is enough for Tribes and keeps the first version simple.

### NIP-77

Parrhesia now has a real reusable relay-side NIP-77 engine:

- proper `NEG-OPEN` / `NEG-MSG` / `NEG-CLOSE` / `NEG-ERR` framing,
- a reusable negentropy codec and reconciliation engine,
- bounded local `(created_at, id)` snapshot enumeration for matching filters,
- connection/session integration with policy checks and resource limits.

That means NIP-77 can be used for bandwidth-efficient catch-up between trusted nodes.

The first sync worker implementation may still default to ordinary NIP-01 catch-up plus live replay, because that path is operationally simpler and already matches the current Tribes sync profile. `:negentropy` can now be introduced as an optimization mode rather than a future prerequisite.

---

## 5. API Surface

Primary control plane:

- `Parrhesia.API.Identity.get/1`
- `Parrhesia.API.Identity.ensure/1`
- `Parrhesia.API.Identity.import/2`
- `Parrhesia.API.Identity.rotate/1`
- `Parrhesia.API.ACL.grant/2`
- `Parrhesia.API.ACL.revoke/2`
- `Parrhesia.API.ACL.list/1`
- `Parrhesia.API.Sync.put_server/2`
- `Parrhesia.API.Sync.remove_server/2`
- `Parrhesia.API.Sync.get_server/2`
- `Parrhesia.API.Sync.list_servers/1`
- `Parrhesia.API.Sync.start_server/2`
- `Parrhesia.API.Sync.stop_server/2`
- `Parrhesia.API.Sync.sync_now/2`
- `Parrhesia.API.Sync.server_stats/2`
- `Parrhesia.API.Sync.sync_stats/1`
- `Parrhesia.API.Sync.sync_health/1`

These APIs are in-process. HTTP management may expose them through `Parrhesia.API.Admin` or direct routing to `Parrhesia.API.Sync`.

---

## 6. Server Specification

`put_server/2` is an upsert.

Suggested server shape:

```elixir
%{
  id: "tribes-primary",
  url: "wss://relay-a.example/relay",
  enabled?: true,
  auth_pubkey: "<remote-server-auth-pubkey>",
  mode: :req_stream,
  filters: [
    %{
      "kinds" => [5000],
      "authors" => ["<trusted-node-pubkey-a>", "<trusted-node-pubkey-b>"],
      "#r" => ["tribes.accounts.user", "tribes.chat.tribe"]
    }
  ],
  overlap_window_seconds: 300,
  auth: %{
    type: :nip42
  },
  tls: %{
    mode: :required,
    hostname: "relay-a.example",
    pins: [
      %{type: :spki_sha256, value: "<pin-a>"},
      %{type: :spki_sha256, value: "<pin-b>"}
    ]
  },
  metadata: %{}
}
```

Required fields:

- `id`
- `url`
- `auth_pubkey`
- `filters`
- `tls`

Recommended fields:

- `enabled?`
- `mode`
- `overlap_window_seconds`
- `auth`
- `metadata`

Rules:

- `id` must be stable and unique locally.
- `url` is the remote relay websocket URL.
- `auth_pubkey` is the expected remote server-auth pubkey.
- `filters` must be valid NIP-01 filters.
- filters are owned by the caller; Parrhesia only validates filter shape.
- `mode` defaults to `:req_stream`.
- `tls.mode` defaults to `:required`.
- `tls.pins` must be non-empty for synced peers.

---

## 7. Runtime State

Each server should have both configuration and runtime status.

Suggested runtime fields:

```elixir
%{
  server_id: "tribes-primary",
  state: :running,
  connected?: true,
  last_connected_at: ~U[2026-03-16 10:00:00Z],
  last_disconnected_at: nil,
  last_sync_started_at: ~U[2026-03-16 10:00:00Z],
  last_sync_completed_at: ~U[2026-03-16 10:00:02Z],
  last_event_received_at: ~U[2026-03-16 10:12:45Z],
  last_eose_at: ~U[2026-03-16 10:00:02Z],
  reconnect_attempts: 0,
  last_error: nil
}
```

Parrhesia should keep this state generic. It is about relay sync health, not app state convergence.

---

## 8. Stats and Health

### Per-server stats

`server_stats/2` should return basic counters such as:

- `events_received`
- `events_accepted`
- `events_duplicate`
- `events_rejected`
- `query_runs`
- `subscription_restarts`
- `reconnects`
- `last_remote_eose_at`
- `last_error`

### Aggregate sync stats

`sync_stats/1` should summarize:

- total configured servers,
- enabled servers,
- running servers,
- connected servers,
- aggregate event counters,
- aggregate reconnect count.

### Health

`sync_health/1` should be operator-oriented, for example:

```elixir
%{
  "status" => "degraded",
  "servers_total" => 3,
  "servers_connected" => 2,
  "servers_failing" => [
    %{"id" => "tribes-secondary", "reason" => "connection_refused"}
  ]
}
```

This is intentionally simple. It should answer “is sync working?” without pretending to prove application convergence.

---

## 9. Event Ingest Path

Events received from a remote sync worker should enter Parrhesia through the same ingest path as any other accepted event.

That means:

1. validate the event,
2. run normal write policy,
3. persist or reject,
4. fan out locally,
5. rely on duplicate-event behavior for idempotency.

This avoids a second ingest path with divergent behavior.

Before normal event acceptance, the sync worker should enforce:

1. pinned TLS validation for the remote endpoint,
2. remote server-auth identity match,
3. local ACL grant permitting the peer to perform sync reads and/or writes.

The sync worker may attach request-context metadata such as:

```elixir
%Parrhesia.API.RequestContext{
  caller: :sync,
  metadata: %{sync_server_id: "tribes-primary"}
}
```

That metadata is for telemetry and audit only. It must not become app sync semantics.

---

## 10. Persistence

Parrhesia should persist enough sync control-plane state to survive restart:

- local server identity reference,
- configured ACL rules for sync principals,
- configured servers,
- whether a server is enabled,
- optional catch-up cursor or watermark per server,
- basic last-error and last-success markers.

Parrhesia does not need to persist application replay heads or winner state. That remains in the embedding application.

---

## 11. Relationship to Current Features

### BEAM cluster fanout

`Parrhesia.Fanout.MultiNode` is a separate feature.

It provides best-effort live fanout between connected BEAM nodes. It is not remote relay sync and is not a substitute for `Parrhesia.API.Sync`.

### Management stats

Current admin `stats` is relay-global and minimal.

Sync adds a new dimension:

- peer config,
- worker state,
- per-peer counters,
- sync health summary.

That should be exposed without coupling it to app-specific sync semantics.

---

## 12. Tribes Usage

For Tribes, `AshNostrSync` should be able to:

1. rely on Parrhesia’s local server identity,
2. register one or more remote relays with `Parrhesia.API.Sync.put_server/2`,
3. grant sync ACLs for trusted server-auth pubkeys,
4. provide narrow Nostr filters for `kind: 5000`,
5. observe sync health and counters,
6. consume events via the normal local Parrhesia ingest/query/stream surface.

Tribes should not need Parrhesia to know:

- what a resource namespace means,
- which node pubkeys are trusted for Tribes,
- how to resolve conflicts,
- how to apply an upsert or delete.

That is the key boundary.
