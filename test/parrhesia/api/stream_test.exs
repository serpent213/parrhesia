defmodule Parrhesia.API.StreamTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Parrhesia.API.Events
  alias Parrhesia.API.RequestContext
  alias Parrhesia.API.Stream
  alias Parrhesia.Protocol.EventValidator
  alias Parrhesia.Repo

  setup do
    :ok = Sandbox.checkout(Repo)
    :ok
  end

  test "subscribe streams catch-up events followed by eose" do
    event = valid_event()
    context = %RequestContext{}

    assert {:ok, %{accepted: true}} = Events.publish(event, context: context)
    assert {:ok, ref} = Stream.subscribe(self(), "sub-1", [%{"kinds" => [1]}], context: context)

    assert_receive {:parrhesia, :event, ^ref, "sub-1", received_event}
    assert received_event["id"] == event["id"]
    assert_receive {:parrhesia, :eose, ^ref, "sub-1"}
    assert :ok = Stream.unsubscribe(ref)
  end

  test "subscribe receives live fanout events after eose" do
    context = %RequestContext{}
    event = valid_event()

    assert {:ok, ref} =
             Stream.subscribe(self(), "sub-live", [%{"kinds" => [1]}], context: context)

    assert_receive {:parrhesia, :eose, ^ref, "sub-live"}, 1_000

    assert {:ok, %{accepted: true}} = Events.publish(event, context: context)

    assert_receive {:parrhesia, :event, ^ref, "sub-live", received_event}, 1_000
    assert received_event["id"] == event["id"]
    assert :ok = Stream.unsubscribe(ref)
  end

  test "unsubscribe stops the subscription bridge" do
    context = %RequestContext{}

    assert {:ok, ref} =
             Stream.subscribe(self(), "sub-stop", [%{"kinds" => [1]}], context: context)

    assert_receive {:parrhesia, :eose, ^ref, "sub-stop"}

    [{stream_pid, _value}] = Registry.lookup(Parrhesia.API.Stream.Registry, ref)
    _ = :sys.get_state(stream_pid)
    monitor_ref = Process.monitor(stream_pid)

    assert :ok = Stream.unsubscribe(ref)
    assert_receive {:DOWN, ^monitor_ref, :process, ^stream_pid, reason}
    assert reason in [:normal, :noproc]
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
