# Khatru-Inspired Runtime Improvements

This document collects refactoring and extension ideas learned from studying Khatru-style relay design.

It is intentionally **not** about the new public API surface or the sync ACL model. Those live in `docs/slop/LOCAL_API.md` and `docs/SYNC.md`.

The focus here is runtime shape, protocol behavior, and operator-visible relay features.

---

## 1. Why This Matters

Khatru appears mature mainly because it exposes clearer relay pipeline stages.

That gives three practical benefits:

- less policy drift between storage, websocket, and management code,
- easier feature addition without hard-coding more branches into one connection module,
- better composability for relay profiles with different trust and traffic models.

Parrhesia should borrow that clarity without copying Khatru's code-first hook model wholesale.

---

## 2. Proposed Runtime Refactors

### 2.1 Staged policy pipeline

Parrhesia should stop treating policy as one coarse `EventPolicy` module plus scattered special cases.

Recommended internal stages:

1. connection admission
2. authentication challenge and validation
3. publish/write authorization
4. query/count authorization
5. stream subscription authorization
6. negentropy authorization
7. response shaping
8. broadcast/fanout suppression

This is an internal runtime refactor. It does not imply a new public API.

### 2.2 Richer internal request context

The runtime should carry a structured request context through all stages.

Useful fields:

- authenticated pubkeys
- caller kind
- remote IP
- subscription id
- peer id
- negentropy session flag
- internal-call flag

This reduces ad-hoc branching and makes audit/telemetry more coherent.

### 2.3 Separate policy from storage presence tables

Moderation state should remain data.

Runtime enforcement should be a first-class layer that consumes that data, not a side effect of whether a table exists.

This is especially important for:

- blocked IP enforcement,
- pubkey allowlists,
- future kind- or tag-scoped restrictions.

---

## 3. Protocol and Relay Features

### 3.1 Real COUNT sketches

Parrhesia currently returns a synthetic `hll` payload for NIP-45-style count responses.

If approximate count exchange matters, implement a real reusable HLL sketch path instead of hashing `filters + count`.

### 3.2 Relay identity in NIP-11

Once Parrhesia owns a stable server identity, NIP-11 should expose the relay pubkey instead of returning `nil`.

This is useful beyond sync:

- operator visibility,
- relay fingerprinting,
- future trust tooling.

### 3.3 Connection-level IP enforcement

Blocked IP support should be enforced on actual connection admission, not only stored in management tables.

This should happen early, before expensive protocol handling.

### 3.4 Better response shaping

Introduce a narrow internal response shaping layer for cases where returned events or counts need controlled rewriting or suppression.

Examples:

- hide fields for specific relay profiles,
- suppress rebroadcast of locally-ingested remote sync traffic,
- shape relay notices consistently.

This should stay narrow and deterministic. It should not become arbitrary app semantics.

---

## 4. Suggested Extension Points

These should be internal runtime seams, not necessarily public interfaces:

- `ConnectionPolicy`
- `AuthPolicy`
- `ReadPolicy`
- `WritePolicy`
- `NegentropyPolicy`
- `ResponsePolicy`
- `BroadcastPolicy`

They may initially be plain modules with well-defined callbacks or functions.

The point is not pluggability for its own sake. The point is to make policy stages explicit and testable.

---

## 5. Near-Term Priority

Recommended order:

1. enforce blocked IPs and any future connection-gating on the real connection path
2. split the current websocket flow into explicit read/write/negentropy policy stages
3. enrich runtime request context and telemetry metadata
4. expose relay pubkey in NIP-11 once identity lands
5. replace fake HLL payloads with a real approximate-count implementation if NIP-45 support matters operationally

This keeps the runtime improvements incremental and independent from the ongoing API and ACL implementation.
