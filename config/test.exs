import Config

config :logger, level: :warning

config :parrhesia, Parrhesia.Web.Endpoint,
  port: 0,
  ip: {127, 0, 0, 1}

config :parrhesia, enable_expiration_worker: false

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
