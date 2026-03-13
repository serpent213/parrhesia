defmodule Parrhesia.Tasks.ExpirationWorker do
  @moduledoc """
  Periodic worker that purges expired events.
  """

  use GenServer

  alias Parrhesia.Storage
  alias Parrhesia.Telemetry

  @default_interval_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms)
    }

    schedule_tick(state.interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    started_at = System.monotonic_time()

    _result = Storage.events().purge_expired([])

    duration = System.monotonic_time() - started_at
    Telemetry.emit([:parrhesia, :maintenance, :purge_expired, :stop], %{duration: duration}, %{})

    schedule_tick(state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end
end
