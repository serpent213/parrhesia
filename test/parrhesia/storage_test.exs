defmodule Parrhesia.StorageTest do
  use Parrhesia.IntegrationCase, async: false

  alias Parrhesia.PostgresRepos
  alias Parrhesia.Storage

  test "resolves default storage modules" do
    assert Storage.events() == Parrhesia.Storage.Adapters.Postgres.Events
    assert Storage.acl() == Parrhesia.Storage.Adapters.Postgres.ACL
    assert Storage.moderation() == Parrhesia.Storage.Adapters.Postgres.Moderation
    assert Storage.groups() == Parrhesia.Storage.Adapters.Postgres.Groups
    assert Storage.admin() == Parrhesia.Storage.Adapters.Postgres.Admin
  end

  test "raises when configured module does not implement required behavior" do
    previous = Application.get_env(:parrhesia, :storage, [])

    Application.put_env(:parrhesia, :storage, events: Parrhesia.Config)

    on_exit(fn ->
      Application.put_env(:parrhesia, :storage, previous)
    end)

    assert_raise ArgumentError,
                 ~r/does not implement Parrhesia\.Storage\.Events/,
                 fn ->
                   Storage.events()
                 end
  end

  test "postgres repos are disabled for non-postgres storage backends" do
    [{:config, previous}] = :ets.lookup(Parrhesia.Config, :config)

    updated_storage =
      previous
      |> Map.get(:storage, [])
      |> Keyword.put(:backend, :memory)

    :ets.insert(Parrhesia.Config, {:config, Map.put(previous, :storage, updated_storage)})

    on_exit(fn ->
      :ets.insert(Parrhesia.Config, {:config, previous})
    end)

    refute PostgresRepos.postgres_enabled?()
    refute PostgresRepos.separate_read_pool_enabled?()
    assert PostgresRepos.started_repos() == []
  end
end
