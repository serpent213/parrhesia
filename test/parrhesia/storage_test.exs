defmodule Parrhesia.StorageTest do
  use ExUnit.Case, async: false

  alias Parrhesia.Storage

  test "resolves default storage modules" do
    assert Storage.events() == Parrhesia.Storage.Adapters.Postgres.Events
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
end
