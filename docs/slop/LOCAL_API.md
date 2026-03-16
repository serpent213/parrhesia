# Parrhesia Shared API

## 1. Goal

Expose a stable in-process API that:

- is used by WebSocket, HTTP management, local callers, and sync workers,
- keeps protocol and storage behavior in one place,
- stays neutral about application-level replication semantics.

This document defines the Parrhesia contract. It does **not** define Tribes or Ash sync behavior.

---

## 2. Scope

### In scope

- event ingest/query/count parity with WebSocket behavior,
- local subscription APIs,
- NIP-98 validation helpers,
- management/admin helpers,
- remote relay sync worker control and health reporting.

### Out of scope

- resource registration,
- trusted app writers,
- mutation payload semantics,
- conflict resolution,
- replay winner selection,
- Ash action mapping.

Those belong in app profiles such as `TRIBES-NOSTRSYNC`, not in Parrhesia.

---

## 3. Layering

```text
Transport / embedding / background workers
  - Parrhesia.Web.Connection
  - Parrhesia.Web.Management
  - Parrhesia.Local.*
  - Parrhesia.Sync.*

Shared API
  - Parrhesia.API.Auth
  - Parrhesia.API.Events
  - Parrhesia.API.Stream
  - Parrhesia.API.Admin
  - Parrhesia.API.Identity
  - Parrhesia.API.ACL
  - Parrhesia.API.Sync

Runtime internals
  - Parrhesia.Policy.EventPolicy
  - Parrhesia.Storage.*
  - Parrhesia.Groups.Flow
  - Parrhesia.Subscriptions.Index
  - Parrhesia.Fanout.MultiNode
  - Parrhesia.Telemetry
```

Rule: transport framing stays at the edge. Business decisions happen in `Parrhesia.API.*`.

---

## 4. Core Context

```elixir
defmodule Parrhesia.API.RequestContext do
  defstruct authenticated_pubkeys: MapSet.new(),
            actor: nil,
            caller: :local,
            metadata: %{}
end
```

`caller` is for telemetry and policy parity, for example `:websocket`, `:http`, `:local`, or `:sync`.

---

## 5. Public Modules

### 5.1 `Parrhesia.API.Auth`

Purpose:

- event validation helpers,
- NIP-98 verification,
- optional embedding account resolution.

```elixir
@spec validate_event(map()) :: :ok | {:error, term()}
@spec compute_event_id(map()) :: String.t()

@spec validate_nip98(String.t() | nil, String.t(), String.t()) ::
  {:ok, Parrhesia.API.Auth.Context.t()} | {:error, term()}

@spec validate_nip98(String.t() | nil, String.t(), String.t(), keyword()) ::
  {:ok, Parrhesia.API.Auth.Context.t()} | {:error, term()}
```

### 5.2 `Parrhesia.API.Events`

Purpose:

- canonical ingest/query/count path used by WS, HTTP, local callers, and sync workers.

```elixir
@spec publish(map(), keyword()) ::
  {:ok, Parrhesia.API.Events.PublishResult.t()} | {:error, term()}

@spec query([map()], keyword()) ::
  {:ok, [map()]} | {:error, term()}

@spec count([map()], keyword()) ::
  {:ok, non_neg_integer() | map()} | {:error, term()}
```

Required options:

- `:context` - `%Parrhesia.API.RequestContext{}`

`publish/2` must preserve current `EVENT` semantics:

1. size checks,
2. `Protocol.validate_event/1`,
3. `EventPolicy.authorize_write/2`,
4. group handling,
5. persistence or control-event path,
6. local plus multi-node fanout,
7. telemetry.

Return shape mirrors `OK`:

```elixir
{:ok, %PublishResult{event_id: id, accepted: true, message: "ok: event stored"}}
{:ok, %PublishResult{event_id: id, accepted: false, message: "blocked: ..."}}
```

`query/2` and `count/2` must preserve current `REQ` and `COUNT` behavior, including giftwrap restrictions and server-side filter validation.

### 5.3 `Parrhesia.API.Stream`

