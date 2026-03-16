defmodule Parrhesia.TestSupport.SyncFakeRelay.Server do
  @moduledoc false

  use Agent

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)

    initial_state = %{
      pubkey: Keyword.fetch!(opts, :pubkey),
      expected_client_pubkey: Keyword.fetch!(opts, :expected_client_pubkey),
      initial_events: Keyword.get(opts, :initial_events, []),
      subscribers: %{}
    }

    Agent.start_link(fn -> initial_state end, name: name)
  end

  def document(server) do
    Agent.get(server, fn state ->
      %{
        "name" => "Sync Fake Relay",
        "description" => "test relay",
        "pubkey" => state.pubkey,
        "supported_nips" => [1, 11, 42]
      }
    end)
  end

  def initial_events(server) do
    Agent.get(server, & &1.initial_events)
  end

  def expected_client_pubkey(server) do
    Agent.get(server, & &1.expected_client_pubkey)
  end

  def register_subscription(server, pid, subscription_id) do
    Agent.update(server, fn state ->
      put_in(state, [:subscribers, {pid, subscription_id}], true)
    end)
  end

  def unregister_subscription(server, pid, subscription_id) do
    Agent.update(server, fn state ->
      update_in(state.subscribers, &Map.delete(&1, {pid, subscription_id}))
    end)
  end

  def publish_live_event(server, event) do
    subscribers =
      Agent.get_and_update(server, fn state ->
        {
          Map.keys(state.subscribers),
          %{state | initial_events: state.initial_events ++ [event]}
        }
      end)

    Enum.each(subscribers, fn {pid, subscription_id} ->
      send(pid, {:sync_fake_relay_event, subscription_id, event})
    end)

    :ok
  end
end
