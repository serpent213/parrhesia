import Config

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing. Example: ecto://USER:PASS@HOST/DATABASE"

  default_pool_size =
    :parrhesia
    |> Application.get_env(Parrhesia.Repo, [])
    |> Keyword.get(:pool_size, 32)

  pool_size =
    case System.get_env("POOL_SIZE") do
      nil -> default_pool_size
      value -> String.to_integer(value)
    end

  config :parrhesia, Parrhesia.Repo,
    url: database_url,
    pool_size: pool_size

  config :parrhesia, Parrhesia.Web.Endpoint,
    port: String.to_integer(System.get_env("PORT") || "4000")
end
