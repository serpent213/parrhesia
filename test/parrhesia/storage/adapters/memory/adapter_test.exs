defmodule Parrhesia.Storage.Adapters.Memory.AdapterTest do
  use ExUnit.Case, async: false

  alias Parrhesia.Storage.Adapters.Memory.Admin
  alias Parrhesia.Storage.Adapters.Memory.Events
  alias Parrhesia.Storage.Adapters.Memory.Groups
  alias Parrhesia.Storage.Adapters.Memory.Moderation

  test "memory adapter supports basic behavior contract operations" do
    event_id = String.duplicate("a", 64)
    event = %{"id" => event_id, "pubkey" => "pk", "kind" => 1, "tags" => [], "content" => "hello"}

    assert {:ok, _event} = Events.put_event(%{}, event)
    assert {:ok, [result]} = Events.query(%{}, [%{"ids" => [event_id]}], [])
    assert result["id"] == event_id

    assert :ok = Moderation.ban_pubkey(%{}, "pk")
    assert {:ok, true} = Moderation.pubkey_banned?(%{}, "pk")

    assert {:ok, membership} =
             Groups.put_membership(%{}, %{group_id: "g1", pubkey: "pk", role: "member"})

    assert membership.group_id == "g1"

    assert :ok = Admin.append_audit_log(%{}, %{method: "ping"})
    assert {:ok, [%{method: "ping"}]} = Admin.list_audit_logs(%{}, [])
  end
end
