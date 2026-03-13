import Config

config :parrhesia,
  limits: [
    max_frame_bytes: 1_048_576,
    max_event_bytes: 262_144,
    max_filters_per_req: 16,
    max_subscriptions_per_connection: 32,
    max_event_future_skew_seconds: 900
  ],
  policies: [
    auth_required_for_writes: false,
    auth_required_for_reads: false,
    min_pow_difficulty: 0,
    accept_ephemeral_events: true
  ],
  features: [
    nip_45_count: true,
    nip_50_search: false,
    nip_77_negentropy: false,
    nip_ee_mls: false
  ],
  storage: [
    events: Parrhesia.Storage.Adapters.Postgres.Events,
    moderation: Parrhesia.Storage.Adapters.Postgres.Moderation,
    groups: Parrhesia.Storage.Adapters.Postgres.Groups,
    admin: Parrhesia.Storage.Adapters.Postgres.Admin
  ]

config :parrhesia, Parrhesia.Web.Endpoint, port: 4000

import_config "#{config_env()}.exs"
