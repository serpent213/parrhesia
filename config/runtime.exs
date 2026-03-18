import Config

string_env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    "" -> default
    value -> value
  end
end

int_env = fn name, default ->
  case System.get_env(name) do
    nil -> default
    value -> String.to_integer(value)
  end
end

bool_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    value ->
      case String.downcase(value) do
        "1" -> true
        "true" -> true
        "yes" -> true
        "on" -> true
        "0" -> false
        "false" -> false
        "no" -> false
        "off" -> false
        _other -> raise "environment variable #{name} must be a boolean value"
      end
  end
end

csv_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    value ->
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end
end

json_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    "" ->
      default

    value ->
      case JSON.decode(value) do
        {:ok, decoded} ->
          decoded

        {:error, reason} ->
          raise "environment variable #{name} must contain valid JSON: #{inspect(reason)}"
      end
  end
end

infinity_or_int_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    value ->
      normalized = value |> String.trim() |> String.downcase()

      if normalized == "infinity" do
        :infinity
      else
        String.to_integer(value)
      end
  end
end

outbound_overflow_strategy_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    "close" ->
      :close

    "drop_oldest" ->
      :drop_oldest

    "drop_newest" ->
      :drop_newest

    _other ->
      raise "environment variable #{name} must be one of: close, drop_oldest, drop_newest"
  end
end

