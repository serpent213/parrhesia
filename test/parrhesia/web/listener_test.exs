defmodule Parrhesia.Web.ListenerTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Web.Listener

  test "listener max_connections is translated to ThousandIsland num_connections" do
    options =
      listener(%{max_connections: 20_000})
      |> Listener.bandit_options()

    assert Keyword.get(options, :thousand_island_options) == [num_connections: 200]
  end

  test "listener max_connections honors custom num_acceptors when deriving the limit" do
    options =
      listener(%{
        max_connections: 20_000,
        bandit_options: [thousand_island_options: [num_acceptors: 80]]
      })
      |> Listener.bandit_options()

    thousand_island_options = Keyword.get(options, :thousand_island_options)

    assert Keyword.get(thousand_island_options, :num_acceptors) == 80
    assert Keyword.get(thousand_island_options, :num_connections) == 250
  end

  test "explicit ThousandIsland num_connections overrides the first-class listener cap" do
    options =
      listener(%{
        max_connections: 20_000,
        bandit_options: [thousand_island_options: [num_acceptors: 80, num_connections: 50]]
      })
      |> Listener.bandit_options()

    thousand_island_options = Keyword.get(options, :thousand_island_options)

    assert Keyword.get(thousand_island_options, :num_acceptors) == 80
    assert Keyword.get(thousand_island_options, :num_connections) == 50
  end

  test "metrics listeners default to a lower max_connections ceiling" do
    listener = Listener.from_opts(listener: %{id: :metrics, bind: %{port: 9568}})

    assert listener.max_connections == 1_024
  end

  defp listener(overrides) do
    Listener.from_opts(
      listener:
        Map.merge(
          %{
            id: :public,
            enabled: true,
            bind: %{ip: {127, 0, 0, 1}, port: 4413},
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
          },
          overrides
        )
    )
  end
end
