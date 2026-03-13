defmodule Parrhesia.Groups.FlowTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Groups.Flow
  alias Parrhesia.Repo
  alias Parrhesia.Storage

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "handles membership request kinds by upserting group memberships" do
    event = %{
      "kind" => 8_000,
      "pubkey" => String.duplicate("a", 64),
      "tags" => [["h", "group-1"]]
    }

    assert :ok = Flow.handle_event(event)

    assert {:ok, membership} =
             Storage.groups().get_membership(%{}, "group-1", String.duplicate("a", 64))

    assert membership.role == "requested"
  end

  test "marks configured membership and relay kinds as group related" do
    assert Flow.group_related_kind?(8_000)
    assert Flow.group_related_kind?(13_534)
    refute Flow.group_related_kind?(1)
  end
end
