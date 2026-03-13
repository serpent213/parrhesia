# PROGRESS (ephemeral)

Implementation checklist for Parrhesia relay.

## Phase 0 — foundation

- [x] Confirm architecture doc with final NIP scope (`docs/ARCH.md`)
- [x] Add core deps (websocket/http server, ecto_sql/postgrex, telemetry, test tooling)
- [x] Establish application config structure (limits, policies, feature flags)
- [x] Wire initial supervision tree skeleton

## Phase 1 — protocol core (NIP-01)

- [x] Implement websocket endpoint + per-connection process
- [x] Implement message decode/encode for `EVENT`, `REQ`, `CLOSE`
- [x] Implement strict event validation (`id`, `sig`, shape, timestamps)
- [x] Implement filter evaluation engine (AND/OR semantics)
- [x] Implement subscription lifecycle + `EOSE` behavior
- [x] Implement canonical `OK`, `NOTICE`, `CLOSED` responses + prefixes

## Phase 2 — storage boundary + postgres adapter

- [x] Define `Parrhesia.Storage.*` behaviors (events/moderation/groups/admin)
- [x] Implement Postgres adapter modules behind behaviors
- [x] Create migrations for events, tags, moderation, membership
- [x] Implement replaceable/addressable semantics at storage layer
- [x] Add adapter contract test suite

## Phase 3 — fanout + performance primitives

- [x] Build ETS-backed subscription index
- [x] Implement candidate narrowing by kind/author/tag
- [x] Add bounded outbound queues/backpressure per connection
- [x] Add telemetry for ingest/query/fanout latency + queue depth

## Phase 4 — relay metadata and auth

- [x] NIP-11 endpoint (`application/nostr+json`)
- [x] NIP-42 challenge/auth flow
- [x] Enforce NIP-70 protected events (default reject, auth override)
- [x] Add auth-required/restricted response paths for writes and reqs

## Phase 5 — lifecycle and moderation features

- [x] NIP-09 deletion requests
- [x] NIP-40 expiration handling + purge worker
- [x] NIP-62 vanish requests (hard delete semantics)
- [x] NIP-13 PoW gate (configurable minimum)
- [x] Moderation tables + policy hooks (ban/allow/event/ip)

## Phase 6 — query extensions

- [x] NIP-45 `COUNT` (exact)
- [x] Optional HLL response support
- [x] NIP-50 search (`search` filter + ranking)
- [x] NIP-77 negentropy (`NEG-OPEN/MSG/CLOSE`)

## Phase 7 — private messaging, groups, and MLS

- [x] NIP-17/59 recipient-protected giftwrap read path (`kind:1059`)
- [x] NIP-29 group event policy + relay metadata events
- [x] NIP-43 membership request flow (`28934/28935/28936`, `8000/8001`, `13534`)
- [x] NIP-EE (feature-flagged): `443`, `445`, `10051` handling
- [x] MLS retention policy + tests for commit race edge cases

## Phase 8 — management API + operations

- [x] NIP-86 HTTP management endpoint
- [x] NIP-98 auth validation for management calls
- [x] Implement supported management methods + audit logging
- [x] Build health/readiness and Prometheus-compatible `/metrics` endpoints

## Phase 9 — full test + hardening pass

- [x] Unit + integration + property test coverage for all critical modules
- [x] End-to-end websocket conformance scenarios
- [x] Load/soak tests with target p95 latency budgets
- [x] Fault-injection tests (DB outages, high churn, restart recovery)
- [x] Final precommit run and fix all issues

## Nice-to-have / backlog

- [x] Multi-node fanout via PG LISTEN/NOTIFY or external bus
- [x] Partitioned event storage + archival strategy
- [x] Alternate storage adapter prototype (non-Postgres)
- [x] Compatibility mode for Marmot protocol transition (not required per user)
