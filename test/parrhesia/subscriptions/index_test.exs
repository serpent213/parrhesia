defmodule Parrhesia.Subscriptions.IndexTest do
  use ExUnit.Case, async: true

  alias Parrhesia.Subscriptions.Index

  test "returns narrowed candidates by kind, author, and tag" do
    index = start_supervised!(Index)
    owner = self()

    author = String.duplicate("a", 64)

    filters = [
      %{
        "kinds" => [1],
        "authors" => [author],
        "#e" => ["event-1"]
      }
    ]

    assert :ok = Index.upsert(index, owner, "sub-1", filters)

    matching_event = %{"kind" => 1, "pubkey" => author, "tags" => [["e", "event-1"]]}
    non_matching_event = %{"kind" => 2, "pubkey" => author, "tags" => [["e", "event-1"]]}

    assert Index.candidate_subscription_keys(index, matching_event) == [{owner, "sub-1"}]
    assert Index.candidate_subscription_keys(index, non_matching_event) == []
  end

  test "treats missing kind and tag constraints as wildcards" do
    index = start_supervised!(Index)
    owner = self()

    author = String.duplicate("b", 64)
    filters = [%{"authors" => [author]}]

    assert :ok = Index.upsert(index, owner, "sub-1", filters)

    event = %{"kind" => 7, "pubkey" => author, "tags" => []}

    assert Index.candidate_subscription_keys(index, event) == [{owner, "sub-1"}]
  end

  test "replaces existing subscription index entries on upsert" do
    index = start_supervised!(Index)
    owner = self()

    assert :ok = Index.upsert(index, owner, "sub-1", [%{"kinds" => [1]}])
    assert :ok = Index.upsert(index, owner, "sub-1", [%{"kinds" => [2]}])

    kind_one_event = %{"kind" => 1, "pubkey" => "any", "tags" => []}
    kind_two_event = %{"kind" => 2, "pubkey" => "any", "tags" => []}

    assert Index.candidate_subscription_keys(index, kind_one_event) == []
    assert Index.candidate_subscription_keys(index, kind_two_event) == [{owner, "sub-1"}]
  end

  test "removes subscriptions when owner process exits" do
    index = start_supervised!(Index)

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert :ok = Index.upsert(index, owner, "sub-1", [%{"kinds" => [1]}])

    event = %{"kind" => 1, "pubkey" => "any", "tags" => []}
    assert Index.candidate_subscription_keys(index, event) == [{owner, "sub-1"}]

    ref = Process.monitor(owner)
    send(owner, :stop)

    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}

    _state = :sys.get_state(index)

    assert Index.candidate_subscription_keys(index, event) == []
  end
end
