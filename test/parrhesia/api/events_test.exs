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

  test "publish fanout includes sync-originated events when relay guard is disabled" do
    with_sync_relay_guard(false)
    join_multi_node_group!()

    event = valid_event()
    event_id = event["id"]

    assert {:ok, %{accepted: true}} =
             Events.publish(event, context: %RequestContext{caller: :sync})

    assert_receive {:remote_fanout_event, %{"id" => ^event_id}}, 200
  end

  test "publish fanout skips sync-originated events when relay guard is enabled" do
    with_sync_relay_guard(true)
    join_multi_node_group!()

    event = valid_event()
    event_id = event["id"]

    assert {:ok, %{accepted: true}} =
             Events.publish(event, context: %RequestContext{caller: :sync})

    refute_receive {:remote_fanout_event, %{"id" => ^event_id}}, 200
  end

  test "publish fanout still includes local-originated events when relay guard is enabled" do
    with_sync_relay_guard(true)
    join_multi_node_group!()

    event = valid_event()
    event_id = event["id"]

    assert {:ok, %{accepted: true}} =
             Events.publish(event, context: %RequestContext{caller: :local})

    assert_receive {:remote_fanout_event, %{"id" => ^event_id}}, 200
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

  defp with_sync_relay_guard(enabled?) when is_boolean(enabled?) do
    [{:config, previous}] = :ets.lookup(Parrhesia.Config, :config)

    sync =
      previous
      |> Map.get(:sync, [])
      |> Keyword.put(:relay_guard, enabled?)

    :ets.insert(Parrhesia.Config, {:config, Map.put(previous, :sync, sync)})

    on_exit(fn ->
      :ets.insert(Parrhesia.Config, {:config, previous})
    end)
  end

  defp join_multi_node_group! do
    case Process.whereis(:pg) do
      nil ->
        case :pg.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end

    :ok = :pg.join(Parrhesia.Fanout.MultiNode, self())
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
