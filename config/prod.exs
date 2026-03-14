import Config

config :parrhesia, Parrhesia.Repo,
  pool_size: 32,
  queue_target: 1_000,
  queue_interval: 5_000

# Production runtime configuration lives in config/runtime.exs.
