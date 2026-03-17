defmodule Parrhesia.API.EventsTest do
  use Parrhesia.IntegrationCase, async: false, sandbox: true

  alias Parrhesia.API.Events
  alias Parrhesia.API.RequestContext
  alias Parrhesia.Protocol.EventValidator

  test "publish stores valid events through the shared API" do
    event = valid_event()

    assert {:ok, result} = Events.publish(event, context: %RequestContext{})
    assert result.accepted
    assert result.event_id == event["id"]
    assert result.message == "ok: event stored"
    assert result.reason == nil

    assert {:ok, stored_event} = Parrhesia.Storage.events().get_event(%{}, event["id"])
    assert stored_event["id"] == event["id"]
  end

  test "publish returns duplicate results without raising transport errors" do
    event = valid_event()

    assert {:ok, first_result} = Events.publish(event, context: %RequestContext{})
    assert first_result.accepted

    assert {:ok, second_result} = Events.publish(event, context: %RequestContext{})
    refute second_result.accepted
    assert second_result.reason == :duplicate_event
    assert second_result.message == "duplicate: event already stored"
  end

  test "query and count preserve read semantics through the shared API" do
    now = System.system_time(:second)
    first = valid_event(%{"content" => "first", "created_at" => now})
    second = valid_event(%{"content" => "second", "created_at" => now + 1})

    assert {:ok, %{accepted: true}} = Events.publish(first, context: %RequestContext{})
    assert {:ok, %{accepted: true}} = Events.publish(second, context: %RequestContext{})

    assert {:ok, events} =
             Events.query([%{"kinds" => [1]}], context: %RequestContext{})

    assert Enum.map(events, & &1["id"]) == [second["id"], first["id"]]

    assert {:ok, 2} =
             Events.count([%{"kinds" => [1]}], context: %RequestContext{})

    assert {:ok, %{"count" => 2, "approximate" => false}} =
             Events.count([%{"kinds" => [1]}],
               context: %RequestContext{},
               options: %{}
             )
  end

  defp valid_event(overrides \\ %{}) do
    base_event = %{
      "pubkey" => String.duplicate("1", 64),
      "created_at" => System.system_time(:second),
      "kind" => 1,
      "tags" => [],
      "content" => "hello",
      "sig" => String.duplicate("3", 128)
    }

    base_event
    |> Map.merge(overrides)
    |> recalculate_event_id()
  end

  defp recalculate_event_id(event) do
    Map.put(event, "id", EventValidator.compute_id(event))
  end
end
