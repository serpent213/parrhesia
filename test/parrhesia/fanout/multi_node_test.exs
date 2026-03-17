defmodule Parrhesia.Fanout.MultiNodeTest do
  use Parrhesia.IntegrationCase, async: false

  alias Parrhesia.Fanout.MultiNode
  alias Parrhesia.Subscriptions.Index

  test "publishes remote fanout events across pg members" do
    remote_bus = start_supervised!({MultiNode, name: nil})

    assert :ok = Index.upsert(Index, self(), "sub-multi", [%{"kinds" => [1]}])

    event = %{
      "id" => String.duplicate("a", 64),
      "kind" => 1,
      "pubkey" => String.duplicate("b", 64),
      "tags" => [],
      "content" => "x"
    }

    assert :ok = MultiNode.publish(MultiNode, event)

    assert_receive {:fanout_event, "sub-multi", ^event}
    assert is_pid(remote_bus)
  end
end