Purpose:

- in-process subscription surface with the same semantics as a WebSocket `REQ`.

This is **required** for embedding and sync consumers.

```elixir
@spec subscribe(pid(), String.t(), [map()], keyword()) ::
  {:ok, reference()} | {:error, term()}

@spec unsubscribe(reference()) :: :ok
```

Required options:

- `:context` - `%Parrhesia.API.RequestContext{}`

Subscriber contract:

```elixir
{:parrhesia, :event, ref, subscription_id, event}
{:parrhesia, :eose, ref, subscription_id}
{:parrhesia, :closed, ref, subscription_id, reason}
```

`subscribe/4` must:

1. validate filters,
2. apply read policy,
3. emit initial catch-up events in the same order as `REQ`,
4. emit exactly one `:eose`,
5. register for live fanout until `unsubscribe/1`.

This module does **not** know why a caller wants the stream.

### 5.4 `Parrhesia.API.Admin`

Purpose:

- stable in-process facade for management operations already exposed over HTTP.

```elixir
@spec execute(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, term()}
@spec stats(keyword()) :: {:ok, map()} | {:error, term()}
@spec health(keyword()) :: {:ok, map()} | {:error, term()}
@spec list_audit_logs(keyword()) :: {:ok, [map()]} | {:error, term()}
```

Baseline methods:

- `ping`
- `stats`
- `health`
- moderation methods already supported by the storage admin adapter

`stats/1` is relay-level and cheap. `health/1` is liveness/readiness-oriented and may include worker state.

`API.Admin` is the operator-facing umbrella for management. It may delegate domain-specific work to `API.Identity`, `API.ACL`, and `API.Sync`.

### 5.5 `Parrhesia.API.Identity`

Purpose:

- manage Parrhesia-owned server identity,
- expose public identity metadata,
- support explicit import and rotation,
- keep private key material internal.

Parrhesia owns a low-level server identity used for relay-to-relay auth and other transport-local security features.

```elixir
@spec get(keyword()) :: {:ok, map()} | {:error, term()}
@spec ensure(keyword()) :: {:ok, map()} | {:error, term()}
@spec import(map(), keyword()) :: {:ok, map()} | {:error, term()}
@spec rotate(keyword()) :: {:ok, map()} | {:error, term()}
@spec sign_event(map(), keyword()) :: {:ok, map()} | {:error, term()}
```

Rules:

- private key material must never be returned by API,
- production deployments should be able to import a configured key,
- local/dev deployments may generate on first init if none exists,
- identity creation should be eager and deterministic, not lazy on first sync use.

Recommended boot order:

1. configured/imported key,
2. persisted local identity,
3. generate once and persist.

### 5.6 `Parrhesia.API.ACL`

Purpose:

- enforce event/filter ACLs for authenticated principals,
- support default-deny sync visibility,
- allow dynamic grants for trusted sync peers.

This is a real authorization layer, not a reuse of moderation allowlists.

```elixir
@spec grant(map(), keyword()) :: :ok | {:error, term()}
@spec revoke(map(), keyword()) :: :ok | {:error, term()}
@spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
@spec check(atom(), map(), keyword()) :: :ok | {:error, term()}
```

Suggested rule shape:

```elixir
%{
  principal_type: :pubkey,
  principal: "<server-auth-pubkey>",
  capability: :sync_read,
  match: %{
    "kinds" => [5000],
    "#r" => ["tribes.accounts.user", "tribes.chat.tribe"]
  }
}
```

For the first implementation, principals should be authenticated pubkeys only.

We do **not** need a separate user-vs-server ACL model yet. A sync peer is simply a principal with sync capabilities.

Initial required capabilities:

- `:sync_read`
- `:sync_write`

Recommended baseline:

- ordinary events follow existing relay behavior,
- sync traffic is default-deny,
- access is lifted only by explicit ACL grants for authenticated server pubkeys.

### 5.7 `Parrhesia.API.Sync`

Purpose:

- manage remote relay sync workers without embedding app-specific replication semantics.

