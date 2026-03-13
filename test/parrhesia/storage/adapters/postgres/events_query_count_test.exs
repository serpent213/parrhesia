defmodule Parrhesia.Storage.Adapters.Postgres.EventsQueryCountTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Storage.Adapters.Postgres.Events

  setup_all do
    start_supervised!(Repo)
    Sandbox.mode(Repo, :manual)
    :ok
  end

  setup do
    :ok = Sandbox.checkout(Repo)
  end

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
