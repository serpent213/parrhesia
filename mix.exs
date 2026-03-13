defmodule Parrhesia.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrhesia,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Runtime: web + protocol edge
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.15"},

      # Runtime: storage adapter (Postgres first)
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},

      # Runtime: telemetry + prometheus exporter (/metrics)
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus, "~> 1.1"},

      # Test tooling
      {:stream_data, "~> 1.0", only: :test},
      {:mox, "~> 1.1", only: :test},
      {:bypass, "~> 2.1", only: :test},
      {:websockex, "~> 0.4", only: :test},

      # Project tooling
      {:deps_changelog, "~> 0.3"},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end
end
