defmodule Parrhesia.Fanout.MultiNode do
  @moduledoc """
  Lightweight multi-node fanout bus built on `:pg` groups.
  """

  use GenServer

  alias Parrhesia.Subscriptions.Index

  @group __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec publish(map()) :: :ok
  def publish(event), do: publish(__MODULE__, event)

  @spec publish(GenServer.server(), map()) :: :ok
  def publish(server, event) when is_map(event) do
    GenServer.cast(server, {:publish, event})
  end

  @impl true
  def init(:ok) do
    :ok = ensure_pg_started()
    :ok = :pg.join(@group, self())
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:publish, event}, state) do
    @group
    |> :pg.get_members()
    |> Enum.reject(&(&1 == self()))
    |> Enum.each(fn member_pid ->
      send(member_pid, {:remote_fanout_event, event})
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:remote_fanout_event, event}, state) do
    Index.candidate_subscription_keys(event)
    |> Enum.each(fn {owner_pid, subscription_id} ->
      send(owner_pid, {:fanout_event, subscription_id, event})
    end)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ensure_pg_started do
    case Process.whereis(:pg) do
      nil ->
        case :pg.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, reason}
        end

      _pid ->
        :ok
    end
  end
end
