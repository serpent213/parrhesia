# Parrhesia Shared API + Local API Design (Option 1)

## 1) Goal

Expose a stable in-process API for embedding apps **and** refactor server transports to consume the same API.

Desired end state:

- WebSocket server, HTTP management, and embedding app all call one shared core API.
- Transport layers (WS/HTTP/local) only do framing, auth header extraction, and response encoding.
- Policy/storage/fanout/business semantics live in one place.

This keeps everything in the same dependency (`:parrhesia`) and avoids a second package.

---

## 2) Key architectural decision

Previous direction: `Parrhesia.Local.*` as primary public API.

Updated direction (this doc):

- Introduce **shared core API modules** under `Parrhesia.API.*`.
- Make server code (`Parrhesia.Web.Connection`, management handlers) delegate to `Parrhesia.API.*`.
- Keep `Parrhesia.Local.*` as optional convenience wrappers over `Parrhesia.API.*`.

This ensures no divergence between local embedding behavior and websocket behavior.

---

## 3) Layered design

```text
Transport layer
  - Parrhesia.Web.Connection (WS)
  - Parrhesia.Web.Management (HTTP)
  - Parrhesia.Local.* wrappers (in-process)

Shared API layer
  - Parrhesia.API.Auth
  - Parrhesia.API.Events
  - Parrhesia.API.Stream (optional)
  - Parrhesia.API.Admin (optional, for management methods)

Domain/runtime dependencies
  - Parrhesia.Policy.EventPolicy
  - Parrhesia.Storage.* adapters
  - Parrhesia.Groups.Flow
  - Parrhesia.Subscriptions.Index
  - Parrhesia.Fanout.MultiNode
  - Parrhesia.Telemetry
```

Rule: all ingest/query/count decisions happen in `Parrhesia.API.Events`.

---

## 4) Public module plan

## 4.1 `Parrhesia.API.Auth`

Purpose:
- event validation helpers
- NIP-98 verification
- optional embedding account resolution hook

Proposed functions:

```elixir
@spec validate_event(map()) :: :ok | {:error, term()}
@spec compute_event_id(map()) :: String.t()

@spec validate_nip98(String.t() | nil, String.t(), String.t()) ::
  {:ok, Parrhesia.API.Auth.Context.t()} | {:error, term()}

@spec validate_nip98(String.t() | nil, String.t(), String.t(), keyword()) ::
  {:ok, Parrhesia.API.Auth.Context.t()} | {:error, term()}
```

`validate_nip98/4` options:

```elixir
account_resolver: (pubkey_hex :: String.t(), auth_event :: map() ->
  {:ok, account :: term()} | {:error, term()})
```

Context struct:

```elixir
defmodule Parrhesia.API.Auth.Context do
  @enforce_keys [:pubkey, :auth_event]
  defstruct [:pubkey, :auth_event, :account, claims: %{}]
end
```

---

## 4.2 `Parrhesia.API.Events`

Purpose:
- canonical ingress/query/count API used by WS + local + HTTP integrations.

Proposed functions:

```elixir
@spec publish(map(), keyword()) :: {:ok, Parrhesia.API.Events.PublishResult.t()} | {:error, term()}
@spec query([map()], keyword()) :: {:ok, [map()]} | {:error, term()}
@spec count([map()], keyword()) :: {:ok, non_neg_integer() | map()} | {:error, term()}
```

Request context:

```elixir
defmodule Parrhesia.API.RequestContext do
  defstruct authenticated_pubkeys: MapSet.new(),
            actor: nil,
            metadata: %{}
end
```

Publish result:

```elixir
defmodule Parrhesia.API.Events.PublishResult do
  @enforce_keys [:event_id, :accepted, :message]
  defstruct [:event_id, :accepted, :message]
end
```

### Publish semantics (must match websocket EVENT)

Pipeline in `publish/2`:

1. frame/event size limits
2. `Parrhesia.Protocol.validate_event/1`
3. `Parrhesia.Policy.EventPolicy.authorize_write/2`
4. group handling (`Parrhesia.Groups.Flow.handle_event/1`)
5. persistence path (`put_event`, deletion, vanish, ephemeral rules)
6. fanout (local + multi-node)
7. telemetry emit

Return shape mirrors Nostr `OK` semantics:

```elixir
{:ok, %PublishResult{event_id: id, accepted: true, message: "ok: event stored"}}
{:ok, %PublishResult{event_id: id, accepted: false, message: "blocked: ..."}}
```

### Query/count semantics (must match websocket REQ/COUNT)

`query/2` and `count/2`:

1. validate filters
2. run read policy (`EventPolicy.authorize_read/2`)
3. call storage with `requester_pubkeys` from context
4. return ordered events/count payload

Giftwrap restrictions (`kind 1059`) must remain identical to websocket behavior.

---

## 4.3 `Parrhesia.API.Stream` (optional but recommended)

Purpose:
- local in-process subscriptions using same subscription index/fanout model.

Proposed functions:

```elixir
@spec subscribe(pid(), String.t(), [map()], keyword()) :: {:ok, reference()} | {:error, term()}
@spec unsubscribe(reference()) :: :ok
```

Subscriber contract:

```elixir
{:parrhesia, :event, ref, subscription_id, event}
{:parrhesia, :eose, ref, subscription_id}
{:parrhesia, :closed, ref, subscription_id, reason}
```

---

## 4.4 `Parrhesia.Local.*` wrappers

`Parrhesia.Local.*` remain as convenience API for embedding apps, implemented as thin wrappers:

- `Parrhesia.Local.Auth` -> delegates to `Parrhesia.API.Auth`
- `Parrhesia.Local.Events` -> delegates to `Parrhesia.API.Events`
- `Parrhesia.Local.Stream` -> delegates to `Parrhesia.API.Stream`
- `Parrhesia.Local.Client` -> use-case helpers (posts + private messages)

No business logic in wrappers.

---

## 5) Server integration plan (critical)

## 5.1 WebSocket (`Parrhesia.Web.Connection`)

After decode:
- `EVENT` -> `Parrhesia.API.Events.publish/2`
- `REQ` -> `Parrhesia.API.Events.query/2`
- `COUNT` -> `Parrhesia.API.Events.count/2`
- `AUTH` keep transport-specific challenge/session flow, but can use `API.Auth.validate_event/1` internally

WebSocket keeps responsibility for:
- websocket framing
- subscription lifecycle per connection
- AUTH challenge rotation protocol frames

## 5.2 HTTP management (`Parrhesia.Web.Management`)

- NIP-98 header validation via `Parrhesia.API.Auth.validate_nip98/3`
- command execution via `Parrhesia.API.Admin` (or existing storage admin adapter via API facade)

---

## 6) High-level client helpers for embedding app use case

These helpers are optional and live in `Parrhesia.Local.Client`.

## 6.1 Public posts

```elixir
@spec publish_post(Parrhesia.API.Auth.Context.t(), String.t(), keyword()) ::
  {:ok, Parrhesia.API.Events.PublishResult.t()} | {:error, term()}

@spec list_posts(keyword()) :: {:ok, [map()]} | {:error, term()}
@spec stream_posts(pid(), keyword()) :: {:ok, reference()} | {:error, term()}
```

`publish_post/3` options:
- `:tags`
- `:created_at`
- `:signer` callback (required unless fully signed event provided)

Signer contract:

```elixir
(unsigned_event_map -> {:ok, signed_event_map} | {:error, term()})
```

Parrhesia does not store or manage private keys.

## 6.2 Private messages (giftwrap kind 1059)

```elixir
@spec send_private_message(
  Parrhesia.API.Auth.Context.t(),
  recipient_pubkey :: String.t(),
  encrypted_payload :: String.t(),
  keyword()
) :: {:ok, Parrhesia.API.Events.PublishResult.t()} | {:error, term()}

@spec inbox(Parrhesia.API.Auth.Context.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
@spec stream_inbox(pid(), Parrhesia.API.Auth.Context.t(), keyword()) :: {:ok, reference()} | {:error, term()}
```

