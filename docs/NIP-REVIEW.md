# Review of `docs/NIP-DBSYNC.md`

## 1. Scope and motivation

### Scope is too broad

This draft is trying to standardize at least five separate things at once:

1. a transport format for mutation logs,
2. a conflict-resolution algorithm,
3. a trust and key-management model,
4. relay storage/indexing expectations,
5. schema/versioning and replay semantics.

That is too much surface area for one NIP, especially for a first draft. The problem statement in the abstract already bundles all of it: “**replicating database record state across distributed nodes via Nostr relays**” and “**field-level merge resolution**” plus “**A three-tier signing model**” (`docs/NIP-DBSYNC.md:11`, `docs/NIP-DBSYNC.md:13`). A NIP should usually standardize the interoperable wire contract, not the entire replication strategy.

### Motivation is not yet convincing as a NIP motivation

The motivation section argues from deployment convenience, not from a protocol gap:

- “**Applications backed by a single database instance face a single point of failure**” (`docs/NIP-DBSYNC.md:19`)
- “**The Nostr relay mesh handles event distribution and persistence**” (`docs/NIP-DBSYNC.md:22`)
- “**New nodes can bootstrap by replaying the full event history**” (`docs/NIP-DBSYNC.md:25`)

Those are operational goals, but they do not show why a new shared Nostr standard is needed. Today, an application can already publish regular events containing mutation deltas or state snapshots on private kinds. What is still missing after existing Nostr primitives are composed? The draft does not identify a cross-implementation interoperability problem; it mostly describes one cluster’s internal replication design.

### Existing Nostr composition likely covers the transport layer

If the real goal is “signed application mutation log over relays”, that can already be built from:

- regular events for immutable mutations,
- optional addressable events for latest snapshots or heads,
- existing relay ACL / auth choices,
- application-defined content schemas.

What this draft adds beyond that is mostly database-specific replay semantics and custodial key derivation. Those are the least portable parts and the weakest candidates for standardization.

### Concrete fix

Split the work:

- **Base NIP:** immutable mutation events only.
- **Optional profile:** conflict resolution, snapshots, bootstrapping.
- **Out of scope:** custodial key derivation and app-specific operation execution.

## 2. Protocol fit

### This does not feel native to Nostr’s strengths

Nostr is very good at exchanging signed events. It is not good at providing ordered, gap-free, globally consistent transactional replication. The draft quietly assumes those properties anyway.

Examples:

- “**Full history is required for replay and recovery**” (`docs/NIP-DBSYNC.md:41`)
- “**Gaps in sequence numbers from a given node indicate missed events**” (`docs/NIP-DBSYNC.md:227`)
- “**Relay delivers all stored events (oldest first by `created_at`, tie-break by `id`)**” (`docs/NIP-DBSYNC.md:339`)

NIP-01 does not guarantee oldest-first replay, does not guarantee complete retention, and does not give you transactional gap detection. A NIP can define behavior for implementing relays, but this draft treats cluster-grade log semantics as if they are natural extensions of REQ/EVENT/EOSE. They are not.

### It introduces coordination assumptions Nostr cannot reliably provide

The biggest hidden assumptions are:

- `created_at` is a trustworthy ordering signal,
- parents arrive before children or can be recovered cheaply,
- “latest known event for a record” is coherent across nodes,
- all nodes share the same operation semantics,
- a relay can act as durable replay storage indefinitely.

Those assumptions break routinely in Nostr environments.

### Relay behavior section is too strong and too cluster-specific

“**Relays MUST store all events of these kinds**” and “**MUST support filtering by `r`, `i`, `e`, `n`, and `u` tags**” (`docs/NIP-DBSYNC.md:41`, `docs/NIP-DBSYNC.md:279`) turns a generic relay into a specialized replication service. That may be fine for a private deployment profile, but it is not a good default fit for the wider Nostr relay ecosystem.

