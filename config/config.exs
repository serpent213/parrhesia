import Config

config :parrhesia,
  limits: [
    max_frame_bytes: 1_048_576,
    max_event_bytes: 262_144,
    max_filters_per_req: 16,
    max_filter_limit: 500,
    max_subscriptions_per_connection: 32,
    max_event_future_skew_seconds: 900,
    max_outbound_queue: 256,
    outbound_drain_batch_size: 64,
    outbound_overflow_strategy: :close
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
    management_auth_required: true
  ],
  features: [
    nip_45_count: true,
    nip_50_search: true,
    nip_77_negentropy: true,
    nip_ee_mls: false
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
