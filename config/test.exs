import Config

config :logger, level: :warning

test_endpoint_port =
  case System.get_env("PARRHESIA_TEST_HTTP_PORT") do
    nil -> 0
    value -> String.to_integer(value)
  end

config :parrhesia, :listeners,
  public: %{
    enabled: true,
    bind: %{ip: {127, 0, 0, 1}, port: test_endpoint_port},
    transport: %{scheme: :http, tls: %{mode: :disabled}},
    proxy: %{trusted_cidrs: [], honor_x_forwarded_for: true},
    network: %{allow_all: true},
    features: %{
      nostr: %{enabled: true},
      admin: %{enabled: true},
      metrics: %{enabled: true, access: %{private_networks_only: true}, auth_token: nil}
    },
    auth: %{nip42_required: false, nip98_required_for_admin: true},
    baseline_acl: %{read: [], write: []}
  }

config :parrhesia,
  enable_expiration_worker: false,
  moderation_cache_enabled: false,
  identity: [
    path: Path.join(System.tmp_dir!(), "parrhesia_test_identity.json"),
    private_key: nil
  ],
  sync: [
    path: Path.join(System.tmp_dir!(), "parrhesia_test_sync.json"),
    start_workers?: false
  ],
  features: [verify_event_signatures: false]

pg_host = System.get_env("PGHOST")

repo_host_opts =
  if is_binary(pg_host) and String.starts_with?(pg_host, "/") do
    [socket_dir: pg_host]
  else
    [
      hostname: pg_host || "localhost",
      port: String.to_integer(System.get_env("PGPORT") || "5432")
    ]
  end

config :parrhesia,
       Parrhesia.Repo,
       [
         username: System.get_env("PGUSER") || System.get_env("USER") || "agent",
         password: System.get_env("PGPASSWORD"),
         database: System.get_env("PGDATABASE") || "parrhesia_test",
         pool: Ecto.Adapters.SQL.Sandbox,
         pool_size: 10
       ] ++ repo_host_opts