### Deletion semantics are a protocol mismatch

“**Standard kind 5 (NIP-09 deletion requests) MAY be used to retract erroneous sync events**” (`docs/NIP-DBSYNC.md:43`) is the wrong tool. NIP-09 is advisory deletion/hiding, not a causal rollback mechanism for replicated state. Once downstream events depend on a mutation, “retracting” the earlier event does not define what replicas should do.

### Concrete fix

Reframe this as a **private relay profile** unless the draft is narrowed to a minimal event schema that works over ordinary Nostr assumptions. Remove NIP-09-based rollback entirely.

## 3. Event design

### Three kinds are unnecessary; one mutation kind is probably enough

The draft uses kinds 5000/5001/5002 for create/update/destroy, but also has an `act` tag carrying the operation name:

- “**`act` | Operation | Yes | No | Name of the operation that produced this event**” (`docs/NIP-DBSYNC.md:82`)

That duplicates semantics. If operation meaning lives in `act`, separate kinds add little value. If operation meaning lives in kind, `act` should not also be required. Right now the design is neither minimal nor crisp.

### `act` is implementation lock-in disguised as protocol

“**Receiving nodes use this to determine how to apply the mutation**” (`docs/NIP-DBSYNC.md:82`) is a red flag. A protocol should not depend on every implementation having the same executable operation names like `"update_email"` or `"soft_delete"`. That is application code, not interoperable event semantics.

A different stack, schema, or business rule engine cannot safely “apply” `update_email` just because the string matches.

### `content` is over-structured for a supposed generic NIP

The split into `data`, `computed`, and `metadata` (`docs/NIP-DBSYNC.md:91-105`) is not generic protocol design. It reflects one event-sourced database replay strategy.

Specific concerns:

- `computed` says receivers “**MUST be force-applied to reproduce exact state**” (`docs/NIP-DBSYNC.md:104`). That overrides local invariants and assumes homogeneous schemas.
- `metadata` is “**Freeform**” (`docs/NIP-DBSYNC.md:105`), which means two implementations can both “support the NIP” and still be unable to replay each other’s events if behavior leaks into metadata.
- “**Fields marked as sensitive or secret ... MUST be excluded ... unless** ... encrypted” (`docs/NIP-DBSYNC.md:126`) conflicts with the replay story. If important fields are omitted, replay is incomplete. If they are included, encryption stops being optional in practice.

### Tag choices are awkward and sometimes misleading

- `r` for resource, `i` for record ID, `u` for acting user, `n` for node are internally consistent, but they create a protocol whose meaning depends on a private application namespace. “**Format is implementation-defined**” for `r` (`docs/NIP-DBSYNC.md:75`) undermines interoperability immediately.
- `f` as “**Comma-separated list of column/attribute names**” (`docs/NIP-DBSYNC.md:78`) is ad-hoc packing. Use repeated tags or multi-value tags, not CSV inside a tag value.
- `i` for composite keys as “**a deterministic JSON array**” string (`docs/NIP-DBSYNC.md:76`) does not specify canonicalization.

### `seq` semantics are internally inconsistent

The spec says `seq` is “**per record per originating node**” (`docs/NIP-DBSYNC.md:83`, `docs/NIP-DBSYNC.md:227`), but the examples show a create from node A with `seq: 1` and then an update from node B with `seq: 2` (`docs/NIP-DBSYNC.md:374-376`, `docs/NIP-DBSYNC.md:396-400`). That contradicts the definition.

### Merge design is underspecified and brittle

The merge rule says the resolver emits “**a new update event (kind 5001) with `e` tags referencing BOTH conflicting events**” (`docs/NIP-DBSYNC.md:244`). Problems:

- conflict is defined only for sibling events sharing a parent (`docs/NIP-DBSYNC.md:237`), not longer divergent branches;
- multi-parent merge events are introduced, but later “latest known event for that record” logic still reads like a single-head chain;
- merge semantics are application-specific, yet the draft treats them as protocol-level authority.

