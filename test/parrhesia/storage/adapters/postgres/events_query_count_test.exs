defmodule Parrhesia.Storage.Adapters.Postgres.EventsQueryCountTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Storage.Adapters.Postgres.Events

  test "query/3 translates NIP filters including tag filters" do
    author = String.duplicate("a", 64)
    other_author = String.duplicate("b", 64)
    target_pubkey = String.duplicate("c", 64)
    other_target = String.duplicate("d", 64)
    referenced_event = String.duplicate("e", 64)

    matching =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_000,
        "kind" => 1,
        "tags" => [["p", target_pubkey], ["e", referenced_event], ["x", "topic"]],
        "content" => "matching"
      })

    _non_matching_tag =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_001,
        "kind" => 1,
        "tags" => [["p", other_target], ["e", referenced_event]],
        "content" => "other-target"
      })

    _non_matching_author =
      persist_event(%{
        "pubkey" => other_author,
        "created_at" => 1_700_000_002,
        "kind" => 1,
        "tags" => [["p", target_pubkey], ["e", referenced_event]],
        "content" => "other-author"
      })

    filters = [
      %{
        "authors" => [author],
        "kinds" => [1],
        "#p" => [target_pubkey],
        "#e" => [referenced_event]
      }
    ]

    assert {:ok, [result]} = Events.query(%{}, filters, [])
    assert result["id"] == matching["id"]
    assert ["p", target_pubkey] in result["tags"]
    assert ["e", referenced_event] in result["tags"]
  end

  test "query/3 applies filter limit and deterministic tie-break ordering" do
    author = String.duplicate("1", 64)

    tie_a =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_100,
        "kind" => 1,
        "tags" => [],
        "content" => "tie-a"
      })

    tie_b =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_100,
        "kind" => 1,
        "tags" => [],
        "content" => "tie-b"
      })

    newest =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_101,
        "kind" => 1,
        "tags" => [],
        "content" => "newest"
      })

    filters = [%{"authors" => [author], "kinds" => [1], "limit" => 2}]

    assert {:ok, results} = Events.query(%{}, filters, [])

    tie_winner_id = Enum.min([tie_a["id"], tie_b["id"]])
    assert Enum.map(results, & &1["id"]) == [newest["id"], tie_winner_id]
  end

  test "query_event_refs/3 returns sorted lightweight refs for negentropy" do
    author = String.duplicate("9", 64)

    later =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_510,
        "kind" => 1,
        "content" => "later"
      })

    earlier =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_500,
        "kind" => 1,
        "content" => "earlier"
      })

    assert {:ok, refs} =
             Events.query_event_refs(%{}, [%{"authors" => [author], "kinds" => [1]}], [])

    assert refs == [
             %{
               created_at: earlier["created_at"],
               id: Base.decode16!(earlier["id"], case: :mixed)
             },
             %{created_at: later["created_at"], id: Base.decode16!(later["id"], case: :mixed)}
           ]
  end

  test "count/3 ORs filters, deduplicates matches and respects tag filters" do
    now = 1_700_001_000
    target_pubkey = String.duplicate("f", 64)
    referenced_event = String.duplicate("0", 64)

    matching =
      persist_event(%{
        "pubkey" => String.duplicate("2", 64),
        "created_at" => 1_700_000_200,
        "kind" => 7,
        "tags" => [["p", target_pubkey], ["e", referenced_event]],
        "content" => "reaction"
      })

    another_match =
      persist_event(%{
        "pubkey" => String.duplicate("3", 64),
        "created_at" => 1_700_000_201,
        "kind" => 7,
        "tags" => [["p", target_pubkey]],
        "content" => "reaction-2"
      })

    _expired =
      persist_event(%{
        "pubkey" => String.duplicate("4", 64),
        "created_at" => 1_700_000_199,
        "kind" => 7,
        "tags" => [["p", target_pubkey], ["expiration", Integer.to_string(now - 1)]],
        "content" => "expired"
      })

    _non_matching =
      persist_event(%{
        "pubkey" => String.duplicate("5", 64),
        "created_at" => 1_700_000_202,
        "kind" => 7,
        "tags" => [["p", String.duplicate("6", 64)]],
        "content" => "other"
      })

    filters = [
      %{"kinds" => [7], "#p" => [target_pubkey], "#e" => [referenced_event]},
      %{"ids" => [matching["id"], another_match["id"]]}
    ]

    assert {:ok, 2} = Events.count(%{}, filters, now: now)
  end

  test "replaceable events expose only the current winner" do
    author = String.duplicate("a", 64)

    older =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_300,
        "kind" => 0,
        "content" => "profile-v1"
      })

    newer =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_301,
        "kind" => 0,
        "content" => "profile-v2"
      })

    assert {:ok, [result]} = Events.query(%{}, [%{"authors" => [author], "kinds" => [0]}], [])
    assert result["id"] == newer["id"]

    assert {:ok, nil} = Events.get_event(%{}, older["id"])
    assert {:ok, persisted_newer} = Events.get_event(%{}, newer["id"])
    assert persisted_newer["id"] == newer["id"]

    assert {:ok, 1} = Events.count(%{}, [%{"ids" => [older["id"], newer["id"]]}], [])
  end

  test "addressable events tie-break by lexical id for identical timestamps" do
    author = String.duplicate("b", 64)

    first =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_400,
        "kind" => 30_023,
        "tags" => [["d", "topic"]],
        "content" => "version-a"
      })

    second =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_400,
        "kind" => 30_023,
        "tags" => [["d", "topic"]],
        "content" => "version-b"
      })

    winner_id = Enum.min([first["id"], second["id"]])
    loser_id = Enum.max([first["id"], second["id"]])

    assert {:ok, [result]} =
             Events.query(
               %{},
               [%{"authors" => [author], "kinds" => [30_023], "#d" => ["topic"]}],
               []
             )

    assert result["id"] == winner_id
    assert {:ok, nil} = Events.get_event(%{}, loser_id)
    assert {:ok, 1} = Events.count(%{}, [%{"ids" => [first["id"], second["id"]]}], [])
  end

  test "query/3 supports search filter and giftwrap recipient restriction" do
    recipient = String.duplicate("9", 64)

    allowed =
      persist_event(%{
        "kind" => 1059,
        "tags" => [["p", recipient]],
        "content" => "encrypted hello to recipient"
      })

    _other =
      persist_event(%{
        "kind" => 1059,
        "tags" => [["p", String.duplicate("1", 64)]],
        "content" => "encrypted hello to somebody else"
      })

    filters = [%{"kinds" => [1059], "search" => "recipient"}]

    assert {:ok, [result]} =
             Events.query(%{}, filters, requester_pubkeys: [recipient])

    assert result["id"] == allowed["id"]

    assert {:ok, []} = Events.query(%{}, filters, requester_pubkeys: [])
    assert {:ok, 0} = Events.count(%{}, filters, requester_pubkeys: [])
  end

  test "search ranks FTS matches by relevance and applies limit after ranking" do
    stronger_match =
      persist_event(%{
        "kind" => 1,
        "created_at" => 1_700_000_210,
        "content" => "relay relay relay search ranking"
      })

    _newer_weaker_match =
      persist_event(%{
        "kind" => 1,
        "created_at" => 1_700_000_211,
        "content" => "relay only"
      })

    filters = [%{"kinds" => [1], "search" => "relay", "limit" => 1}]

    assert {:ok, [result]} = Events.query(%{}, filters, [])
    assert result["id"] == stronger_match["id"]
    assert {:ok, 2} = Events.count(%{}, filters, [])
  end

  test "search falls back to trigram matching for short prefixes" do
    matching =
      persist_event(%{
        "kind" => 1,
        "content" => "alpha relay note"
      })

    _other =
      persist_event(%{
        "kind" => 1,
        "content" => "omega relay note"
      })

    filters = [%{"kinds" => [1], "search" => "alph"}]

    assert {:ok, [result]} = Events.query(%{}, filters, [])
    assert result["id"] == matching["id"]
    assert {:ok, 1} = Events.count(%{}, filters, [])
  end

  test "search treats % and _ as literals" do
    matching =
      persist_event(%{
        "kind" => 1,
        "content" => "literal 100%_match value"
      })

    _other =
      persist_event(%{
        "kind" => 1,
        "content" => "literal 100Xmatch value"
      })

    filters = [%{"kinds" => [1], "search" => "100%_match"}]

    assert {:ok, [result]} = Events.query(%{}, filters, [])
    assert result["id"] == matching["id"]
    assert {:ok, 1} = Events.count(%{}, filters, [])
  end

  test "query/3 combines search and media metadata tag filters" do
    media_hash = String.duplicate("a", 64)

    matching =
      persist_event(%{
        "kind" => 1,
        "tags" => [
          ["imeta", "url", "https://media.example/blob", "m", "image/jpeg", "x", media_hash],
          ["m", "image/jpeg"],
          ["x", media_hash]
        ],
        "content" => "photo attachment from group"
      })

    _wrong_mime =
      persist_event(%{
        "kind" => 1,
        "tags" => [["m", "video/mp4"], ["x", media_hash]],
        "content" => "photo attachment from group"
      })

    _wrong_search =
      persist_event(%{
        "kind" => 1,
        "tags" => [["m", "image/jpeg"], ["x", media_hash]],
        "content" => "document attachment"
      })

    filters = [
      %{"kinds" => [1], "search" => "photo", "#m" => ["image/jpeg"], "#x" => [media_hash]}
    ]

    assert {:ok, [result]} = Events.query(%{}, filters, [])
    assert result["id"] == matching["id"]

    assert {:ok, 1} = Events.count(%{}, filters, [])
  end

  test "query/3 supports #i keypackage reference lookups" do
    keypackage_ref = String.duplicate("a", 64)

    matching =
      persist_event(%{
        "kind" => 443,
        "tags" => [["i", keypackage_ref], ["encoding", "base64"]],
        "content" => Base.encode64("keypackage")
      })

    _non_matching =
      persist_event(%{
        "kind" => 443,
        "tags" => [["i", String.duplicate("b", 64)], ["encoding", "base64"]],
        "content" => Base.encode64("other")
      })

    assert {:ok, [result]} =
             Events.query(%{}, [%{"kinds" => [443], "#i" => [keypackage_ref]}], [])

    assert result["id"] == matching["id"]
  end

  test "query/3 routes Marmot group events by #h and keeps deterministic order" do
    group_id = String.duplicate("a", 64)
    other_group_id = String.duplicate("b", 64)

    older =
      persist_event(%{
        "kind" => 445,
        "created_at" => 1_700_000_600,
        "tags" => [["h", group_id]],
        "content" => Base.encode64("older")
      })

    tie_a =
      persist_event(%{
        "kind" => 445,
        "created_at" => 1_700_000_601,
        "tags" => [["h", group_id]],
        "content" => Base.encode64("tie-a")
      })

    tie_b =
      persist_event(%{
        "kind" => 445,
        "created_at" => 1_700_000_601,
        "tags" => [["h", group_id]],
        "content" => Base.encode64("tie-b")
      })

    _other_group =
      persist_event(%{
        "kind" => 445,
        "created_at" => 1_700_000_602,
        "tags" => [["h", other_group_id]],
        "content" => Base.encode64("other-group")
      })

    assert {:ok, results} =
             Events.query(%{}, [%{"kinds" => [445], "#h" => [group_id]}], now: 1_700_000_700)

    tie_winner_id = Enum.min([tie_a["id"], tie_b["id"]])
    tie_loser_id = Enum.max([tie_a["id"], tie_b["id"]])

    assert Enum.map(results, & &1["id"]) == [tie_winner_id, tie_loser_id, older["id"]]
  end

  test "query/3 keeps deterministic ordering for high-volume kind 445 group traffic" do
    group_id = String.duplicate("c", 64)

    events =
      Enum.map(1..60, fn idx ->
        persist_event(%{
          "kind" => 445,
          "created_at" => 1_700_001_000 + div(idx, 3),
          "tags" => [["h", group_id]],
          "content" => Base.encode64("group-message-#{idx}")
        })
      end)

    assert {:ok, results} =
             Events.query(%{}, [%{"kinds" => [445], "#h" => [group_id]}], now: 1_700_001_100)

    expected_ids =
      events
      |> Enum.sort(fn left, right ->
        cond do
          left["created_at"] > right["created_at"] -> true
          left["created_at"] < right["created_at"] -> false
          true -> left["id"] < right["id"]
        end
      end)
      |> Enum.map(& &1["id"])

    assert Enum.map(results, & &1["id"]) == expected_ids
  end

  test "mls keypackage relay list kind 10051 follows replaceable conflict semantics" do
    author = String.duplicate("c", 64)

    first =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_500,
        "kind" => 10_051,
        "content" => "v1"
      })

    second =
      persist_event(%{
        "pubkey" => author,
        "created_at" => 1_700_000_501,
        "kind" => 10_051,
        "content" => "v2"
      })

    assert {:ok, [result]} =
             Events.query(%{}, [%{"authors" => [author], "kinds" => [10_051]}], [])

    assert result["id"] == second["id"]
    assert {:ok, nil} = Events.get_event(%{}, first["id"])
  end

  defp persist_event(overrides) do
    event = build_event(overrides)
    assert {:ok, _persisted} = Events.put_event(%{}, event)
    event
  end

  defp build_event(overrides) do
    base_event = %{
      "pubkey" => String.duplicate("7", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "content-#{System.unique_integer([:positive])}",
      "sig" => String.duplicate("8", 128)
    }

    event = Map.merge(base_event, overrides)
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
