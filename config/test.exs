import Config

config :logger, level: :warning

config :parrhesia, Parrhesia.Web.Endpoint,
  port: 0,
  ip: {127, 0, 0, 1}