### Concrete fix

Use one regular kind for immutable mutations and make `content` either:

- a generic application-defined delta, or
- a fully materialized post-state object.

Do not standardize both `data` and `computed` in the base NIP. Move merge rules to an implementation profile.

## 4. Interoperability and ecosystem impact

### Non-implementing relays and clients degrade badly

A relay that does not agree to full retention or arbitrary single-letter tag indexing is effectively unusable here. A client that does not implement this NIP sees opaque events, which is acceptable, but a relay that only partially implements it breaks replication correctness.

That means this is not merely “optional application semantics”; it is a specialized relay/storage contract.

### The draft has undeclared dependencies on local application knowledge

Several parts require data that is not actually in the event:

- trust verification of user-server keys requires `user_id`, but the event only defines `u` as “**acting user pubkey hex**” (`docs/NIP-DBSYNC.md:81`)
- the verifier is told to derive the expected pubkey from “**`cluster_secret` + user ID (looked up via the `u` tag or record context)**” (`docs/NIP-DBSYNC.md:197`)

That is not interoperable. A remote implementation cannot reconstruct trust from the event alone.

### It is not implementation-agnostic

The resource examples already leak implementation details:

- `"accounts.users"`
- `"MyApp.Accounts.User"`
- `"public.orders"`

from `docs/NIP-DBSYNC.md:75`.

The `act` tag also assumes shared executable operation names. The whole design reads like “replicate one service’s ORM mutations” rather than “interoperate across different Nostr apps”.

### Too domain-specific for the NIP registry in current form

As drafted, this is a database mutation replication profile for cooperating cluster nodes, not a broadly reusable Nostr primitive. A standard NIP should define something others can adopt without inheriting one stack’s replication model.

### Concrete fix

If standardization is desired, retarget the NIP to a more general primitive such as:

- signed state-delta events,
- signed per-object snapshots,
- signed conflict annotations / ancestry references.

Leave database table names, ORM operations, and replay internals out.

## 5. Security and abuse surface

### Authorization model is incomplete

“**Receiving nodes MUST verify that the event's `pubkey` is trusted before applying it**” (`docs/NIP-DBSYNC.md:194`) is not enough. Trusted to do what?

The draft lacks per-resource or per-operation authorization. If a node key is trusted at all, can it mutate every table? Can any derived user-server key mutate any record for that user? What prevents a valid signer from publishing semantically invalid state transitions?

### Deterministic custodial key derivation is a major liability

“**Each user has a server-side keypair derived deterministically from a shared cluster secret**” (`docs/NIP-DBSYNC.md:160`) means every node that can replicate can derive every custodial user key. That is an operational shortcut, not a good base protocol.

More problems:

- the spec uses HMAC output “**directly as the secp256k1 private key**” (`docs/NIP-DBSYNC.md:170`) without defining invalid-key handling;
- secret rotation is not actually specified, but future verification depends on it;
- compromise of one cluster secret compromises the entire custodial identity layer.

### Replay and conflict abuse are understated

“**Replay of valid events**” is said to be mitigated by “**event ID uniqueness**” (`docs/NIP-DBSYNC.md:459`). That only deduplicates exact same events. It does not address:

- replay across relays and reconnects,
- adversarial reordering,
- conflict flooding with many validly signed branches,
- resource exhaustion from buffering children while waiting for parents.

### `created_at`-based LWW is easy to game

The draft resolves overlapping updates by higher `created_at` (`docs/NIP-DBSYNC.md:243`). A compromised or buggy node can simply lie about time. The draft’s mitigation claim — “**causal chain verification**” (`docs/NIP-DBSYNC.md:460`) — does not solve that. Two siblings with the same parent can still use fake timestamps to win.

### Relay DoS risks are significant

The relay/storage contract invites unbounded growth:

