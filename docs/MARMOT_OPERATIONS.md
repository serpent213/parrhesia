# Marmot operations guide (relay operator tuning)

This document captures practical limits and operational defaults for Marmot-heavy traffic (`443`, `445`, `10051`, wrapped `1059`, optional media/push flows).

## 1) Recommended baseline limits

Use these as a starting point and tune from production telemetry.

```elixir
config :parrhesia,
  limits: [
    max_filter_limit: 500,
    max_filters_per_req: 16,
    max_outbound_queue: 256,
    outbound_drain_batch_size: 64
  ],
  policies: [
    # Marmot group routing/query guards
    marmot_require_h_for_group_queries: true,
    marmot_group_max_h_values_per_filter: 32,
    marmot_group_max_query_window_seconds: 2_592_000,

    # Kind 445 retention
    mls_group_event_ttl_seconds: 300,

    # MIP-04 metadata controls
    marmot_media_max_imeta_tags_per_event: 8,
    marmot_media_max_field_value_bytes: 1024,
    marmot_media_max_url_bytes: 2048,
    marmot_media_allowed_mime_prefixes: [],
    marmot_media_reject_mip04_v1: true,

    # MIP-05 push controls (optional)
    marmot_push_server_pubkeys: [],
    marmot_push_max_relay_tags: 16,
    marmot_push_max_payload_bytes: 65_536,
    marmot_push_max_trigger_age_seconds: 120,
    marmot_push_require_expiration: true,
    marmot_push_max_expiration_window_seconds: 120,
    marmot_push_max_server_recipients: 1
  ]
```

## 2) Index expectations for Marmot workloads

The Postgres adapter relies on dedicated partial tag indexes for hot Marmot selectors:

- `event_tags_h_value_created_at_idx` for `#h` group routing
- `event_tags_i_value_created_at_idx` for `#i` keypackage reference lookups

Query-plan regression tests assert these paths remain usable for heavy workloads.

## 3) Telemetry to watch

Key metrics for Marmot traffic and pressure:

- `parrhesia.ingest.duration.ms{traffic_class="marmot|generic"}`
- `parrhesia.query.duration.ms{traffic_class="marmot|generic"}`
- `parrhesia.fanout.duration.ms{traffic_class="marmot|generic"}`
- `parrhesia.connection.outbound_queue.depth{traffic_class=...}`
- `parrhesia.connection.outbound_queue.pressure{traffic_class=...}`
- `parrhesia.connection.outbound_queue.pressure_events.count{traffic_class=...}`
- `parrhesia.connection.outbound_queue.overflow.count{traffic_class=...}`

Operational target: keep queue pressure below sustained 0.75 and avoid overflow spikes during `445` bursts.

## 4) Fault and recovery expectations

During storage outages, Marmot group-flow writes must fail with explicit `OK false` errors. After recovery, reordered group events should still query deterministically by `created_at DESC, id ASC`.
