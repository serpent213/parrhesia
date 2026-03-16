# NIP-DBSYNC — Minimal Mutation Events over Nostr

`draft` `optional`

Defines a minimal event format for publishing immutable application mutation events over Nostr.

This draft intentionally standardizes only the wire format for mutation transport. It does **not** standardize database replication strategy, conflict resolution, relay retention, or key derivation.

---

## Abstract

This NIP defines one regular event kind, **5000**, for signed mutation events.

A mutation event identifies:

- the object namespace being mutated,
- the object identifier within that namespace,
- the mutation operation,
- an optional parent mutation event,
- an application-defined payload.

The purpose of this NIP is to make signed mutation logs portable across Nostr clients and relays without requiring relays to implement database-specific behavior.

---

## Motivation

Many applications need a way to distribute signed state changes across multiple publishers, consumers, or services.

Today this can be done with private event kinds, but private schemas make cross-implementation interoperability harder than necessary. This NIP defines a small shared envelope for mutation events while leaving application-specific state semantics in the payload.

This NIP is intended for use cases such as:

- synchronizing object changes between cooperating services,
- publishing auditable mutation logs,
- replaying application events from ordinary Nostr relays,
- bridging non-Nostr systems into a Nostr-based event stream.

This NIP is **not** a consensus protocol. It does not provide:

- total ordering,
- transactional guarantees,
- global conflict resolution,
- authorization rules,
- guaranteed relay retention.

Applications that require those properties MUST define them separately.

---

## Specification

### Event Kind

| Kind | Category | Name |
|------|----------|------|
| 5000 | Regular | Mutation |

Kind `5000` is a regular event. Relays that support this NIP MAY store it like any other regular event.

This NIP does **not** require relays to:

- retain all historical events,
- index any specific tag beyond normal NIP-01 behavior,
- deliver events in causal or chronological order,
- detect or resolve conflicts.

Applications that depend on durable replay or custom indexing MUST choose relays whose policies satisfy those needs.

### Event Structure

```json
{
  "id": "<32-byte lowercase hex>",
  "pubkey": "<32-byte lowercase hex>",
  "created_at": "<unix timestamp, seconds>",
  "kind": 5000,
  "tags": [
    ["r", "<resource namespace>"],
    ["i", "<object identifier>"],
    ["op", "<mutation operation>"],
    ["e", "<parent mutation event id>"]
  ],
  "content": "<JSON-encoded application payload>",
  "sig": "<64-byte lowercase hex>"
}
```

The `content` field is a JSON-encoded string. Its structure is defined below.

---

## Tags

| Tag | Required | Description |
|-----|----------|-------------|
| `r` | Yes | Stable resource namespace for the mutated object type. Reverse-DNS style names are RECOMMENDED, for example `com.example.accounts.user`. |
| `i` | Yes | Opaque object identifier, unique within the `r` namespace. Consumers MUST treat this as a string. |
| `op` | Yes | Mutation operation. This NIP defines only `upsert` and `delete`. |
| `e` | No | Parent mutation event id, if the publisher wants to express ancestry. At most one `e` tag SHOULD be included in this version of the protocol. |
| `v` | No | Application payload schema version as a string. RECOMMENDED when the payload format may evolve over time. |

### Tag Rules

Publishers:

- MUST include exactly one `r` tag.
- MUST include exactly one `i` tag.
- MUST include exactly one `op` tag.
- MUST set `op` to either `upsert` or `delete`.
- SHOULD include at most one `e` tag.
- MAY include one `v` tag.

Consumers:

- MUST ignore unknown tags.
- MUST NOT assume tag ordering.
- MUST treat the `e` tag as an ancestry hint, not as proof of global ordering.

### Resource Namespaces

The `r` tag identifies an application-level object type.

This NIP does not define a global registry of resource namespaces. To reduce collisions, publishers SHOULD use a stable namespace they control, such as reverse-DNS notation.

Examples:

- `com.example.accounts.user`
- `org.example.inventory.item`
- `net.example.billing.invoice`

Publishers MUST document the payload schema associated with each resource namespace they use.

---

## Content Payload

The `content` field MUST be a JSON-encoded object.

