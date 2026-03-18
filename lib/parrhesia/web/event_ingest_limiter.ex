defmodule Parrhesia.Web.EventIngestLimiter do
  @moduledoc """
  Relay-wide EVENT ingest rate limiting over a fixed time window.
  """

  use GenServer

  @default_max_events_per_window 10_000
  @default_window_seconds 1

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec allow(GenServer.server()) :: :ok | {:error, :relay_event_rate_limited}
  def allow(server \\ __MODULE__) do
    GenServer.call(server, :allow)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       max_events_per_window:
         normalize_positive_integer(
           Keyword.get(opts, :max_events_per_window),
           max_events_per_window()
         ),
       window_ms:
         normalize_positive_integer(Keyword.get(opts, :window_seconds), window_seconds()) * 1000,
       window_started_at_ms: System.monotonic_time(:millisecond),
       count: 0
     }}
  end

  @impl true
  def handle_call(:allow, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      now_ms - state.window_started_at_ms >= state.window_ms ->
        next_state = %{state | window_started_at_ms: now_ms, count: 1}
        {:reply, :ok, next_state}

      state.count < state.max_events_per_window ->
        next_state = %{state | count: state.count + 1}
        {:reply, :ok, next_state}

      true ->
        {:reply, {:error, :relay_event_rate_limited}, state}
    end
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default

  defp max_events_per_window do
    case Application.get_env(:parrhesia, :limits, [])
         |> Keyword.get(:relay_max_event_ingest_per_window) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_max_events_per_window
    end
  end

  defp window_seconds do
    case Application.get_env(:parrhesia, :limits, [])
         |> Keyword.get(:relay_event_ingest_window_seconds) do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_window_seconds
    end
  end
end
