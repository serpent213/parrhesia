defmodule Parrhesia.Negentropy.Sessions do
  @moduledoc """
  In-memory NEG-* session tracking.
  """

  use GenServer

  @type session_key :: {pid(), String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, :ok, name: name)
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
  def init(:ok) do
    {:ok, %{sessions: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:open, owner_pid, subscription_id, params}, _from, state) do
    key = {owner_pid, subscription_id}

    session = %{
      cursor: 0,
      params: params,
      opened_at: System.system_time(:second)
    }

    state =
      state
      |> ensure_monitor(owner_pid)
      |> put_in([:sessions, key], session)

    {:reply, {:ok, %{"status" => "open", "cursor" => 0}}, state}
  end

  def handle_call({:message, owner_pid, subscription_id, payload}, _from, state) do
    key = {owner_pid, subscription_id}

    case Map.get(state.sessions, key) do
      nil ->
        {:reply, {:error, :unknown_session}, state}

      session ->
        cursor = session.cursor + 1

        next_session = %{session | cursor: cursor, params: Map.merge(session.params, payload)}
        state = put_in(state, [:sessions, key], next_session)

        {:reply, {:ok, %{"status" => "ack", "cursor" => cursor}}, state}
    end
  end

  def handle_call({:close, owner_pid, subscription_id}, _from, state) do
    key = {owner_pid, subscription_id}
    state = update_in(state.sessions, &Map.delete(&1, key))
    {:reply, :ok, state}
  end

  @impl true
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

  defp remove_owner_sessions(state, owner_pid) do
    update_in(state.sessions, fn sessions ->
      sessions
      |> Enum.reject(fn {{session_owner, _sub_id}, _session} -> session_owner == owner_pid end)
      |> Map.new()
    end)
  end

  defp ensure_monitor(state, owner_pid) do
    case Map.has_key?(state.monitors, owner_pid) do
      true -> state
      false -> put_in(state, [:monitors, owner_pid], Process.monitor(owner_pid))
    end
  end

  defp maybe_remove_monitor(state, owner_pid) do
    {monitor_ref, monitors} = Map.pop(state.monitors, owner_pid)

    if is_reference(monitor_ref) do
      Process.demonitor(monitor_ref, [:flush])
    end

    Map.put(state, :monitors, monitors)
  end
end
