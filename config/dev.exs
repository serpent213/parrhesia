import Config

config :logger, :console, format: "[$level] $message\n"

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
         database: System.get_env("PGDATABASE") || "parrhesia_dev",
         show_sensitive_data_on_connection_error: true,
         pool_size: 10
       ] ++ repo_host_opts

config :parrhesia,
       Parrhesia.ReadRepo,
       [
         username: System.get_env("PGUSER") || System.get_env("USER") || "agent",
         password: System.get_env("PGPASSWORD"),
         database: System.get_env("PGDATABASE") || "parrhesia_dev",
         show_sensitive_data_on_connection_error: true,
         pool_size: 10
       ] ++ repo_host_opts
