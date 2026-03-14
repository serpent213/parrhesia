import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing. Example: ecto://USER:PASS@HOST/DATABASE"

  repo_defaults = Application.get_env(:parrhesia, Parrhesia.Repo, [])

  default_pool_size = Keyword.get(repo_defaults, :pool_size, 32)
  default_queue_target = Keyword.get(repo_defaults, :queue_target, 1_000)
  default_queue_interval = Keyword.get(repo_defaults, :queue_interval, 5_000)

  pool_size =
    case System.get_env("POOL_SIZE") do
      nil -> default_pool_size
      value -> String.to_integer(value)
    end

  queue_target =
    case System.get_env("DB_QUEUE_TARGET_MS") do
      nil -> default_queue_target
      value -> String.to_integer(value)
    end

  queue_interval =
    case System.get_env("DB_QUEUE_INTERVAL_MS") do
      nil -> default_queue_interval
      value -> String.to_integer(value)
    end

  config :parrhesia, Parrhesia.Repo,
    url: database_url,
    pool_size: pool_size,
    queue_target: queue_target,
    queue_interval: queue_interval

  config :parrhesia, Parrhesia.Web.Endpoint,
    port: String.to_integer(System.get_env("PORT") || "4000")
end
