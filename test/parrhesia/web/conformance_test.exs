defmodule Parrhesia.Web.ConformanceTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo
  alias Parrhesia.Web.Connection

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "REQ -> EOSE emitted once and CLOSE emits CLOSED" do
    {:ok, state} = Connection.init(subscription_index: nil)

    req_payload = Jason.encode!(["REQ", "sub-e2e", %{"kinds" => [1]}])

    assert {:push, frames, subscribed_state} =
             Connection.handle_in({req_payload, [opcode: :text]}, state)

    decoded = Enum.map(frames, fn {:text, frame} -> Jason.decode!(frame) end)
    assert ["EOSE", "sub-e2e"] = List.last(decoded)

    close_payload = Jason.encode!(["CLOSE", "sub-e2e"])

    assert {:push, {:text, closed_frame}, closed_state} =
             Connection.handle_in({close_payload, [opcode: :text]}, subscribed_state)

    assert Jason.decode!(closed_frame) == ["CLOSED", "sub-e2e", "error: subscription closed"]
    refute Map.has_key?(closed_state.subscriptions, "sub-e2e")
  end

  test "EVENT accepted path returns canonical OK frame" do
    {:ok, state} = Connection.init(subscription_index: nil)

    event = valid_event()

    assert {:push, {:text, frame}, ^state} =
             Connection.handle_in({Jason.encode!(["EVENT", event]), [opcode: :text]}, state)

    assert Jason.decode!(frame) == ["OK", event["id"], true, "ok: event stored"]
  end

  defp valid_event do
    now = System.system_time(:second)

    base = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => now,
      "kind" => 1,
      "tags" => [],
      "content" => "e2e",
      "sig" => String.duplicate("2", 128)
    }

    Map.put(base, "id", EventValidator.compute_id(base))
  end
end