Parrhesia syncs **events**, not records.

```elixir
@spec put_server(map(), keyword()) ::
  {:ok, Parrhesia.API.Sync.Server.t()} | {:error, term()}

@spec remove_server(String.t(), keyword()) :: :ok | {:error, term()}
@spec get_server(String.t(), keyword()) ::
  {:ok, Parrhesia.API.Sync.Server.t()} | :error | {:error, term()}

@spec list_servers(keyword()) ::
  {:ok, [Parrhesia.API.Sync.Server.t()]} | {:error, term()}

@spec start_server(String.t(), keyword()) :: :ok | {:error, term()}
@spec stop_server(String.t(), keyword()) :: :ok | {:error, term()}
@spec sync_now(String.t(), keyword()) :: :ok | {:error, term()}

@spec server_stats(String.t(), keyword()) ::
  {:ok, map()} | :error | {:error, term()}

@spec sync_stats(keyword()) :: {:ok, map()} | {:error, term()}
@spec sync_health(keyword()) :: {:ok, map()} | {:error, term()}
```

`put_server/2` is upsert-style. It covers both add and update.

Minimum server shape:

```elixir
%{
  id: "tribes-a",
  url: "wss://relay-a.example/relay",
  enabled?: true,
  auth_pubkey: "<remote-server-auth-pubkey>",
  filters: [%{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}],
  mode: :req_stream,
  auth: %{type: :nip42},
  tls: %{
    mode: :required,
    hostname: "relay-a.example",
    pins: [
      %{type: :spki_sha256, value: "<base64-sha256-spki-pin>"}
    ]
  }
}
```

Important constraints:

- filters are caller-provided and opaque to Parrhesia,
- Parrhesia does not inspect `kind: 5000` payload semantics,
- Parrhesia may persist peer config and runtime counters,
- Parrhesia may reconnect and resume catch-up using generic event cursors,
- Parrhesia must expose worker health and basic counters,
- remote relay TLS pinning is required,
- sync peer auth is bound to a server-auth pubkey, not inferred from event author pubkeys.

Server identity model:

- Parrhesia owns its local server-auth identity via `API.Identity`,
- peer config declares the expected remote server-auth pubkey,
- ACL grants are bound to authenticated server-auth pubkeys,
- event author pubkeys remain a separate application concern.

Initial mode should be `:req_stream`:

1. run catch-up with `API.Events.query/2`-equivalent client behavior against the remote relay,
2. switch to a live subscription,
3. ingest received events through local `API.Events.publish/2`.

Future optimization:

- `:negentropy` may be added as an optimization mode on top of the simpler `:req_stream` baseline.
- Parrhesia now has a reusable NIP-77 engine, but a sync worker does not need to depend on it for the first implementation.

---

## 6. Server Integration

### WebSocket

- `EVENT` -> `Parrhesia.API.Events.publish/2`
- `REQ` -> `Parrhesia.API.Stream.subscribe/4`
- `COUNT` -> `Parrhesia.API.Events.count/2`
- `AUTH` stays connection-specific, but validation helpers may move to `API.Auth`
- `NEG-*` maps to the reusable NIP-77 engine and remains exposed through the websocket transport boundary

### HTTP management

- NIP-98 validation via `Parrhesia.API.Auth.validate_nip98/3`
- management methods via `Parrhesia.API.Admin`
- sync peer CRUD and health endpoints may delegate to `Parrhesia.API.Sync`
- identity and ACL management may delegate to `API.Identity` and `API.ACL`

### Local wrappers

`Parrhesia.Local.*` remain thin delegates over `Parrhesia.API.*`.

---

## 7. Relationship to Sync Profiles

This document is intentionally lower-level than `TRIBES-NOSTRSYNC` and `SYNC_DB.md`.

Those documents may require:

- `Parrhesia.API.Events.publish/2`
- `Parrhesia.API.Events.query/2`
- `Parrhesia.API.Stream.subscribe/4`
- `Parrhesia.API.Sync.*`

But they must not move application conflict rules or payload semantics into Parrhesia.
