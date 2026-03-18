import Config

config :postgrex, :json_library, JSON

config :parrhesia,
  moderation_cache_enabled: true,
  relay_url: "ws://localhost:4413/relay",
  nip43: [
    enabled: true,
    invite_ttl_seconds: 900,
    request_max_age_seconds: 300
  ],
  nip66: [
    enabled: true,
    publish_interval_seconds: 900,
    publish_monitor_announcement?: true,
    timeout_ms: 5_000,
    checks: [:open, :read, :nip11],
    targets: []
  ],
  identity: [
    path: nil,
    private_key: nil
  ],
  sync: [
    path: nil,
    start_workers?: true
  ],
  limits: [
    max_frame_bytes: 1_048_576,
    max_event_bytes: 262_144,
    max_filters_per_req: 16,
    max_filter_limit: 500,
    max_tags_per_event: 256,
    max_tag_values_per_filter: 128,
    relay_max_event_ingest_per_window: 10_000,
    relay_event_ingest_window_seconds: 1,
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
    max_negentropy_items_per_session: 50_000,
    negentropy_id_list_threshold: 32,
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
  listeners: %{
    public: %{
      enabled: true,
      bind: %{ip: {0, 0, 0, 0}, port: 4413},
      max_connections: 20_000,
      transport: %{scheme: :http, tls: %{mode: :disabled}},
      proxy: %{trusted_cidrs: [], honor_x_forwarded_for: true},
      network: %{allow_all: true},
      features: %{
        nostr: %{enabled: true},
        admin: %{enabled: true},
        metrics: %{
          enabled: true,
          access: %{private_networks_only: true},
          auth_token: nil
        }
      },
      auth: %{nip42_required: false, nip98_required_for_admin: true},
      baseline_acl: %{read: [], write: []}
    }
  },
  retention: [
    check_interval_hours: 24,
    months_ahead: 2,
    max_db_bytes: :infinity,
    max_months_to_keep: :infinity,
    max_partitions_to_drop_per_run: 1
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

config :parrhesia, Parrhesia.Repo, types: Parrhesia.PostgresTypes

config :parrhesia, ecto_repos: [Parrhesia.Repo]

import_config "#{config_env()}.exs"