- permanent retention,
- full-history replay,
- broad subscriptions with no author filter,
- parent-missing buffering,
- conflict merge amplification.

The “live sync” example subscribes to all three kinds with no authors, no resources, no trusted-key filter (`docs/NIP-DBSYNC.md:290-294`). That is a gift to event flooding unless the deployment is tightly closed.

### Concrete fix

- Remove custodial derivation from the base NIP.
- Require explicit signer allowlists or signed capability documents if auth is in scope.
- Treat conflict resolution as local policy, not network truth.
- Require narrow subscription filters in examples.

## 6. Long-term evolution

### Versioning path is weak

The `v` tag only versions “**the event's content structure**” (`docs/NIP-DBSYNC.md:349`), but many breaking changes would hit tag semantics, trust rules, conflict policy, and replay rules too. A single integer on the event is not enough governance for the full protocol surface being claimed.

### The draft over-specifies internals and under-specifies critical edges

It over-specifies:

- `data` vs `computed`,
- deterministic key derivation,
- field-level merge strategy,
- full-replay expectations.

It under-specifies:

- invalid/rotated derived keys,
- authorization scope,
- parent lookup behavior,
- how to recover from missing history,
- how to handle partial relay retention,
- how to migrate resource identifiers.

That is the worst combination for long-term evolution: too much locked down, too many dangerous gaps.

### Network-topology assumptions will age badly

The draft assumes a stable cluster of mutually trusting nodes sharing one secret and one resource namespace. That may work for one deployment, but it will age poorly as soon as:

- multiple organizations interoperate,
- relays are semi-public or policy-diverse,
- mobile/offline publishers appear,
- snapshots become necessary because full replay is too expensive.

### Concrete fix

Define an extension path now:

- base mutation event;
- optional snapshot/head events;
- optional auth profile;
- optional merge/conflict profile.

Do not bundle them into a single mandatory behavior set.

## 7. Micro issues

- “**Eventual consistency with per-field last-write-wins conflict resolution.**” is a sentence fragment and should be rewritten (`docs/NIP-DBSYNC.md:27`).
- “**NIP-01 guarantees single-letter tag indexing**” is too strong; NIP-01 describes a convention, not a universal guarantee (`docs/NIP-DBSYNC.md:71`).
- “**The `content` field contains a JSON object**” is technically wrong; `content` is a string containing JSON-encoded text (`docs/NIP-DBSYNC.md:91`).
- `r` is said to be “**implementation-defined**” yet also “**MUST be unique within the cluster**”; that scopes uniqueness only to one cluster, not to interoperable consumers (`docs/NIP-DBSYNC.md:75`).
- Composite `i` values use a “**deterministic JSON array**” string but no canonicalization is defined (`docs/NIP-DBSYNC.md:76`).
- `f` as “**Comma-separated**” field names is an unnecessary custom encoding (`docs/NIP-DBSYNC.md:78`).
- “**Used for echo suppression — a node discards events where the `n` tag matches its own pubkey**” assumes `n` is trustworthy before trust evaluation order is stated (`docs/NIP-DBSYNC.md:80`).
- “**Receiving nodes use this to determine how to apply the mutation**” leaves operation semantics undefined and stack-specific (`docs/NIP-DBSYNC.md:82`).
- The binary encoding convention `{"__binary__": "<base64>"}` reserves a magic object shape without escape rules or collision handling (`docs/NIP-DBSYNC.md:138`).
- “**initial implementation**” is not NIP language; specs should not speak from one implementation’s release plan (`docs/NIP-DBSYNC.md:188`).
- “**looked up via the `u` tag or record context**” is undefined; `u` does not carry `user_id`, and “record context” is not a protocol concept (`docs/NIP-DBSYNC.md:197`).
- The conflict definition only covers same-parent siblings and misses deeper branch divergence (`docs/NIP-DBSYNC.md:237`).
- The tie-break rule borrows replaceable-event wording — “**consistent with NIP-01 replaceable event semantics**” — but these are regular events, so the analogy is weak and not obviously appropriate (`docs/NIP-DBSYNC.md:243`).
- “**authoritative resolution**” for merge events conflicts with the earlier statement that conflict resolution is application-level (`docs/NIP-DBSYNC.md:233`, `docs/NIP-DBSYNC.md:264`).
- “**Relay delivers all stored events (oldest first by `created_at`, tie-break by `id`)**” specifies behavior not grounded in NIP-01 relay semantics (`docs/NIP-DBSYNC.md:339`).
- The examples are not wire-valid Nostr examples because fields like `id`, `pubkey`, and `sig` use placeholders such as `"a1b2c3..."` and `"node_a_pubkey_hex"` instead of valid lowercase hex (`docs/NIP-DBSYNC.md:365-379`, `docs/NIP-DBSYNC.md:387-403`).
- The destroy example is semantically inconsistent: kind 5002 is “destroy” but the example `act` is `"deactivate"`, which sounds like soft delete/state transition, not deletion (`docs/NIP-DBSYNC.md:407-425`).
- The `seq` example contradicts the stated “per record per originating node” rule (`docs/NIP-DBSYNC.md:227`, `docs/NIP-DBSYNC.md:374-376`, `docs/NIP-DBSYNC.md:396-400`).
- “**Rotate the secret and re-derive keys**” is incomplete because no key epoch/version is carried in events, so verifiers cannot know which secret version to use (`docs/NIP-DBSYNC.md:457`).
- “**the pubkeys don't change retroactively**” is muddled wording; future derived pubkeys do change after rotation unless the derivation input is versioned separately (`docs/NIP-DBSYNC.md:457`).
- “**event ID uniqueness**” is not a sufficient replay defense (`docs/NIP-DBSYNC.md:459`).
- “**Kinds 5003–5099 are reserved**” overreaches; a draft should not unilaterally reserve a broad global kind range unless the community has agreed to it (`docs/NIP-DBSYNC.md:466`).

