defmodule Parrhesia.Negentropy.Sessions do
  @moduledoc """
  In-memory NEG-* session tracking.
  """

  use GenServer

  @type session_key :: {pid(), String.t()}

  @default_max_payload_bytes 4096
  @default_max_sessions_per_owner 8
  @default_max_total_sessions 10_000
  @default_max_idle_seconds 60
  @default_sweep_interval_seconds 10
  @sweep_idle_sessions :sweep_idle_sessions

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec open(GenServer.server(), pid(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def open(server \\ __MODULE__, owner_pid, subscription_id, params)
      when is_pid(owner_pid) and is_binary(subscription_id) and is_map(params) do
    GenServer.call(server, {:open, owner_pid, subscription_id, params})
  end

  @spec message(GenServer.server(), pid(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def message(server \\ __MODULE__, owner_pid, subscription_id, payload)
      when is_pid(owner_pid) and is_binary(subscription_id) and is_map(payload) do
    GenServer.call(server, {:message, owner_pid, subscription_id, payload})
  end

  @spec close(GenServer.server(), pid(), String.t()) :: :ok
  def close(server \\ __MODULE__, owner_pid, subscription_id)
      when is_pid(owner_pid) and is_binary(subscription_id) do
    GenServer.call(server, {:close, owner_pid, subscription_id})
  end

  @impl true
  def init(opts) do
    max_idle_ms =
      normalize_positive_integer(Keyword.get(opts, :max_idle_seconds), max_idle_seconds()) * 1000

    sweep_interval_ms =
      normalize_positive_integer(
        Keyword.get(opts, :sweep_interval_seconds),
        sweep_interval_seconds()
      ) *
        1000

    state = %{
      sessions: %{},
      monitors: %{},
      max_payload_bytes:
        normalize_positive_integer(Keyword.get(opts, :max_payload_bytes), max_payload_bytes()),
      max_sessions_per_owner:
        normalize_positive_integer(
          Keyword.get(opts, :max_sessions_per_owner),
          max_sessions_per_owner()
        ),
      max_total_sessions:
        normalize_positive_integer(Keyword.get(opts, :max_total_sessions), max_total_sessions()),
      max_idle_ms: max_idle_ms,
      sweep_interval_ms: sweep_interval_ms
    }

    :ok = schedule_idle_sweep(sweep_interval_ms)

    {:ok, state}
  end

  @impl true
  def handle_call({:open, owner_pid, subscription_id, params}, _from, state) do
    key = {owner_pid, subscription_id}

    with :ok <- validate_payload_size(params, state.max_payload_bytes),
         :ok <- enforce_session_limits(state, owner_pid, key) do
      now_ms = System.monotonic_time(:millisecond)

      session = %{
        cursor: 0,
        params: params,
        opened_at: System.system_time(:second),
        last_active_at_ms: now_ms
      }

      state =
        state
        |> ensure_monitor(owner_pid)
        |> put_in([:sessions, key], session)

      {:reply, {:ok, %{"status" => "open", "cursor" => 0}}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:message, owner_pid, subscription_id, payload}, _from, state) do
    key = {owner_pid, subscription_id}

    case Map.get(state.sessions, key) do
      nil ->
        {:reply, {:error, :unknown_session}, state}

      session ->
        case validate_payload_size(payload, state.max_payload_bytes) do
          :ok ->
            cursor = session.cursor + 1

            next_session = %{
              session
              | cursor: cursor,
                last_active_at_ms: System.monotonic_time(:millisecond)
            }

            state = put_in(state, [:sessions, key], next_session)

            {:reply, {:ok, %{"status" => "ack", "cursor" => cursor}}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:close, owner_pid, subscription_id}, _from, state) do
    key = {owner_pid, subscription_id}

    state =
      state
      |> update_in([:sessions], &Map.delete(&1, key))
      |> maybe_remove_monitor_if_owner_has_no_sessions(owner_pid)

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(@sweep_idle_sessions, state) do
    now_ms = System.monotonic_time(:millisecond)

    sessions =
      Enum.reduce(state.sessions, %{}, fn {key, session}, acc ->
        idle_ms = now_ms - Map.get(session, :last_active_at_ms, now_ms)

        if idle_ms >= state.max_idle_ms do
          acc
        else
          Map.put(acc, key, session)
        end
      end)

    owner_pids =
      sessions
      |> Map.keys()
      |> Enum.map(fn {owner_pid, _subscription_id} -> owner_pid end)
      |> MapSet.new()

    state =
      state
      |> Map.put(:sessions, sessions)
      |> clear_monitors_without_sessions(owner_pids)

    :ok = schedule_idle_sweep(state.sweep_interval_ms)

    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, owner_pid, _reason}, state) do
    case Map.get(state.monitors, owner_pid) do
      ^monitor_ref ->
        state =
          state
          |> maybe_remove_monitor(owner_pid)
          |> remove_owner_sessions(owner_pid)

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp clear_monitors_without_sessions(state, owner_pids) do
    Enum.reduce(Map.keys(state.monitors), state, fn owner_pid, acc ->
      if MapSet.member?(owner_pids, owner_pid) do
        acc
      else
        maybe_remove_monitor(acc, owner_pid)
      end
    end)
  end

  defp remove_owner_sessions(state, owner_pid) do
    update_in(state.sessions, fn sessions ->
      sessions
      |> Enum.reject(fn {{session_owner, _sub_id}, _session} -> session_owner == owner_pid end)
      |> Map.new()
    end)
  end

  defp validate_payload_size(payload, max_payload_bytes) do
    if :erlang.external_size(payload) <= max_payload_bytes do
      :ok
    else
      {:error, :payload_too_large}
    end
  end

  defp enforce_session_limits(state, owner_pid, key) do
    if Map.has_key?(state.sessions, key) do
      :ok
    else
      total_sessions = map_size(state.sessions)

      cond do
        total_sessions >= state.max_total_sessions ->
          {:error, :session_limit_reached}

        owner_session_count(state.sessions, owner_pid) >= state.max_sessions_per_owner ->
          {:error, :owner_session_limit_reached}

        true ->
          :ok
      end
    end
  end

  defp owner_session_count(sessions, owner_pid) do
    Enum.count(sessions, fn {{session_owner, _subscription_id}, _session} ->
      session_owner == owner_pid
    end)
  end

  defp ensure_monitor(state, owner_pid) do
    case Map.has_key?(state.monitors, owner_pid) do
      true -> state
      false -> put_in(state, [:monitors, owner_pid], Process.monitor(owner_pid))
    end
  end

  defp maybe_remove_monitor_if_owner_has_no_sessions(state, owner_pid) do
    if owner_session_count(state.sessions, owner_pid) == 0 do
      maybe_remove_monitor(state, owner_pid)
    else
      state
    end
  end

  defp maybe_remove_monitor(state, owner_pid) do
    {monitor_ref, monitors} = Map.pop(state.monitors, owner_pid)

    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end

    Map.put(state, :monitors, monitors)
  end

  defp schedule_idle_sweep(sweep_interval_ms) do
    _timer_ref = Process.send_after(self(), @sweep_idle_sessions, sweep_interval_ms)
    :ok
  end

  defp max_payload_bytes do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_negentropy_payload_bytes, @default_max_payload_bytes)
  end

  defp max_sessions_per_owner do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_negentropy_sessions_per_connection, @default_max_sessions_per_owner)
  end

  defp max_total_sessions do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:max_negentropy_total_sessions, @default_max_total_sessions)
  end

  defp max_idle_seconds do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:negentropy_session_idle_timeout_seconds, @default_max_idle_seconds)
  end

  defp sweep_interval_seconds do
    :parrhesia
    |> Application.get_env(:limits, [])
    |> Keyword.get(:negentropy_session_sweep_interval_seconds, @default_sweep_interval_seconds)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0,
    do: value

  defp normalize_positive_integer(_value, default), do: default
end
