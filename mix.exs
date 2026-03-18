defmodule Parrhesia.MixProject do
  use Mix.Project

  def project do
    [
      app: :parrhesia,
      version: "0.6.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Parrhesia.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        bench: :test,
        "bench.collect": :test,
        "bench.update": :test,
        "bench.at": :test
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Runtime: web + protocol edge
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.15"},
      {:websock_adapter, "~> 0.5"},
      {:lib_secp256k1, "~> 0.7"},

      # Runtime: storage adapter (Postgres first)
      {:ecto_sql, "~> 3.12"},
      {:postgrex, ">= 0.0.0"},
      {:req, "~> 0.5"},

      # Runtime: telemetry + prometheus exporter (/metrics)
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus, "~> 1.1"},

      # Test tooling
      {:stream_data, "~> 1.0", only: :test},
      {:websockex, "~> 0.4"},

      # Project tooling
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:deps_changelog, "~> 0.3"},
      {:igniter, "~> 0.6", only: [:dev, :test]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "test.nak_e2e": ["cmd ./scripts/run_nak_e2e.sh"],
      "test.marmot_e2e": ["cmd ./scripts/run_marmot_e2e.sh"],
      "test.node_sync_e2e": ["cmd ./scripts/run_node_sync_e2e.sh"],
      "test.node_sync_docker_e2e": ["cmd ./scripts/run_node_sync_docker_e2e.sh"],
      bench: ["cmd ./scripts/run_bench_compare.sh"],
      "bench.collect": ["cmd ./scripts/run_bench_collect.sh"],
      "bench.update": ["cmd ./scripts/run_bench_update.sh"],
      "bench.at": ["cmd ./scripts/run_bench_at_ref.sh"],
      # cov: ["cmd mix coveralls.lcov"],
      lint: ["format --check-formatted", "credo"],
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict --all",
        "deps.unlock --unused",
        "test",
        # "test.nak_e2e",
        "test.marmot_e2e"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      output: "_build/doc",
      extras: [
        "README.md",
        "docs/LOCAL_API.md",
        "docs/SYNC.md",
        "docs/ARCH.md",
        "docs/CLUSTER.md",
        "BENCHMARK.md"
      ],
      groups_for_modules: [
        "Embedded API": [
          Parrhesia.API.ACL,
          Parrhesia.API.Admin,
          Parrhesia.API.Auth,
          Parrhesia.API.Auth.Context,
          Parrhesia.API.Events,
          Parrhesia.API.Events.PublishResult,
          Parrhesia.API.Identity,
          Parrhesia.API.RequestContext,
          Parrhesia.API.Stream,
          Parrhesia.API.Sync
        ],
        Runtime: [
          Parrhesia,
          Parrhesia.Release,
          Parrhesia.Runtime
        ]
      ],
      nest_modules_by_prefix: [Parrhesia.API]
    ]
  end
end
