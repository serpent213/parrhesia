defmodule Parrhesia.Groups.FlowTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.Groups.Flow
  alias Parrhesia.Storage

  test "handles join requests by upserting relay memberships" do
    event = %{
      "kind" => 28_934,
      "pubkey" => String.duplicate("a", 64),
      "tags" => [["-"], ["claim", "invite-code"]],
      "id" => "join-1"
    }

    assert :ok = Flow.handle_event(event)

    assert {:ok, membership} = Flow.get_membership(String.duplicate("a", 64))

    assert membership.role == "member"
    assert membership.metadata["source_kind"] == 28_934
  end

  test "membership snapshot replaces the stored relay memberships" do
    assert {:ok, _membership} =
             Storage.groups().put_membership(%{}, %{
               group_id: "__relay_access__",
               pubkey: String.duplicate("a", 64),
               role: "member"
             })

    snapshot = %{
      "kind" => 13_534,
      "tags" => [["-"], ["member", String.duplicate("b", 64)]],
      "id" => "snapshot-1"
    }

    assert :ok = Flow.handle_event(snapshot)

    assert {:ok, memberships} = Flow.list_memberships()
    assert Enum.map(memberships, & &1.pubkey) == [String.duplicate("b", 64)]
  end

  test "marks configured relay access kinds as handled" do
    assert Flow.relay_access_kind?(28_934)
    assert Flow.relay_access_kind?(13_534)
    refute Flow.relay_access_kind?(1)
  end
end
