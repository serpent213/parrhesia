# PROGRESS_MARMOT (ephemeral)

Marmot-specific implementation checklist for Parrhesia relay interoperability.

Spec source: `~/marmot/README.md` + MIP-00..05.

## M0 — spec lock + interoperability profile

- [ ] Freeze target profile to MIP-00..03 (mandatory)
- [ ] Keep MIP-04 and MIP-05 behind feature flags (optional)
- [ ] Document that legacy NIP-EE is superseded and no dedicated transition compatibility mode is planned
- [ ] Publish operator-facing compatibility statement in docs

## M1 — MIP-00 (credentials + keypackages)

- [x] Enforce kind `443` required tags and encoding (`encoding=base64`)
- [x] Validate `mls_protocol_version`, `mls_ciphersuite`, `mls_extensions`, `relays`, and `i` tag shape
- [x] Add efficient `#i` query/index path for KeyPackageRef lookup
- [x] Keep replaceable behavior for kind `10051` relay-list events
- [x] Add conformance tests for valid/invalid KeyPackage envelopes

## M2 — MIP-01 (group construction data expectations)

- [x] Enforce relay-side routing prerequisites for Marmot groups (`#h` query path)
- [x] Keep deterministic ordering for group-event catch-up (`created_at` + `id` tie-break)
- [x] Add guardrails for group metadata traffic volume and filter windows
- [x] Add tests for `#h` routing and ordering invariants

## M3 — MIP-02 (welcome events)

- [x] Support wrapped Welcome delivery via NIP-59 (`1059`) recipient-gated reads
- [x] Validate relay behavior for unsigned inner Welcome semantics (kind `444` envelope expectations)
- [x] Ensure durability/ack semantics support Commit-then-Welcome sequencing requirements
- [x] Add negative tests for malformed wrapped Welcome payloads

## M4 — MIP-03 (group events)

- [x] Enforce kind `445` envelope validation (`#h` tag presence/shape, base64 content shape)
- [x] Keep relay MLS-agnostic (no MLS decrypt/inspect in relay hot path)
- [x] Add configurable retention policy for kind `445` traffic
- [x] Add tests for high-volume fanout behavior and deterministic query results

## M5 — optional MIP-04 (encrypted media)

- [ ] Accept/store MIP-04 metadata-bearing events as regular Nostr events
- [ ] Add policy hooks for media metadata limits and abuse controls
- [ ] Add tests for search/filter interactions with media metadata tags

## M6 — optional MIP-05 (push notifications)

- [ ] Accept/store notification coordination events required by enabled profile
- [ ] Add policy/rate-limit controls for push-related event traffic
- [ ] Add abuse and replay protection tests for notification trigger paths

## M7 — hardening + operations

- [ ] Add Marmot-focused telemetry breakdowns (ingest/query/fanout, queue pressure)
- [ ] Add query-plan regression checks for `#h` and `#i` heavy workloads
- [ ] Add fault-injection scenarios for relay outage/reordering behavior in group flows
- [ ] Add docs for operator limits tuned for Marmot traffic patterns
- [ ] Final `mix precommit` before merge