### Borrowed conventions that need adaptation to Nostr

- The per-field LWW merge model reads like database/CRDT literature, but Nostr does not provide the causal metadata needed to make that portable or trustworthy.
- The “operation name” approach feels closer to RPC/event-sourcing inside one service than to Nostr event interoperability.
- The deterministic cluster-wide custodial key derivation looks like an infrastructure shortcut from a single deployment architecture, not a Nostr-native identity model.

## 8. Verdict and recommendations

### Top 3 issues to resolve first

1. **The scope is too broad.** The draft mixes wire format, replay engine, auth model, and conflict semantics.
2. **The trust model is not interoperable.** User-server key verification depends on out-of-band `user_id` and a shared secret.
3. **The protocol assumes relay/storage/order guarantees that ordinary Nostr infrastructure does not provide.**

### Recommended structural alternatives

#### Option A: Narrow to a transport primitive

Define a single regular event kind for immutable application mutations:

- required tags: object namespace, object id, optional parent event id;
- content: application-defined JSON string;
- no standard merge algorithm;
- no standard key derivation.

This is the most Nostr-native option.

#### Option B: Add snapshots, not replay mandates

If bootstrap matters, add an optional addressable snapshot/head event profile:

- regular mutation log for history;
- addressable snapshot per object or per resource;
- new nodes bootstrap from snapshot + tail, not full replay.

This fits Nostr much better than requiring permanent full history everywhere.

#### Option C: Keep this as an implementation profile, not a NIP

If the goal is specifically “database replication for cooperating nodes in one cluster”, publish it as implementation documentation or a project-specific profile. In current form it is too opinionated and stack-shaped for a general NIP.

### Overall readiness

**Needs major revision**.

The current draft is not ready for wider Nostr community review as a standards-track NIP. It first needs to be narrowed to a small interoperable core and stripped of implementation-specific replication and key-management assumptions.
