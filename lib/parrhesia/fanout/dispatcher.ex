defmodule Parrhesia.Fanout.Dispatcher do
  @moduledoc """
  Asynchronous local fanout dispatcher.
  """

  use GenServer

  alias Parrhesia.Subscriptions.Index

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @spec dispatch(map()) :: :ok
  def dispatch(event), do: dispatch(__MODULE__, event)

  @spec dispatch(GenServer.server(), map()) :: :ok
  def dispatch(server, event) when is_map(event) do
    GenServer.cast(server, {:dispatch, event})
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_cast({:dispatch, event}, state) do
    dispatch_to_candidates(event)
    {:noreply, state}
  end

  defp dispatch_to_candidates(event) do
    case Index.candidate_subscription_keys(event) do
      candidates when is_list(candidates) ->
        Enum.each(candidates, fn {owner_pid, subscription_id} ->
          send(owner_pid, {:fanout_event, subscription_id, event})
        end)

      _other ->
        :ok
    end
  catch
    :exit, _reason -> :ok
  end
end