ipv4_env = fn name, default ->
  case System.get_env(name) do
    nil ->
      default

    value ->
      case String.split(value, ".", parts: 4) do
        [a, b, c, d] ->
          octets = Enum.map([a, b, c, d], &String.to_integer/1)

          if Enum.all?(octets, &(&1 >= 0 and &1 <= 255)) do
            List.to_tuple(octets)
          else
            raise "environment variable #{name} must be a valid IPv4 address"
          end

        _other ->
          raise "environment variable #{name} must be a valid IPv4 address"
      end
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing. Example: ecto://USER:PASS@HOST/DATABASE"

  repo_defaults = Application.get_env(:parrhesia, Parrhesia.Repo, [])
  read_repo_defaults = Application.get_env(:parrhesia, Parrhesia.ReadRepo, [])
  relay_url_default = Application.get_env(:parrhesia, :relay_url)

  moderation_cache_enabled_default =
    Application.get_env(:parrhesia, :moderation_cache_enabled, true)

  enable_expiration_worker_default =
    Application.get_env(:parrhesia, :enable_expiration_worker, true)

  limits_defaults = Application.get_env(:parrhesia, :limits, [])
  policies_defaults = Application.get_env(:parrhesia, :policies, [])
  listeners_defaults = Application.get_env(:parrhesia, :listeners, %{})
  retention_defaults = Application.get_env(:parrhesia, :retention, [])
  features_defaults = Application.get_env(:parrhesia, :features, [])
  acl_defaults = Application.get_env(:parrhesia, :acl, [])

  default_pool_size = Keyword.get(repo_defaults, :pool_size, 32)
  default_queue_target = Keyword.get(repo_defaults, :queue_target, 1_000)
  default_queue_interval = Keyword.get(repo_defaults, :queue_interval, 5_000)
  default_read_pool_size = Keyword.get(read_repo_defaults, :pool_size, default_pool_size)
  default_read_queue_target = Keyword.get(read_repo_defaults, :queue_target, default_queue_target)

  default_read_queue_interval =
    Keyword.get(read_repo_defaults, :queue_interval, default_queue_interval)

  pool_size = int_env.("POOL_SIZE", default_pool_size)
  queue_target = int_env.("DB_QUEUE_TARGET_MS", default_queue_target)
  queue_interval = int_env.("DB_QUEUE_INTERVAL_MS", default_queue_interval)
  read_pool_size = int_env.("DB_READ_POOL_SIZE", default_read_pool_size)
  read_queue_target = int_env.("DB_READ_QUEUE_TARGET_MS", default_read_queue_target)
  read_queue_interval = int_env.("DB_READ_QUEUE_INTERVAL_MS", default_read_queue_interval)

  limits = [
    max_frame_bytes:
      int_env.(
        "PARRHESIA_LIMITS_MAX_FRAME_BYTES",
        Keyword.get(limits_defaults, :max_frame_bytes, 1_048_576)
      ),
    max_event_bytes:
      int_env.(
        "PARRHESIA_LIMITS_MAX_EVENT_BYTES",
        Keyword.get(limits_defaults, :max_event_bytes, 262_144)
      ),
    max_filters_per_req:
      int_env.(
        "PARRHESIA_LIMITS_MAX_FILTERS_PER_REQ",
        Keyword.get(limits_defaults, :max_filters_per_req, 16)
      ),
    max_filter_limit:
      int_env.(
        "PARRHESIA_LIMITS_MAX_FILTER_LIMIT",
        Keyword.get(limits_defaults, :max_filter_limit, 500)
      ),
    max_tags_per_event:
      int_env.(
        "PARRHESIA_LIMITS_MAX_TAGS_PER_EVENT",
        Keyword.get(limits_defaults, :max_tags_per_event, 256)
      ),
    max_tag_values_per_filter:
      int_env.(
        "PARRHESIA_LIMITS_MAX_TAG_VALUES_PER_FILTER",
        Keyword.get(limits_defaults, :max_tag_values_per_filter, 128)
      ),
    ip_max_event_ingest_per_window:
      int_env.(
        "PARRHESIA_LIMITS_IP_MAX_EVENT_INGEST_PER_WINDOW",
        Keyword.get(limits_defaults, :ip_max_event_ingest_per_window, 1_000)
      ),
    ip_event_ingest_window_seconds:
      int_env.(
        "PARRHESIA_LIMITS_IP_EVENT_INGEST_WINDOW_SECONDS",
        Keyword.get(limits_defaults, :ip_event_ingest_window_seconds, 1)
      ),
    relay_max_event_ingest_per_window:
      int_env.(
        "PARRHESIA_LIMITS_RELAY_MAX_EVENT_INGEST_PER_WINDOW",
        Keyword.get(limits_defaults, :relay_max_event_ingest_per_window, 10_000)
      ),
    relay_event_ingest_window_seconds:
      int_env.(
        "PARRHESIA_LIMITS_RELAY_EVENT_INGEST_WINDOW_SECONDS",
        Keyword.get(limits_defaults, :relay_event_ingest_window_seconds, 1)
      ),
    max_subscriptions_per_connection:
      int_env.(
        "PARRHESIA_LIMITS_MAX_SUBSCRIPTIONS_PER_CONNECTION",
        Keyword.get(limits_defaults, :max_subscriptions_per_connection, 32)
      ),
    max_event_future_skew_seconds:
      int_env.(
        "PARRHESIA_LIMITS_MAX_EVENT_FUTURE_SKEW_SECONDS",
        Keyword.get(limits_defaults, :max_event_future_skew_seconds, 900)
      ),
    max_event_ingest_per_window:
      int_env.(
        "PARRHESIA_LIMITS_MAX_EVENT_INGEST_PER_WINDOW",
        Keyword.get(limits_defaults, :max_event_ingest_per_window, 120)
      ),
    event_ingest_window_seconds:
      int_env.(
        "PARRHESIA_LIMITS_EVENT_INGEST_WINDOW_SECONDS",
        Keyword.get(limits_defaults, :event_ingest_window_seconds, 1)
      ),
    auth_max_age_seconds:
      int_env.(
        "PARRHESIA_LIMITS_AUTH_MAX_AGE_SECONDS",
        Keyword.get(limits_defaults, :auth_max_age_seconds, 600)
      ),
    max_outbound_queue:
      int_env.(
        "PARRHESIA_LIMITS_MAX_OUTBOUND_QUEUE",
        Keyword.get(limits_defaults, :max_outbound_queue, 256)
      ),
    outbound_drain_batch_size:
      int_env.(
        "PARRHESIA_LIMITS_OUTBOUND_DRAIN_BATCH_SIZE",
        Keyword.get(limits_defaults, :outbound_drain_batch_size, 64)
      ),
    outbound_overflow_strategy:
      outbound_overflow_strategy_env.(
        "PARRHESIA_LIMITS_OUTBOUND_OVERFLOW_STRATEGY",
        Keyword.get(limits_defaults, :outbound_overflow_strategy, :close)
      ),
    max_negentropy_payload_bytes:
      int_env.(
        "PARRHESIA_LIMITS_MAX_NEGENTROPY_PAYLOAD_BYTES",
        Keyword.get(limits_defaults, :max_negentropy_payload_bytes, 4096)
      ),
    max_negentropy_sessions_per_connection:
      int_env.(
        "PARRHESIA_LIMITS_MAX_NEGENTROPY_SESSIONS_PER_CONNECTION",
        Keyword.get(limits_defaults, :max_negentropy_sessions_per_connection, 8)
      ),
    max_negentropy_total_sessions:
      int_env.(
        "PARRHESIA_LIMITS_MAX_NEGENTROPY_TOTAL_SESSIONS",
        Keyword.get(limits_defaults, :max_negentropy_total_sessions, 10_000)
      ),
    max_negentropy_items_per_session:
      int_env.(
        "PARRHESIA_LIMITS_MAX_NEGENTROPY_ITEMS_PER_SESSION",
        Keyword.get(limits_defaults, :max_negentropy_items_per_session, 50_000)
      ),
    negentropy_id_list_threshold:
      int_env.(
        "PARRHESIA_LIMITS_NEGENTROPY_ID_LIST_THRESHOLD",
        Keyword.get(limits_defaults, :negentropy_id_list_threshold, 32)
      ),
    negentropy_session_idle_timeout_seconds:
      int_env.(
        "PARRHESIA_LIMITS_NEGENTROPY_SESSION_IDLE_TIMEOUT_SECONDS",
        Keyword.get(limits_defaults, :negentropy_session_idle_timeout_seconds, 60)
      ),
    negentropy_session_sweep_interval_seconds:
      int_env.(
        "PARRHESIA_LIMITS_NEGENTROPY_SESSION_SWEEP_INTERVAL_SECONDS",
        Keyword.get(limits_defaults, :negentropy_session_sweep_interval_seconds, 10)
      )
  ]

  policies = [
    auth_required_for_writes:
      bool_env.(
        "PARRHESIA_POLICIES_AUTH_REQUIRED_FOR_WRITES",
        Keyword.get(policies_defaults, :auth_required_for_writes, false)
      ),
    auth_required_for_reads:
      bool_env.(
        "PARRHESIA_POLICIES_AUTH_REQUIRED_FOR_READS",
        Keyword.get(policies_defaults, :auth_required_for_reads, false)
      ),
    min_pow_difficulty:
      int_env.(
        "PARRHESIA_POLICIES_MIN_POW_DIFFICULTY",
        Keyword.get(policies_defaults, :min_pow_difficulty, 0)
      ),
    accept_ephemeral_events:
      bool_env.(
        "PARRHESIA_POLICIES_ACCEPT_EPHEMERAL_EVENTS",
        Keyword.get(policies_defaults, :accept_ephemeral_events, true)
      ),
    mls_group_event_ttl_seconds:
      int_env.(
        "PARRHESIA_POLICIES_MLS_GROUP_EVENT_TTL_SECONDS",
        Keyword.get(policies_defaults, :mls_group_event_ttl_seconds, 300)
      ),
    marmot_require_h_for_group_queries:
      bool_env.(
        "PARRHESIA_POLICIES_MARMOT_REQUIRE_H_FOR_GROUP_QUERIES",
        Keyword.get(policies_defaults, :marmot_require_h_for_group_queries, true)
      ),
    marmot_group_max_h_values_per_filter:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_GROUP_MAX_H_VALUES_PER_FILTER",
        Keyword.get(policies_defaults, :marmot_group_max_h_values_per_filter, 32)
      ),
    marmot_group_max_query_window_seconds:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_GROUP_MAX_QUERY_WINDOW_SECONDS",
        Keyword.get(policies_defaults, :marmot_group_max_query_window_seconds, 2_592_000)
      ),
    marmot_media_max_imeta_tags_per_event:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_MEDIA_MAX_IMETA_TAGS_PER_EVENT",
        Keyword.get(policies_defaults, :marmot_media_max_imeta_tags_per_event, 8)
      ),
    marmot_media_max_field_value_bytes:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_MEDIA_MAX_FIELD_VALUE_BYTES",
        Keyword.get(policies_defaults, :marmot_media_max_field_value_bytes, 1024)
      ),
    marmot_media_max_url_bytes:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_MEDIA_MAX_URL_BYTES",
        Keyword.get(policies_defaults, :marmot_media_max_url_bytes, 2048)
      ),
    marmot_media_allowed_mime_prefixes:
      csv_env.(
        "PARRHESIA_POLICIES_MARMOT_MEDIA_ALLOWED_MIME_PREFIXES",
        Keyword.get(policies_defaults, :marmot_media_allowed_mime_prefixes, [])
      ),
    marmot_media_reject_mip04_v1:
      bool_env.(
        "PARRHESIA_POLICIES_MARMOT_MEDIA_REJECT_MIP04_V1",
        Keyword.get(policies_defaults, :marmot_media_reject_mip04_v1, true)
      ),
    marmot_push_server_pubkeys:
      csv_env.(
        "PARRHESIA_POLICIES_MARMOT_PUSH_SERVER_PUBKEYS",
        Keyword.get(policies_defaults, :marmot_push_server_pubkeys, [])
      ),
    marmot_push_max_relay_tags:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_PUSH_MAX_RELAY_TAGS",
        Keyword.get(policies_defaults, :marmot_push_max_relay_tags, 16)
      ),
    marmot_push_max_payload_bytes:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_PUSH_MAX_PAYLOAD_BYTES",
        Keyword.get(policies_defaults, :marmot_push_max_payload_bytes, 65_536)
      ),
    marmot_push_max_trigger_age_seconds:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_PUSH_MAX_TRIGGER_AGE_SECONDS",
        Keyword.get(policies_defaults, :marmot_push_max_trigger_age_seconds, 120)
      ),
    marmot_push_require_expiration:
      bool_env.(
        "PARRHESIA_POLICIES_MARMOT_PUSH_REQUIRE_EXPIRATION",
        Keyword.get(policies_defaults, :marmot_push_require_expiration, true)
      ),
    marmot_push_max_expiration_window_seconds:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_PUSH_MAX_EXPIRATION_WINDOW_SECONDS",
        Keyword.get(policies_defaults, :marmot_push_max_expiration_window_seconds, 120)
      ),
    marmot_push_max_server_recipients:
      int_env.(
        "PARRHESIA_POLICIES_MARMOT_PUSH_MAX_SERVER_RECIPIENTS",
        Keyword.get(policies_defaults, :marmot_push_max_server_recipients, 1)
      ),
    management_auth_required:
      bool_env.(
        "PARRHESIA_POLICIES_MANAGEMENT_AUTH_REQUIRED",
        Keyword.get(policies_defaults, :management_auth_required, true)
      )
  ]

  public_listener_defaults = Map.get(listeners_defaults, :public, %{})
  public_bind_defaults = Map.get(public_listener_defaults, :bind, %{})
  public_transport_defaults = Map.get(public_listener_defaults, :transport, %{})
  public_proxy_defaults = Map.get(public_listener_defaults, :proxy, %{})
  public_network_defaults = Map.get(public_listener_defaults, :network, %{})
  public_features_defaults = Map.get(public_listener_defaults, :features, %{})
  public_auth_defaults = Map.get(public_listener_defaults, :auth, %{})
  public_metrics_defaults = Map.get(public_features_defaults, :metrics, %{})
  public_metrics_access_defaults = Map.get(public_metrics_defaults, :access, %{})

  metrics_listener_defaults = Map.get(listeners_defaults, :metrics, %{})
  metrics_listener_bind_defaults = Map.get(metrics_listener_defaults, :bind, %{})
  metrics_listener_transport_defaults = Map.get(metrics_listener_defaults, :transport, %{})
  metrics_listener_network_defaults = Map.get(metrics_listener_defaults, :network, %{})

  metrics_listener_metrics_defaults =
    metrics_listener_defaults
    |> Map.get(:features, %{})
    |> Map.get(:metrics, %{})

  metrics_listener_metrics_access_defaults =
    Map.get(metrics_listener_metrics_defaults, :access, %{})

  public_listener = %{
    enabled: Map.get(public_listener_defaults, :enabled, true),
    bind: %{
      ip: Map.get(public_bind_defaults, :ip, {0, 0, 0, 0}),
      port: int_env.("PORT", Map.get(public_bind_defaults, :port, 4413))
    },
    max_connections:
      infinity_or_int_env.(
        "PARRHESIA_PUBLIC_MAX_CONNECTIONS",
        Map.get(public_listener_defaults, :max_connections, 20_000)
      ),
    transport: %{
      scheme: Map.get(public_transport_defaults, :scheme, :http),
      tls: Map.get(public_transport_defaults, :tls, %{mode: :disabled})
    },
    proxy: %{
      trusted_cidrs:
        csv_env.(
          "PARRHESIA_TRUSTED_PROXIES",
          Map.get(public_proxy_defaults, :trusted_cidrs, [])
        ),
      honor_x_forwarded_for: Map.get(public_proxy_defaults, :honor_x_forwarded_for, true)
    },
    network: %{
      allow_cidrs: Map.get(public_network_defaults, :allow_cidrs, []),
      private_networks_only: Map.get(public_network_defaults, :private_networks_only, false),
      public: Map.get(public_network_defaults, :public, false),
      allow_all: Map.get(public_network_defaults, :allow_all, true)
    },
    features: %{
      nostr: %{
        enabled: public_features_defaults |> Map.get(:nostr, %{}) |> Map.get(:enabled, true)
      },
      admin: %{
        enabled: public_features_defaults |> Map.get(:admin, %{}) |> Map.get(:enabled, true)
      },
      metrics: %{
        enabled:
          bool_env.(
            "PARRHESIA_METRICS_ENABLED_ON_MAIN_ENDPOINT",
            Map.get(public_metrics_defaults, :enabled, true)
          ),
        auth_token:
          string_env.(
            "PARRHESIA_METRICS_AUTH_TOKEN",
            Map.get(public_metrics_defaults, :auth_token)
          ),
        access: %{
          public:
            bool_env.(
              "PARRHESIA_METRICS_PUBLIC",
              Map.get(public_metrics_access_defaults, :public, false)
            ),
          private_networks_only:
            bool_env.(
              "PARRHESIA_METRICS_PRIVATE_NETWORKS_ONLY",
              Map.get(public_metrics_access_defaults, :private_networks_only, true)
            ),
          allow_cidrs:
            csv_env.(
              "PARRHESIA_METRICS_ALLOWED_CIDRS",
              Map.get(public_metrics_access_defaults, :allow_cidrs, [])
            ),
          allow_all: Map.get(public_metrics_access_defaults, :allow_all, true)
        }
      }
    },
    auth: %{
      nip42_required: Map.get(public_auth_defaults, :nip42_required, false),
      nip98_required_for_admin:
        bool_env.(
          "PARRHESIA_POLICIES_MANAGEMENT_AUTH_REQUIRED",
          Map.get(public_auth_defaults, :nip98_required_for_admin, true)
        )
    },
    baseline_acl: Map.get(public_listener_defaults, :baseline_acl, %{read: [], write: []})
  }

  listeners =
    if Map.get(metrics_listener_defaults, :enabled, false) or
         bool_env.("PARRHESIA_METRICS_ENDPOINT_ENABLED", false) do
      Map.put(
        %{public: public_listener},
        :metrics,
        %{
          enabled: true,
          bind: %{
            ip: Map.get(metrics_listener_bind_defaults, :ip, {127, 0, 0, 1}),
            port:
              int_env.(
                "PARRHESIA_METRICS_ENDPOINT_PORT",
                Map.get(metrics_listener_bind_defaults, :port, 9568)
              )
          },
          max_connections:
            infinity_or_int_env.(
              "PARRHESIA_METRICS_ENDPOINT_MAX_CONNECTIONS",
              Map.get(metrics_listener_defaults, :max_connections, 1_024)
            ),
          transport: %{
            scheme: Map.get(metrics_listener_transport_defaults, :scheme, :http),
            tls: Map.get(metrics_listener_transport_defaults, :tls, %{mode: :disabled})
          },
          network: %{
            allow_cidrs: Map.get(metrics_listener_network_defaults, :allow_cidrs, []),
            private_networks_only:
              Map.get(metrics_listener_network_defaults, :private_networks_only, false),
            public: Map.get(metrics_listener_network_defaults, :public, false),
            allow_all: Map.get(metrics_listener_network_defaults, :allow_all, true)
          },
          features: %{
            nostr: %{enabled: false},
            admin: %{enabled: false},
            metrics: %{
              enabled: true,
              auth_token:
                string_env.(
                  "PARRHESIA_METRICS_AUTH_TOKEN",
                  Map.get(metrics_listener_metrics_defaults, :auth_token)
                ),
              access: %{
                public:
                  bool_env.(
                    "PARRHESIA_METRICS_PUBLIC",
                    Map.get(metrics_listener_metrics_access_defaults, :public, false)
                  ),
                private_networks_only:
                  bool_env.(
                    "PARRHESIA_METRICS_PRIVATE_NETWORKS_ONLY",
                    Map.get(
                      metrics_listener_metrics_access_defaults,
                      :private_networks_only,
                      true
                    )
                  ),
                allow_cidrs:
                  csv_env.(
                    "PARRHESIA_METRICS_ALLOWED_CIDRS",
                    Map.get(metrics_listener_metrics_access_defaults, :allow_cidrs, [])
                  ),
                allow_all: Map.get(metrics_listener_metrics_access_defaults, :allow_all, true)
              }
            }
          },
          auth: %{nip42_required: false, nip98_required_for_admin: true},
          baseline_acl: %{read: [], write: []}
        }
      )
    else
      %{public: public_listener}
    end

  retention = [
    check_interval_hours:
      int_env.(
        "PARRHESIA_RETENTION_CHECK_INTERVAL_HOURS",
        Keyword.get(retention_defaults, :check_interval_hours, 24)
      ),
    months_ahead:
      int_env.(
        "PARRHESIA_RETENTION_MONTHS_AHEAD",
        Keyword.get(retention_defaults, :months_ahead, 2)
      ),
    max_db_bytes:
      infinity_or_int_env.(
        "PARRHESIA_RETENTION_MAX_DB_BYTES",
        Keyword.get(retention_defaults, :max_db_bytes, :infinity)
      ),
    max_months_to_keep:
      infinity_or_int_env.(
        "PARRHESIA_RETENTION_MAX_MONTHS_TO_KEEP",
        Keyword.get(retention_defaults, :max_months_to_keep, :infinity)
      ),
    max_partitions_to_drop_per_run:
      int_env.(
        "PARRHESIA_RETENTION_MAX_PARTITIONS_TO_DROP_PER_RUN",
        Keyword.get(retention_defaults, :max_partitions_to_drop_per_run, 1)
      )
  ]

  features = [
    verify_event_signatures_locked?:
      Keyword.get(features_defaults, :verify_event_signatures_locked?, false),
    verify_event_signatures:
      if Keyword.get(features_defaults, :verify_event_signatures_locked?, false) do
        true
      else
        Keyword.get(features_defaults, :verify_event_signatures, true)
      end,
    nip_45_count:
      bool_env.(
        "PARRHESIA_FEATURES_NIP_45_COUNT",
        Keyword.get(features_defaults, :nip_45_count, true)
      ),
    nip_50_search:
      bool_env.(
        "PARRHESIA_FEATURES_NIP_50_SEARCH",
        Keyword.get(features_defaults, :nip_50_search, true)
      ),
    nip_77_negentropy:
      bool_env.(
        "PARRHESIA_FEATURES_NIP_77_NEGENTROPY",
        Keyword.get(features_defaults, :nip_77_negentropy, true)
      ),
    marmot_push_notifications:
      bool_env.(
        "PARRHESIA_FEATURES_MARMOT_PUSH_NOTIFICATIONS",
        Keyword.get(features_defaults, :marmot_push_notifications, false)
      )
  ]

  config :parrhesia, Parrhesia.Repo,
    url: database_url,
    pool_size: pool_size,
    queue_target: queue_target,
    queue_interval: queue_interval

  config :parrhesia, Parrhesia.ReadRepo,
    url: database_url,
    pool_size: read_pool_size,
    queue_target: read_queue_target,
    queue_interval: read_queue_interval

  config :parrhesia,
    relay_url: string_env.("PARRHESIA_RELAY_URL", relay_url_default),
    acl: [
      protected_filters:
        json_env.(
          "PARRHESIA_ACL_PROTECTED_FILTERS",
          Keyword.get(acl_defaults, :protected_filters, [])
        )
    ],
    identity: [
      path: string_env.("PARRHESIA_IDENTITY_PATH", nil),
      private_key: string_env.("PARRHESIA_IDENTITY_PRIVATE_KEY", nil)
    ],
    sync: [
      path: string_env.("PARRHESIA_SYNC_PATH", nil),
      start_workers?:
        bool_env.(
          "PARRHESIA_SYNC_START_WORKERS",
          Keyword.get(Application.get_env(:parrhesia, :sync, []), :start_workers?, true)
        )
    ],
    moderation_cache_enabled:
      bool_env.("PARRHESIA_MODERATION_CACHE_ENABLED", moderation_cache_enabled_default),
    enable_expiration_worker:
      bool_env.("PARRHESIA_ENABLE_EXPIRATION_WORKER", enable_expiration_worker_default),
    listeners: listeners,
    limits: limits,
    policies: policies,
    retention: retention,
    features: features

  case System.get_env("PARRHESIA_EXTRA_CONFIG") do
    nil -> :ok
    "" -> :ok
    path -> import_config path
  end
end
