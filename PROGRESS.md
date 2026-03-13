# PROGRESS (ephemeral)

Implementation checklist for Parrhesia relay.

## Phase 0 — foundation

- [x] Confirm architecture doc with final NIP scope (`docs/ARCH.md`)
- [x] Add core deps (websocket/http server, ecto_sql/postgrex, telemetry, test tooling)
- [x] Establish application config structure (limits, policies, feature flags)
- [x] Wire initial supervision tree skeleton

## Phase 1 — protocol core (NIP-01)

- [ ] Implement websocket endpoint + per-connection process
- [ ] Implement message decode/encode for `EVENT`, `REQ`, `CLOSE`
- [ ] Implement strict event validation (`id`, `sig`, shape, timestamps)
- [ ] Implement filter evaluation engine (AND/OR semantics)
- [ ] Implement subscription lifecycle + `EOSE` behavior
- [ ] Implement canonical `OK`, `NOTICE`, `CLOSED` responses + prefixes

## Phase 2 — storage boundary + postgres adapter

- [ ] Define `Parrhesia.Storage.*` behaviors (events/moderation/groups/admin)
- [ ] Implement Postgres adapter modules behind behaviors
- [ ] Create migrations for events, tags, moderation, membership
- [ ] Implement replaceable/addressable semantics at storage layer
- [ ] Add adapter contract test suite

## Phase 3 — fanout + performance primitives

- [ ] Build ETS-backed subscription index
- [ ] Implement candidate narrowing by kind/author/tag
- [ ] Add bounded outbound queues/backpressure per connection
- [ ] Add telemetry for ingest/query/fanout latency + queue depth

## Phase 4 — relay metadata and auth

- [ ] NIP-11 endpoint (`application/nostr+json`)
- [ ] NIP-42 challenge/auth flow
- [ ] Enforce NIP-70 protected events (default reject, auth override)
- [ ] Add auth-required/restricted response paths for writes and reqs

## Phase 5 — lifecycle and moderation features

- [ ] NIP-09 deletion requests
- [ ] NIP-40 expiration handling + purge worker
- [ ] NIP-62 vanish requests (hard delete semantics)
- [ ] NIP-13 PoW gate (configurable minimum)
- [ ] Moderation tables + policy hooks (ban/allow/event/ip)

## Phase 6 — query extensions

- [ ] NIP-45 `COUNT` (exact)
- [ ] Optional HLL response support
- [ ] NIP-50 search (`search` filter + ranking)
- [ ] NIP-77 negentropy (`NEG-OPEN/MSG/CLOSE`)

## Phase 7 — private messaging, groups, and MLS

- [ ] NIP-17/59 recipient-protected giftwrap read path (`kind:1059`)
- [ ] NIP-29 group event policy + relay metadata events
- [ ] NIP-43 membership request flow (`28934/28935/28936`, `8000/8001`, `13534`)
- [ ] NIP-EE (feature-flagged): `443`, `445`, `10051` handling
- [ ] MLS retention policy + tests for commit race edge cases

## Phase 8 — management API + operations

- [ ] NIP-86 HTTP management endpoint
- [ ] NIP-98 auth validation for management calls
- [ ] Implement supported management methods + audit logging
- [ ] Build health/readiness and Prometheus-compatible `/metrics` endpoints

## Phase 9 — full test + hardening pass

- [ ] Unit + integration + property test coverage for all critical modules
- [ ] End-to-end websocket conformance scenarios
- [ ] Load/soak tests with target p95 latency budgets
- [ ] Fault-injection tests (DB outages, high churn, restart recovery)
- [ ] Final precommit run and fix all issues

## Nice-to-have / backlog

- [ ] Multi-node fanout via PG LISTEN/NOTIFY or external bus
- [ ] Partitioned event storage + archival strategy
- [ ] Alternate storage adapter prototype (non-Postgres)
- [ ] Compatibility mode for Marmot protocol transition