```json
{
  "value": {},
  "patch": "merge"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `value` | Yes | Application-defined mutation payload. For `upsert`, this is the state fragment or full post-mutation state being published. For `delete`, this MAY be an empty object or a small reason object. |
| `patch` | No | How `value` should be interpreted. This NIP defines `merge` and `replace`. If omitted, consumers MUST treat it as application-defined. |

### Payload Rules

For `op = upsert`:

- `value` MUST be a JSON object.
- Publishers SHOULD publish either:
  - a partial object intended to be merged, or
  - a full post-mutation object intended to replace prior state.
- If the interpretation is important for interoperability, publishers SHOULD set `patch` to `merge` or `replace`.

For `op = delete`:

- `value` MAY be `{}`.
- Consumers MUST treat `delete` as an application-level tombstone signal.
- This NIP does not define whether deletion means hard delete, soft delete, archival, or hiding. Applications MUST define that separately.

### Serialization

All payload values MUST be JSON-serializable.

The following representations are RECOMMENDED:

| Type | Representation |
|------|----------------|
| Timestamp / datetime | ISO 8601 string |
| Decimal | String |
| Binary | Base64 string |
| Null | JSON `null` |

Publishers MAY define additional type mappings, but those mappings are application-specific and MUST be documented outside this NIP.

---

## Ancestry and Replay

The optional `e` tag allows a publisher to indicate which prior mutation event it considered the parent when creating a new mutation.

This supports applications that want ancestry hints for:

- local conflict detection,
- replay ordering,
- branch inspection,
- audit tooling.

However:

- the `e` tag does **not** create a global ordering guarantee,
- relays are not required to deliver parents before children,
- consumers MUST be prepared to receive out-of-order events,
- consumers MAY buffer, defer, ignore, or immediately apply parent-missing events according to local policy.

This NIP does not define a merge event format.

This NIP does not define conflict resolution. If two valid mutation events for the same `(r, i)` object are concurrent or incompatible, consumers MUST resolve them using application-specific rules.

---

## Authorization

This NIP does not define who is authorized to publish mutation events for a given resource or object.

Authorization is application-specific.

Consumers MUST NOT assume that a valid Nostr signature alone authorizes a mutation. Consumers MUST apply their own trust policy, which MAY include:

- explicit pubkey allowlists,
- per-resource ACLs,
- external capability documents,
- relay-level write restrictions,
- application-specific verification.

This NIP does not define custodial keys, deterministic key derivation, shared cluster secrets, or delegation schemes.

---

## Relay Behavior

A relay implementing only NIP-01 remains compatible with this NIP.

No new relay messages are required beyond `REQ`, `EVENT`, and `CLOSE`.

Relays:

- MAY index the `r` and `i` tags using existing single-letter tag indexing conventions.
- MAY apply normal retention, rate-limit, and access-control policies.
- MAY reject events that are too large or otherwise violate local policy.
- MUST NOT be expected to validate application payload semantics.

Applications that require stronger guarantees, such as durable retention or strict admission control, MUST obtain those guarantees from relay policy or from a separate protocol profile.

---

## Subscription Filters

This NIP works with ordinary NIP-01 filters.

### All mutations for one resource

```json
{
  "kinds": [5000],
  "#r": ["com.example.accounts.user"]
}
```

### Mutation history for one object

```json
{
  "kinds": [5000],
  "#r": ["com.example.accounts.user"],
  "#i": ["550e8400-e29b-41d4-a716-446655440000"]
}
```

### Mutations from trusted authors

```json
{
  "kinds": [5000],
  "authors": [
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  ]
}
```

Applications SHOULD prefer narrow subscriptions over broad network-wide firehoses.

---

## Examples

### Upsert with parent

```json
{
  "id": "1111111111111111111111111111111111111111111111111111111111111111",
  "pubkey": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "created_at": 1710500300,
  "kind": 5000,
  "tags": [
    ["r", "com.example.accounts.user"],
    ["i", "550e8400-e29b-41d4-a716-446655440000"],
    ["op", "upsert"],
    ["e", "0000000000000000000000000000000000000000000000000000000000000000"],
    ["v", "1"]
  ],
  "content": "{\"value\":{\"email\":\"jane.doe@newdomain.com\",\"updated_at\":\"2025-03-15T14:35:00Z\"},\"patch\":\"merge\"}",
  "sig": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
}
```

### Delete tombstone

```json
{
  "id": "2222222222222222222222222222222222222222222222222222222222222222",
  "pubkey": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "created_at": 1710500600,
  "kind": 5000,
  "tags": [
    ["r", "com.example.accounts.user"],
    ["i", "550e8400-e29b-41d4-a716-446655440000"],
    ["op", "delete"],
    ["e", "1111111111111111111111111111111111111111111111111111111111111111"],
    ["v", "1"]
  ],
  "content": "{\"value\":{\"reason\":\"user_requested\"}}",
  "sig": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
}
```

---

## Security Considerations

- **Unauthorized writes:** A valid signature proves authorship, not authorization. Consumers MUST enforce their own trust policy.
- **Replay:** Old valid events may be redelivered by relays or attackers. Consumers SHOULD deduplicate by event id and apply local replay policy.
- **Reordering:** Events may arrive out of order. Consumers MUST NOT treat `created_at` or `e` as a guaranteed total order.
- **Conflict flooding:** Multiple valid mutations may target the same object. Consumers SHOULD rate-limit, bound buffering, and define local conflict policy.
- **Sensitive data exposure:** Nostr events are typically widely replicable. Publishers SHOULD NOT put secrets or regulated data in mutation payloads unless they provide application-layer encryption.
- **Relay retention variance:** Some relays will prune history. Applications that depend on full replay MUST choose relays accordingly or maintain an external archive.

---

## Extension Points

Future drafts or companion NIPs may define:

- snapshot events for faster bootstrap,
- object-head or checkpoint events,
- capability or delegation profiles for authorized writers,
- standardized conflict-resolution profiles for specific application classes.

Such extensions SHOULD remain optional and MUST NOT change the meaning of kind `5000` mutation events defined here.

---

## References

- [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) — Basic protocol flow description
