# NIP-DBSYNC — Database Replication over Nostr

`draft` `optional`

Defines a set of custom Nostr event kinds for replicating database record state across distributed nodes via Nostr relays.

---

## Abstract

This NIP specifies event kinds **5000–5002** for distributing database create, update, and destroy operations as Nostr events. Each participating node maintains a local database as its read/write model and uses Nostr as the replication bus. Events carry the full mutation payload (caller input, computed attributes, metadata) and form per-record causal chains via `e` tags, enabling conflict detection and field-level merge resolution.

A three-tier signing model supports node-level, user-server-level, and user-personal-level event authorship with deterministic key derivation for the custodial tier.

---

## Motivation

Applications backed by a single database instance face a single point of failure. For multi-node deployments, sharing one database requires all nodes to have network access to it and introduces a central bottleneck. By replicating database mutations as Nostr events:

- Each node operates independently against its own local database.
- The Nostr relay mesh handles event distribution and persistence.
- Cryptographic signatures provide tamper detection and authorship verification that a database column cannot.
- Nodes can recover from downtime by replaying missed events.
- New nodes can bootstrap by replaying the full event history.

The consistency model is deliberately relaxed — closer to a social network than a central bank. Eventual consistency with per-field last-write-wins conflict resolution.

---

## Specification

### Event Kinds

| Kind | Category | Name | Relay Behaviour |
|------|----------|------|-----------------|
| 5000 | Regular  | Record Create | Stored permanently, full history retained |
| 5001 | Regular  | Record Update | Stored permanently, full history retained |
| 5002 | Regular  | Record Destroy | Stored permanently, full history retained |

All kinds fall in the regular range (1000–9999). Relays MUST store all events of these kinds and MUST NOT treat them as replaceable. Full history is required for replay and recovery.

Standard kind 5 (NIP-09 deletion requests) MAY be used to retract erroneous sync events. Receiving implementations SHOULD honour deletion requests from the same pubkey.

### Event Structure

```json
{
  "id": "<32-byte hex, sha256 of serialised event>",
  "pubkey": "<32-byte hex, signer's public key>",
  "created_at": "<unix timestamp, seconds>",
  "kind": 5000,
  "tags": [
    ["r", "<qualified resource name>"],
    ["i", "<record primary key>"],
    ["act", "<operation name>"],
    ["v", "<schema version>"],
    ["n", "<originating node pubkey hex>"],
    ["e", "<parent event id for this record>"],
    ["f", "<comma-separated changed field names>"],
    ["u", "<acting user pubkey hex>"],
    ["seq", "<per-record sequence number>"]
  ],
  "content": "<JSON-encoded payload>",
  "sig": "<64-byte hex, Schnorr signature>"
}
```

### Tags

All tags use single-letter keys where possible to ensure relay indexing (NIP-01 guarantees single-letter tag indexing). Multi-letter tags are used only where no single-letter tag is appropriate.

