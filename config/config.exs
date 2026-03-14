import Config

config :postgrex, :json_library, JSON

config :parrhesia,
  moderation_cache_enabled: true,
  relay_url: "ws://localhost:4000/relay",
  limits: [
    max_frame_bytes: 1_048_576,
    max_event_bytes: 262_144,
    max_filters_per_req: 16,
    max_filter_limit: 500,
    max_subscriptions_per_connection: 32,
    max_event_future_skew_seconds: 900,
    max_event_ingest_per_window: 120,
    event_ingest_window_seconds: 1,
    auth_max_age_seconds: 600,
    max_outbound_queue: 256,
    outbound_drain_batch_size: 64,
    outbound_overflow_strategy: :close,
    max_negentropy_payload_bytes: 4096,
    max_negentropy_sessions_per_connection: 8,
    max_negentropy_total_sessions: 10_000,
    negentropy_session_idle_timeout_seconds: 60,
    negentropy_session_sweep_interval_seconds: 10
  ],
  policies: [
    auth_required_for_writes: false,
    auth_required_for_reads: false,
    min_pow_difficulty: 0,
    accept_ephemeral_events: true,
    mls_group_event_ttl_seconds: 300,
    marmot_require_h_for_group_queries: true,
    marmot_group_max_h_values_per_filter: 32,
    marmot_group_max_query_window_seconds: 2_592_000,
    marmot_media_max_imeta_tags_per_event: 8,
    marmot_media_max_field_value_bytes: 1024,
    marmot_media_max_url_bytes: 2048,
    marmot_media_allowed_mime_prefixes: [],
    marmot_media_reject_mip04_v1: true,
    marmot_push_server_pubkeys: [],
    marmot_push_max_relay_tags: 16,
    marmot_push_max_payload_bytes: 65_536,
    marmot_push_max_trigger_age_seconds: 120,
    marmot_push_require_expiration: true,
    marmot_push_max_expiration_window_seconds: 120,
    marmot_push_max_server_recipients: 1,
    management_auth_required: true
  ],
  features: [
    verify_event_signatures: true,
    nip_45_count: true,
    nip_50_search: true,
    nip_77_negentropy: true,
    marmot_push_notifications: false
  ],
  storage: [
    events: Parrhesia.Storage.Adapters.Postgres.Events,
    moderation: Parrhesia.Storage.Adapters.Postgres.Moderation,
    groups: Parrhesia.Storage.Adapters.Postgres.Groups,
    admin: Parrhesia.Storage.Adapters.Postgres.Admin
  ]

config :parrhesia, Parrhesia.Web.Endpoint, port: 4000

config :parrhesia, ecto_repos: [Parrhesia.Repo]

import_config "#{config_env()}.exs"
