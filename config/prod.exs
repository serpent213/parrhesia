import Config

database_url =
  System.get_env("DATABASE_URL") ||
    raise "environment variable DATABASE_URL is missing. Example: ecto://USER:PASS@HOST/DATABASE"

config :parrhesia, Parrhesia.Repo,
  url: database_url,
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")
