defmodule Parrhesia.Web.EventIngestLimiter do
  @moduledoc """
  Relay-wide EVENT ingest rate limiting over a fixed time window.
  """

  use GenServer

  @default_max_events_per_window 10_000
  @default_window_seconds 1
  @named_table :parrhesia_event_ingest_limiter
  @config_key :config

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    max_events_per_window =
      normalize_positive_integer(
        Keyword.get(opts, :max_events_per_window),
        max_events_per_window()
      )

    window_ms =
      normalize_positive_integer(Keyword.get(opts, :window_seconds), window_seconds()) * 1000

    init_arg = %{
      max_events_per_window: max_events_per_window,
      window_ms: window_ms,
      named_table?: Keyword.get(opts, :name, __MODULE__) == __MODULE__
    }

    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, init_arg)
      name -> GenServer.start_link(__MODULE__, init_arg, name: name)
    end
  end

  @spec allow(GenServer.server()) :: :ok | {:error, :relay_event_rate_limited}
  def allow(server \\ __MODULE__)

  def allow(__MODULE__) do
    case fetch_named_config() do
      {:ok, max_events_per_window, window_ms} ->
        allow_counter(@named_table, max_events_per_window, window_ms)

      :error ->
        :ok
    end
  end

  def allow(server), do: GenServer.call(server, :allow)

  @impl true
  def init(%{
        max_events_per_window: max_events_per_window,
        window_ms: window_ms,
        named_table?: named_table?
      }) do
    table = create_table(named_table?)

    true = :ets.insert(table, {@config_key, max_events_per_window, window_ms})

    {:ok,
     %{
       table: table,
       max_events_per_window: max_events_per_window,
       window_ms: window_ms
     }}
  end

  @impl true
  def handle_call(:allow, _from, state) do
    {:reply, allow_counter(state.table, state.max_events_per_window, state.window_ms), state}
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp normalize_positive_integer(_value, default), do: default

  defp create_table(true) do
    :ets.new(@named_table, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])
  end

  defp create_table(false) do
    :ets.new(__MODULE__, [:set, :public, {:read_concurrency, true}, {:write_concurrency, true}])
  end

  defp fetch_named_config do
    case :ets.lookup(@named_table, @config_key) do
      [{@config_key, max_events_per_window, window_ms}] -> {:ok, max_events_per_window, window_ms}
      _other -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp allow_counter(table, max_events_per_window, window_ms) do
    window_id = System.monotonic_time(:millisecond) |> div(window_ms)
    key = {:window, window_id}

    count = :ets.update_counter(table, key, {2, 1}, {key, 0})

    if count == 1 do
      prune_expired_windows(table, window_id)
    end

    if count <= max_events_per_window do
      :ok
    else
      {:error, :relay_event_rate_limited}
    end
  rescue
    ArgumentError -> :ok
  end

  defp prune_expired_windows(table, window_id) do
    :ets.select_delete(table, [
      {{{:window, :"$1"}, :_}, [{:<, :"$1", window_id}], [true]}
    ])
  end

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
