defmodule Parrhesia.Storage.Adapters.Memory.AdapterTest do
  use Parrhesia.IntegrationCase, async: false

  alias Parrhesia.Storage.Adapters.Memory.ACL
  alias Parrhesia.Storage.Adapters.Memory.Admin
  alias Parrhesia.Storage.Adapters.Memory.Events
  alias Parrhesia.Storage.Adapters.Memory.Groups
  alias Parrhesia.Storage.Adapters.Memory.Moderation
  alias Parrhesia.Storage.Adapters.Memory.Store

  setup do
    start_supervised!(Store)
    :ok
  end

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

  test "memory adapter counts and returns refs without duplicate overlaps across indexed filters" do
    author = String.duplicate("9", 64)
    tag = "shared"

    older =
      %{
        "id" => String.duplicate("a", 64),
        "pubkey" => author,
        "created_at" => 1_700_000_200,
        "kind" => 1,
        "tags" => [["t", tag]],
        "content" => "older"
      }

    newer =
      %{
        "id" => String.duplicate("b", 64),
        "pubkey" => author,
        "created_at" => 1_700_000_201,
        "kind" => 1,
        "tags" => [["t", tag]],
        "content" => "newer"
      }

    unrelated =
      %{
        "id" => String.duplicate("c", 64),
        "pubkey" => String.duplicate("d", 64),
        "created_at" => 1_700_000_202,
        "kind" => 2,
        "tags" => [["t", "other"]],
        "content" => "unrelated"
      }

    assert {:ok, _event} = Events.put_event(%{}, older)
    assert {:ok, _event} = Events.put_event(%{}, newer)
    assert {:ok, _event} = Events.put_event(%{}, unrelated)

    filters = [
      %{"authors" => [author], "kinds" => [1]},
      %{"#t" => [tag]}
    ]

    assert {:ok, 2} = Events.count(%{}, filters, [])

    assert {:ok, refs} = Events.query_event_refs(%{}, filters, [])

    assert Enum.map(refs, &Base.encode16(&1.id, case: :lower)) == [older["id"], newer["id"]]
  end

  test "memory adapter uses indexes for vanish and keeps unrelated events" do
    author = String.duplicate("e", 64)
    other = String.duplicate("f", 64)

    own_event =
      %{
        "id" => String.duplicate("1", 64),
        "pubkey" => author,
        "created_at" => 1_700_000_300,
        "kind" => 1,
        "tags" => [],
        "content" => "own-event"
      }

    giftwrap_event =
      %{
        "id" => String.duplicate("2", 64),
        "pubkey" => other,
        "created_at" => 1_700_000_301,
        "kind" => 1059,
        "tags" => [["p", author]],
        "content" => "giftwrap"
      }

    other_event =
      %{
        "id" => String.duplicate("3", 64),
        "pubkey" => other,
        "created_at" => 1_700_000_302,
        "kind" => 1,
        "tags" => [],
        "content" => "other"
      }

    assert {:ok, _event} = Events.put_event(%{}, own_event)
    assert {:ok, _event} = Events.put_event(%{}, giftwrap_event)
    assert {:ok, _event} = Events.put_event(%{}, other_event)

    assert {:ok, 2} =
             Events.vanish(%{}, %{"pubkey" => author, "created_at" => 1_700_000_400})

    assert {:ok, nil} = Events.get_event(%{}, own_event["id"])
    assert {:ok, nil} = Events.get_event(%{}, giftwrap_event["id"])
    assert {:ok, remaining} = Events.get_event(%{}, other_event["id"])
    assert remaining["id"] == other_event["id"]
  end

  test "memory admin keeps a bounded newest-first audit log" do
    Enum.each(1..1_005, fn index ->
      assert :ok =
               Admin.append_audit_log(%{}, %{
                 method: if(rem(index, 2) == 0, do: "stats", else: "ping"),
                 actor_pubkey: if(rem(index, 3) == 0, do: "actor-a", else: "actor-b"),
                 params: %{index: index}
               })
    end)

    assert {:ok, latest_logs} = Admin.list_audit_logs(%{}, limit: 3)
    assert length(latest_logs) == 3
    assert Enum.map(latest_logs, & &1.params.index) == [1005, 1004, 1003]

    assert {:ok, actor_logs} = Admin.list_audit_logs(%{}, actor_pubkey: "actor-a", limit: 2)
    assert Enum.all?(actor_logs, &(&1.actor_pubkey == "actor-a"))

    assert {:ok, stats_logs} = Admin.list_audit_logs(%{}, method: :stats, limit: 2)
    assert Enum.all?(stats_logs, &(&1.method == "stats"))

    assert {:ok, retained_logs} = Admin.list_audit_logs(%{}, limit: 2_000)
    assert length(retained_logs) == 1_000
    assert Enum.any?(retained_logs, &(&1.params.index == 1005))
    refute Enum.any?(retained_logs, &(&1.params.index == 1))
  end
end
