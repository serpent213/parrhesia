defmodule Parrhesia.Tasks.Nip66Publisher do
  @moduledoc """
  Periodic worker that publishes NIP-66 monitor and discovery events.
  """

  use GenServer

  alias Parrhesia.NIP66

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, NIP66.publish_interval_ms()),
      publish_opts: Keyword.drop(opts, [:name, :interval_ms, :nip66_module]),
      nip66_module: Keyword.get(opts, :nip66_module, NIP66)
    }

    schedule_tick(0)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _result = state.nip66_module.publish_snapshot(state.publish_opts)
    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end
end