| Tag | Key | Required | Indexed | Description |
|-----|-----|----------|---------|-------------|
| `r` | Resource | Yes | Yes | Qualified name identifying the resource type (table, collection, entity). Format is implementation-defined but MUST be unique within the cluster. Examples: `"accounts.users"`, `"MyApp.Accounts.User"`, `"public.orders"`. |
| `i` | Record ID | Yes | Yes | Primary key value of the affected record, as a string. UUIDs recommended. Composite keys SHOULD be serialised as a deterministic JSON array (e.g., `"[\"tenant_a\",\"123\"]"`). |
| `e` | Parent | No | Yes | Event ID of the most recent prior event for this record from the signer's perspective. Omitted on the first event for a record (kind 5000 create with no prior history). Forms the causal chain. |
| `f` | Fields | No | No | Comma-separated list of column/attribute names changed in this mutation. Example: `"name,email,status"`. Omitted for creates (all fields are new) and destroys. Used for field-level conflict resolution. |
| `v` | Version | Yes | No | Integer schema version as a string. Incremented when the event content structure changes for a given resource/operation combination. Default: `"1"`. |
| `n` | Node | Yes | Yes | Public key (hex) of the originating node. Used for echo suppression — a node discards events where the `n` tag matches its own pubkey. |
| `u` | User | No | Yes | Public key (hex) of the acting user. Present when a node key or user-server key signs on behalf of a user. See [Signing Model](#signing-model). |
| `act` | Operation | Yes | No | Name of the operation that produced this event. Examples: `"create"`, `"update_email"`, `"soft_delete"`. Receiving nodes use this to determine how to apply the mutation. |
| `seq` | Sequence | No | No | Monotonically increasing integer (as string) per record per originating node. Provides a secondary ordering signal and gap detection. |

#### Tag Ordering Convention

Tags SHOULD appear in the order listed above. Implementations MUST NOT depend on tag ordering.

### Content Payload

The `content` field contains a JSON object with three keys:

```json
{
  "data": { },
  "computed": { },
  "metadata": { }
}
```

| Field | Description |
|-------|-------------|
| `data` | The original mutation input — fields and values as provided by the caller before any defaults, triggers, or computed columns were applied. Keys are column/attribute names as strings. Values are JSON-serialisable representations. |
| `computed` | Fields whose values were set by the system during mutation execution (auto-generated IDs, timestamps, sequences, computed columns, default values). These were NOT in the original caller input. On replay, these MUST be force-applied to reproduce exact state. |
| `metadata` | Freeform object for application-specific context. Examples: `"source"` (API, web, CLI), `"request_id"`, `"ip_address"`, `"tenant"`. Implementations SHOULD NOT use metadata for replay logic. |

#### Content by Kind

**Kind 5000 (Create):**
- `data`: all input fields provided by the caller.
- `computed`: all fields set by the system (generated ID, timestamps, defaults, computed columns).
- `f` tag: SHOULD be omitted (all fields are new).

**Kind 5001 (Update):**
- `data`: only the fields explicitly changed by the caller.
- `computed`: only fields modified by the system as a side effect of this update (e.g., `updated_at`).
- `f` tag: MUST list all field names present in `data` AND `computed`.

**Kind 5002 (Destroy):**
- `data`: any arguments passed to the destroy operation (e.g., soft-delete reason).
- `computed`: typically empty. May contain final state modifications for soft deletes (e.g., `deleted_at`, `status`).
- `f` tag: SHOULD be omitted.

#### Sensitive Fields

Fields marked as sensitive or secret in the application schema (passwords, tokens, PII as required by policy) MUST be excluded from `data` and `computed` unless the implementation provides encryption for the content payload. If sensitive fields are included, the `content` field SHOULD be encrypted (application-level; encryption scheme is out of scope for this NIP).

#### Serialisation

All values in `data` and `computed` MUST be JSON-serialisable. Types that have no native JSON representation require explicit serialisation. The following conventions are RECOMMENDED:

| Type | JSON Representation |
|------|-------------------|
| Timestamps / datetimes | ISO 8601 string (e.g., `"2025-03-15T14:30:00Z"`) |
| Arbitrary-precision decimals | String (to preserve precision) |
| Enumerations / symbols | String |
| Sets | Array |
| Binary data (non-UTF-8) | Base64-encoded string with `{"__binary__": "<base64>"}` wrapper |
| Nested/embedded objects | JSON object |
| NULL | JSON `null` |

Implementations MAY define additional type mappings. Custom mappings SHOULD be documented alongside the schema version.

---

### Signing Model

Events use a three-tier signing hierarchy. The `pubkey` field always identifies the signer.

#### Tier 1: Node Key

Each node in the cluster holds a secp256k1 keypair. Used for:
- System-initiated operations (background jobs, migrations, automated maintenance)
- Any operation where no user context is available

The node pubkey is registered in the cluster's trusted key set.

#### Tier 2: User Server Key (Custodial)

Each user has a server-side keypair derived deterministically from a shared cluster secret and the user's stable identifier. Used for:
- User-triggered mutations executed on the server (profile updates, settings changes, etc.)
- Any operation where the user is authenticated but their personal key is not available for signing

**Deterministic derivation:**

```
user_server_privkey = HMAC-SHA256(cluster_secret, "nostr-dbsync-user-key:" || user_id)
```

The HMAC output (32 bytes) is used directly as the secp256k1 private key. The corresponding public key is derived per standard secp256k1 operations (x-only, as per BIP-340).

All nodes sharing the same `cluster_secret` and `user_id` independently derive the same keypair. No key distribution is required.

**Requirements:**
- `cluster_secret` MUST be at least 32 bytes of cryptographically random data.
- `cluster_secret` MUST be identical across all nodes in the cluster.
- `cluster_secret` MUST be stored securely (environment variable, secrets manager) and MUST NOT appear in event data, logs, or Nostr content.
- `user_id` MUST be a stable, unique identifier for the user (UUID recommended). It MUST NOT change over the user's lifetime.

When a user-server key signs a sync event, the `u` tag SHOULD also be set to the user's personal pubkey (if known), to enable cross-referencing.

#### Tier 3: User Personal Key (Non-Custodial)

The user's own Nostr keypair, held on their device. Used for:
- Signing regular Nostr content (kind 1, etc.)
- Future: signing high-trust database operations via NIP-46 (Nostr Connect)

User personal keys do NOT sign sync events in the initial implementation. NIP-46 integration is a future extension.

When a user personal key eventually signs a sync event directly, the `u` tag is omitted (the `pubkey` field IS the user).

#### Trust Verification

Receiving nodes MUST verify that the event's `pubkey` is trusted before applying it:

1. **Node keys:** Check against the configured trusted node pubkey set.
2. **User server keys:** Derive the expected pubkey from `cluster_secret` + user ID (looked up via the `u` tag or record context) and verify it matches.
3. **User personal keys:** (Future) Verify the pubkey corresponds to a known user in the local database.

Events from untrusted pubkeys MUST be rejected. Implementations SHOULD log rejected events for debugging.

---

### Causal Chain

Each record's mutation history forms a singly-linked list via `e` tags:

```
E1 (create)  ←──  E2 (update)  ←──  E3 (update)  ←──  E4 (destroy)
   [no e tag]      [e: E1.id]        [e: E2.id]        [e: E3.id]
```

The `e` tag points to the most recent event the signer was aware of for this record at the time of mutation. This is NOT necessarily the globally latest event — under concurrent modification, two nodes may each produce events pointing to the same parent:

```
                 E2 (Node A)  [e: E1.id]
                /
E1 (create)  ──
                \
                 E3 (Node B)  [e: E1.id]
```

This fork is a **conflict**. See [Conflict Resolution](#conflict-resolution).

#### Sequence Numbers

The `seq` tag provides a secondary ordering signal per (record, originating node). It is a monotonically increasing integer starting at 1 for the create event. Gaps in sequence numbers from a given node indicate missed events. Implementations MAY use sequence gaps to trigger catch-up queries.

---

### Conflict Resolution

Conflict resolution is an application-level concern, not a relay concern. This section defines the RECOMMENDED algorithm for implementations.

#### Detection

A conflict exists when two events for the same record reference the same parent `e` tag (or both omit it, which can only happen if two nodes independently create a record with the same ID — an error condition).

#### Resolution: Per-Field Last-Write-Wins

1. Parse the `f` tag of both conflicting events to determine which fields each changed.
2. **Disjoint fields:** Apply both changes. No data loss.
3. **Overlapping fields:** The event with the higher `created_at` wins. Tie-break: the event with the lexicographically lower `id` wins (consistent with NIP-01 replaceable event semantics).
4. After resolution, the resolving node emits a new update event (kind 5001) with `e` tags referencing BOTH conflicting events. This **merge event** collapses the fork into a single chain head.

#### Merge Event Structure

A merge event has multiple `e` tags — one for each parent being merged:

```json
{
  "kind": 5001,
  "tags": [
    ["e", "<event_A_id>"],
    ["e", "<event_B_id>"],
    ["f", "<all fields from merged result>"],
    ["r", "..."],
    ["i", "..."],
    ...
  ]
}
```

Implementations receiving a merge event with multiple `e` tags SHOULD treat it as authoritative resolution and update their local state accordingly.

#### No Conflict (Fast Path)

If an incoming event's `e` tag matches the receiving node's latest known event for that record, there is no conflict. Apply directly.

If an incoming event's `e` tag references an event the receiving node has NOT yet seen, the event SHOULD be buffered until the parent arrives (or a timeout triggers a catch-up query).

---

### Relay Behaviour

Relays implementing this NIP:

- MUST store events of kinds 5000, 5001, 5002 as regular (non-replaceable) events.
- MUST support filtering by `r`, `i`, `e`, `n`, and `u` tags.
- SHOULD support the `since` filter for efficient catch-up queries.
- SHOULD NOT impose aggressive retention limits on these kinds (full history is needed for replay).
- MAY apply rate limits consistent with the expected mutation rate of the cluster.

---

### Subscription Filters

#### Live sync (all resource events from other nodes)

```json
{
  "kinds": [5000, 5001, 5002]
}
```

Post-filter by `n` tag client-side for echo suppression (discard events where `n` matches own node pubkey).

#### Catch-up after downtime

```json
{
  "kinds": [5000, 5001, 5002],
  "since": <last_processed_created_at>
}
```

#### Single resource type

```json
{
  "kinds": [5000, 5001, 5002],
  "#r": ["accounts.users"]
}
```

#### Single record history

```json
{
  "kinds": [5000, 5001, 5002],
  "#i": ["550e8400-e29b-41d4-a716-446655440000"]
}
```

---

### Recovery

#### Node restart (catch-up)

1. Read `last_processed_at` from local cursor storage.
2. Subscribe with `since: last_processed_at`.
3. Process all backlog events (delivered before EOSE).
4. Continue with live subscription.

#### New node (full replay)

1. Subscribe with no `since` filter.
2. Relay delivers all stored events (oldest first by `created_at`, tie-break by `id`).
3. Apply each event to local database via the appropriate operation.
4. After EOSE, continue with live subscription.

Full replay is the only bootstrap mechanism specified. Snapshot-based bootstrap (e.g., via database dumps on object storage) is an implementation optimisation outside the scope of this NIP.

---

### Schema Evolution

The `v` tag carries the schema version for the event's content structure. When the shape of `data` or `computed` changes for a resource/operation combination:

1. Increment the version number in the publishing implementation.
2. Receiving implementations MUST support transforming older versions to the current shape.
3. Replay of historical events MUST apply the appropriate version transformation before processing.

Version `"1"` is the default. Implementations MUST NOT omit the `v` tag.

---

## Example Events

### Create (Kind 5000)

```json
{
  "id": "a1b2c3...",
  "pubkey": "node_a_pubkey_hex",
  "created_at": 1710500000,
  "kind": 5000,
  "tags": [
    ["r", "accounts.users"],
    ["i", "550e8400-e29b-41d4-a716-446655440000"],
    ["act", "create"],
    ["v", "1"],
    ["n", "node_a_pubkey_hex"],
    ["u", "user_personal_pubkey_hex"],
    ["seq", "1"]
  ],
  "content": "{\"data\":{\"name\":\"Jane Doe\",\"email\":\"jane@example.com\"},\"computed\":{\"id\":\"550e8400-e29b-41d4-a716-446655440000\",\"status\":\"active\",\"slug\":\"jane-doe\",\"created_at\":\"2025-03-15T14:30:00Z\",\"updated_at\":\"2025-03-15T14:30:00Z\"},\"metadata\":{\"source\":\"api\",\"request_id\":\"req-abc123\"}}",
  "sig": "..."
}
```

### Update (Kind 5001)

```json
{
  "id": "d4e5f6...",
  "pubkey": "user_server_key_hex",
  "created_at": 1710500300,
  "kind": 5001,
  "tags": [
    ["r", "accounts.users"],
    ["i", "550e8400-e29b-41d4-a716-446655440000"],
    ["act", "update_email"],
    ["v", "1"],
    ["n", "node_b_pubkey_hex"],
    ["e", "a1b2c3..."],
    ["f", "email,updated_at"],
    ["u", "user_personal_pubkey_hex"],
    ["seq", "2"]
  ],
  "content": "{\"data\":{\"email\":\"jane.doe@newdomain.com\"},\"computed\":{\"updated_at\":\"2025-03-15T14:35:00Z\"},\"metadata\":{\"source\":\"web\"}}",
  "sig": "..."
}
```

### Destroy (Kind 5002)

```json
{
  "id": "g7h8i9...",
  "pubkey": "node_a_pubkey_hex",
  "created_at": 1710500600,
  "kind": 5002,
  "tags": [
    ["r", "accounts.users"],
    ["i", "550e8400-e29b-41d4-a716-446655440000"],
    ["act", "deactivate"],
    ["v", "1"],
    ["n", "node_a_pubkey_hex"],
    ["e", "d4e5f6..."],
    ["seq", "3"]
  ],
  "content": "{\"data\":{\"reason\":\"user_requested\"},\"computed\":{\"status\":\"deactivated\",\"deactivated_at\":\"2025-03-15T14:40:00Z\"},\"metadata\":{\"source\":\"admin\"}}",
  "sig": "..."
}
```

### Merge Event (Kind 5001, conflict resolution)

```json
{
  "id": "m1n2o3...",
  "pubkey": "node_b_pubkey_hex",
  "created_at": 1710500350,
  "kind": 5001,
  "tags": [
    ["r", "accounts.users"],
    ["i", "550e8400-e29b-41d4-a716-446655440000"],
    ["act", "merge"],
    ["v", "1"],
    ["n", "node_b_pubkey_hex"],
    ["e", "conflict_event_A_id"],
    ["e", "conflict_event_B_id"],
    ["f", "name,email,updated_at"],
    ["seq", "3"]
  ],
  "content": "{\"data\":{\"name\":\"Alice Smith\",\"email\":\"alice@newdomain.com\"},\"computed\":{\"updated_at\":\"2025-03-15T14:35:50Z\"},\"metadata\":{\"merge_resolution\":true}}",
  "sig": "..."
}
```

---

## Security Considerations

- **Cluster secret compromise:** If `cluster_secret` is leaked, an attacker can derive all user server keys. Rotate the secret and re-derive keys. Events signed with old keys remain verifiable (the pubkeys don't change retroactively, but the attacker could forge new events). Implementations SHOULD support secret rotation with a grace period.
- **Node key compromise:** Attacker can forge system events and events for users who don't have personal keys. Revoke the node's pubkey from the trusted set. Events previously signed by the compromised key remain in the log and may need manual review.
- **Replay of valid events:** An attacker who can publish to the relay could replay old valid events. Mitigated by event ID uniqueness — relays deduplicate by ID, and receiving nodes track processed event IDs.
- **Clock manipulation:** A compromised node could backdate `created_at` to win LWW conflicts. Mitigated by causal chain verification — even with a favourable timestamp, an event's `e` tag must reference a real parent. Implementations MAY reject events with `created_at` significantly in the past.

---

## Reserved Kind Ranges

Kinds 5003–5099 are reserved for future extensions to this protocol (e.g., schema migration events, snapshot events, cluster membership events). Implementations MUST NOT use these kinds for other purposes.

---

## References

- [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) — Basic protocol flow description
- [NIP-09](https://github.com/nostr-protocol/nips/blob/master/09.md) — Event deletion request
- [BIP-340](https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki) — Schnorr signatures for secp256k1