Behavior:
- `send_private_message/4` builds event template with kind `1059` and `p` tag.
- host signer signs template.
- publish through `API.Events.publish/2`.
- `inbox/2` queries `%{"kinds" => [1059], "#p" => [auth.pubkey]}` with authenticated context.

---

## 7) Error model

Shared API should normalize output regardless of transport.

Guideline:
- protocol/policy rejection -> `{:ok, %{accepted: false, message: "..."}}`
- runtime/system failure -> `{:error, term()}`

Common reason mapping:

| Reason | Message prefix |
|---|---|
| `:auth_required` | `auth-required:` |
| `:restricted_giftwrap` | `restricted:` |
| `:invalid_event` | `invalid:` |
| `:duplicate_event` | `duplicate:` |
| `:event_rate_limited` | `rate-limited:` |

---

## 8) Telemetry

Emit shared events in API layer (not transport-specific):

- `[:parrhesia, :api, :publish, :stop]`
- `[:parrhesia, :api, :query, :stop]`
- `[:parrhesia, :api, :count, :stop]`
- `[:parrhesia, :api, :auth, :stop]`

Metadata:
- `traffic_class`
- `caller` (`:websocket | :http | :local`)
- optional `account_present?`

Transport-level telemetry can remain separate where needed.

---

## 9) Refactor sequence

### Phase 1: Extract shared API
1. Create `Parrhesia.API.Events` with publish/query/count from current `Web.Connection` paths.
2. Create `Parrhesia.API.Auth` wrappers for NIP-98/event validation.
3. Add API-level tests.

### Phase 2: Migrate transports
1. Update `Parrhesia.Web.Connection` to delegate publish/query/count to `API.Events`.
2. Update `Parrhesia.Web.Management` to use `API.Auth`.
3. Keep behavior unchanged.

### Phase 3: Add local wrappers/helpers
1. Implement `Parrhesia.Local.Auth/Events/Stream` as thin delegates.
2. Add `Parrhesia.Local.Client` post/inbox/send helpers.
3. Add embedding documentation.

### Phase 4: Lock parity
1. Add parity tests: WS vs Local API for same inputs and policy outcomes.
2. Add property tests for query/count equivalence where feasible.

---

## 10) Testing requirements

1. **Transport parity tests**
   - Same signed event via WS and API => same accepted/message semantics.
2. **Policy parity tests**
   - Giftwrap visibility and auth-required behavior identical across WS/API/local.
3. **Auth tests**
   - NIP-98 success/failure + account resolver success/failure.
4. **Fanout tests**
   - publish via API reaches local stream subscribers and WS subscribers.
5. **Failure tests**
   - storage failures surface deterministic errors in all transports.

---

## 11) Backwards compatibility

- No breaking change to websocket protocol.
- No breaking change to management endpoint contract.
- New API modules are additive.
- Existing apps can ignore local API entirely.

---

## 12) Embedding example flow

### 12.1 Login/auth

```elixir
with {:ok, auth} <- Parrhesia.API.Auth.validate_nip98(header, method, url,
       account_resolver: &MyApp.Accounts.resolve_nostr_pubkey/2
     ) do
  # use auth.pubkey/auth.account in host session
end
```

### 12.2 Post publish

```elixir
Parrhesia.Local.Client.publish_post(auth, "hello", signer: &MyApp.NostrSigner.sign/1)
```

### 12.3 Private message

```elixir
Parrhesia.Local.Client.send_private_message(
  auth,
  recipient_pubkey,
  encrypted_payload,
  signer: &MyApp.NostrSigner.sign/1
)
```

### 12.4 Inbox

```elixir
Parrhesia.Local.Client.inbox(auth, limit: 100)
```

---

## 13) Summary

Yes, this can and should be extracted into a shared API module. The server should consume it too.

That gives:
- one canonical behavior path,
- cleaner embedding,
- easier testing,
- lower long-term maintenance cost.
