defmodule Parrhesia.Auth.Nip98ReplayCache do
  @moduledoc """
  Tracks recently accepted NIP-98 auth event ids to prevent replay.
  """

  use GenServer

  @default_max_age_seconds 60

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec consume(GenServer.server(), String.t(), integer(), keyword()) ::
          :ok | {:error, :replayed_auth_event}
  def consume(server \\ __MODULE__, event_id, created_at, opts \\ [])
      when is_binary(event_id) and is_integer(created_at) and is_list(opts) do
    GenServer.call(server, {:consume, event_id, created_at, opts})
  end

  @impl true
  def init(_opts) do
    {:ok, %{entries: %{}}}
  end

  @impl true
  def handle_call({:consume, event_id, created_at, opts}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    entries = prune_expired(state.entries, now_ms)

    case Map.has_key?(entries, event_id) do
      true ->
        {:reply, {:error, :replayed_auth_event}, %{state | entries: entries}}

      false ->
        expires_at_ms = replay_expiration_ms(now_ms, created_at, opts)
        next_entries = Map.put(entries, event_id, expires_at_ms)
        {:reply, :ok, %{state | entries: next_entries}}
    end
  end

  defp prune_expired(entries, now_ms) do
    Map.reject(entries, fn {_event_id, expires_at_ms} -> expires_at_ms <= now_ms end)
  end

  defp replay_expiration_ms(now_ms, created_at, opts) do
    max_age_seconds = Keyword.get(opts, :max_age_seconds, max_age_seconds())
    max(now_ms, created_at * 1000) + max_age_seconds * 1000
  end

  defp max_age_seconds, do: @default_max_age_seconds
end
