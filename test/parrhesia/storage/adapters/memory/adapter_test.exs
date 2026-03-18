defmodule Parrhesia.Storage.Adapters.Memory.AdapterTest do
  use Parrhesia.IntegrationCase, async: false

  alias Parrhesia.Storage.Adapters.Memory.ACL
  alias Parrhesia.Storage.Adapters.Memory.Admin
  alias Parrhesia.Storage.Adapters.Memory.Events
  alias Parrhesia.Storage.Adapters.Memory.Groups
  alias Parrhesia.Storage.Adapters.Memory.Moderation

  test "memory adapter supports basic behavior contract operations" do
    event_id = String.duplicate("a", 64)

    event = %{
      "id" => event_id,
      "pubkey" => "pk",
      "created_at" => 1_700_000_000,
      "kind" => 1,
      "tags" => [],
      "content" => "hello"
    }

    assert {:ok, _event} = Events.put_event(%{}, event)
    assert {:ok, [result]} = Events.query(%{}, [%{"ids" => [event_id]}], [])
    assert result["id"] == event_id

    assert {:ok, [%{created_at: 1_700_000_000, id: <<_::size(256)>>}]} =
             Events.query_event_refs(%{}, [%{"ids" => [event_id]}], [])

    assert :ok = Moderation.ban_pubkey(%{}, "pk")
    assert {:ok, true} = Moderation.pubkey_banned?(%{}, "pk")
    assert {:ok, false} = Moderation.has_allowed_pubkeys?(%{})
    assert :ok = Moderation.allow_pubkey(%{}, String.duplicate("f", 64))
    assert {:ok, true} = Moderation.has_allowed_pubkeys?(%{})

    assert {:ok, %{capability: :sync_read}} =
             ACL.put_rule(%{}, %{
               principal_type: :pubkey,
               principal: String.duplicate("f", 64),
               capability: :sync_read,
               match: %{"kinds" => [5000], "#r" => ["tribes.accounts.user"]}
             })

    assert {:ok, membership} =
             Groups.put_membership(%{}, %{group_id: "g1", pubkey: "pk", role: "member"})

    assert membership.group_id == "g1"

    assert :ok = Admin.append_audit_log(%{}, %{method: "ping"})
    assert {:ok, [%{method: "ping"}]} = Admin.list_audit_logs(%{}, [])
  end

  test "memory adapter enforces recipient visibility for giftwrap queries" do
    recipient = String.duplicate("b", 64)

    giftwrap_event = %{
      "id" => String.duplicate("c", 64),
      "pubkey" => "pk",
      "kind" => 1059,
      "tags" => [["p", recipient]],
      "content" => "ciphertext"
    }

    assert {:ok, _event} = Events.put_event(%{}, giftwrap_event)

    filters = [%{"kinds" => [1059], "#p" => [recipient]}]

    assert {:ok, [result]} = Events.query(%{}, filters, requester_pubkeys: [recipient])
    assert result["id"] == giftwrap_event["id"]

    assert {:ok, []} = Events.query(%{}, filters, requester_pubkeys: [])
    assert {:ok, 0} = Events.count(%{}, filters, requester_pubkeys: [])
  end

  test "memory adapter applies filter limits in descending chronological order" do
    now = 1_700_000_000
    author = String.duplicate("d", 64)

    older =
      %{
        "id" => String.duplicate("1", 64),
        "pubkey" => author,
        "created_at" => now,
        "kind" => 1,
        "tags" => [],
        "content" => "older"
      }

    tie_loser =
      %{
        "id" => String.duplicate("3", 64),
        "pubkey" => author,
        "created_at" => now + 1,
        "kind" => 1,
        "tags" => [],
        "content" => "tie-loser"
      }

    tie_winner =
      %{
        "id" => String.duplicate("2", 64),
        "pubkey" => author,
        "created_at" => now + 1,
        "kind" => 1,
        "tags" => [],
        "content" => "tie-winner"
      }

    newest =
      %{
        "id" => String.duplicate("4", 64),
        "pubkey" => author,
        "created_at" => now + 2,
        "kind" => 1,
        "tags" => [],
        "content" => "newest"
      }

    assert {:ok, _event} = Events.put_event(%{}, older)
    assert {:ok, _event} = Events.put_event(%{}, tie_loser)
    assert {:ok, _event} = Events.put_event(%{}, tie_winner)
    assert {:ok, _event} = Events.put_event(%{}, newest)

    assert {:ok, results} =
             Events.query(%{}, [%{"authors" => [author], "kinds" => [1], "limit" => 2}], [])

    assert Enum.map(results, & &1["id"]) == [newest["id"], tie_winner["id"]]
  end

  test "memory adapter serves tag-filter queries from newest matching events" do
    now = 1_700_000_100
    author = String.duplicate("e", 64)

    off_topic =
      %{
        "id" => String.duplicate("5", 64),
        "pubkey" => author,
        "created_at" => now + 3,
        "kind" => 1,
        "tags" => [["t", "other"]],
        "content" => "off-topic"
      }

    oldest =
      %{
        "id" => String.duplicate("6", 64),
        "pubkey" => author,
        "created_at" => now,
        "kind" => 1,
        "tags" => [["t", "bench"]],
        "content" => "oldest"
      }

    middle =
      %{
        "id" => String.duplicate("7", 64),
        "pubkey" => author,
        "created_at" => now + 1,
        "kind" => 1,
        "tags" => [["t", "bench"]],
        "content" => "middle"
      }

    newest =
      %{
        "id" => String.duplicate("8", 64),
        "pubkey" => author,
        "created_at" => now + 2,
        "kind" => 1,
        "tags" => [["t", "bench"]],
        "content" => "newest"
      }

    assert {:ok, _event} = Events.put_event(%{}, off_topic)
    assert {:ok, _event} = Events.put_event(%{}, oldest)
    assert {:ok, _event} = Events.put_event(%{}, middle)
    assert {:ok, _event} = Events.put_event(%{}, newest)

    assert {:ok, results} = Events.query(%{}, [%{"#t" => ["bench"], "limit" => 2}], [])

    assert Enum.map(results, & &1["id"]) == [newest["id"], middle["id"]]
  end
end
